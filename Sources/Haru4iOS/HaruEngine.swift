import Foundation
import Combine
import AVFoundation

private let haruFrameCallback: HaruFrameCallback = { samples, count, text, context in
    guard let context else { return 0 }
    let engine = Unmanaged<HaruEngine>.fromOpaque(context).takeUnretainedValue()
    engine.receiveOutput(samples: samples, count: count, text: text)
    return 0
}

private final class HaruRuntimeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// Bounded microphone ring buffer. The AVAudioEngine tap only copies samples;
/// all model inference is performed by HaruEngine's serial worker queue.
private final class HaruAudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let capacity = 96_000
    private var ring = [Float](repeating: 0, count: 96_000)
    private var readIndex = 0
    private var writeIndex = 0
    private var queued = 0
    private(set) var inputSampleRate: Double = 48_000
    private var running = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.invalidInputFormat
        }
        inputSampleRate = format.sampleRate

        engine.attach(player)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24_000, channels: 1,
                                         interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channelCount > 0, frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        for frame in 0..<frames {
            var mono: Float = 0
            for channel in 0..<channelCount { mono += channels[channel][frame] }
            mono /= Float(channelCount)
            if queued == capacity {
                readIndex = (readIndex + 1) % capacity
                queued -= 1
            }
            ring[writeIndex] = mono
            writeIndex = (writeIndex + 1) % capacity
            queued += 1
        }
    }

    func takeInput(maxSamples: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(maxSamples, queued)
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = ring[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        queued -= count
        return result
    }

    func play(samples: [Float]) {
        guard running, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24_000, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        readIndex = 0
        writeIndex = 0
        queued = 0
        lock.unlock()
        running = false
    }

    private enum AudioError: LocalizedError {
        case invalidInputFormat
        var errorDescription: String? { "マイクの入力フォーマットを取得できませんでした" }
    }
}

@MainActor
final class HaruEngine: ObservableObject {
    @Published private(set) var status = "モデル未読み込み"
    @Published private(set) var lastText = ""
    @Published private(set) var lastFrameSamples = 0
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isDialogueActive = false
    @Published private(set) var isAudioRunning = false

    private let worker = DispatchQueue(label: "dev.haru4ios.inference", qos: .userInitiated)
    private let audioIO = HaruAudioIO()
    private var runtime: OpaquePointer?
    private var inputPump: DispatchSourceTimer?

    init() {
        runtime = HaruRuntimeCreate()
        if runtime == nil { status = "ネイティブランタイムの作成に失敗" }
    }

    func loadModel(at url: URL) {
        guard let runtime else { status = "ランタイムが初期化されていません"; return }
        status = "モデルを読み込み中…"
        let handle = HaruRuntimeHandle(runtime)
        worker.async { [weak self, handle] in
            guard let self else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let result = url.path.withCString { path in
                "auto".withCString { device in
                    error.withUnsafeMutableBufferPointer {
                        HaruRuntimeLoadModel(handle.pointer, path, device, 4,
                                             $0.baseAddress, $0.count)
                    }
                }
            }
            let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
            DispatchQueue.main.async {
                if result == 0 {
                    self.isModelLoaded = true
                    self.status = "モデル読み込み成功"
                } else {
                    self.status = "モデル読み込み失敗: \(message) (code \(result))"
                }
            }
        }
    }

    func startDialogue() {
        guard let runtime, isModelLoaded else {
            status = "先にHaru GGUFモデルを読み込んでください"
            return
        }
        guard !isDialogueActive else { return }
        status = "マイクを準備中…"
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "マイクへのアクセスが許可されていません" }
                return
            }
            let handle = HaruRuntimeHandle(runtime)
            self.worker.async { [weak self, handle] in
                guard let self else { return }
                do {
                    try self.audioIO.start()
                } catch {
                    DispatchQueue.main.async { self.status = "オーディオ開始失敗: \(error.localizedDescription)" }
                    return
                }

                var error = [CChar](repeating: 0, count: 1024)
                let context = Unmanaged.passUnretained(self).toOpaque()
                let sampleRate = Int(self.audioIO.inputSampleRate.rounded())
                let result = "ja".withCString { language in
                    "ハル".withCString { name in
                        "日本語で自然に会話する、親しみやすく反応のよい対話相手。".withCString { persona in
                            "あなた".withCString { otherName in
                                error.withUnsafeMutableBufferPointer {
                                    HaruRuntimeStartDialogue(
                                        handle.pointer, sampleRate, language, name,
                                        persona, otherName, 30.0, 1, haruFrameCallback,
                                        context, $0.baseAddress, $0.count
                                    )
                                }
                            }
                        }
                    }
                }
                let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                guard result == 0 else {
                    self.audioIO.stop()
                    DispatchQueue.main.async { self.status = "対話開始失敗: \(message) (code \(result))" }
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: self.worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
                timer.setEventHandler { [weak self, handle] in
                    guard let self else { return }
                    let count = max(240, Int((self.audioIO.inputSampleRate * 0.02).rounded()))
                    let pcm = self.audioIO.takeInput(maxSamples: count)
                    guard !pcm.isEmpty else { return }
                    var pushError = [CChar](repeating: 0, count: 1024)
                    let pushResult = pcm.withUnsafeBufferPointer { samples in
                        pushError.withUnsafeMutableBufferPointer { errorBuffer in
                            HaruRuntimePushAudio(handle.pointer, samples.baseAddress, samples.count,
                                                 errorBuffer.baseAddress, errorBuffer.count)
                        }
                    }
                    if pushResult < 0 {
                        let detail = pushError.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                        DispatchQueue.main.async {
                            self.status = "音声処理エラー: \(detail) (code \(pushResult))"
                        }
                    }
                }
                self.inputPump = timer
                timer.resume()
                DispatchQueue.main.async {
                    self.isDialogueActive = true
                    self.isAudioRunning = true
                    self.status = "会話中 — マイク入力・音声出力が有効です"
                }
            }
        }
    }

    func stopDialogue() {
        guard let runtime, isDialogueActive else { return }
        status = "対話を終了中…"
        let handle = HaruRuntimeHandle(runtime)
        worker.async { [weak self, handle] in
            guard let self else { return }
            self.inputPump?.cancel()
            self.inputPump = nil
            var error = [CChar](repeating: 0, count: 1024)
            let result = error.withUnsafeMutableBufferPointer {
                HaruRuntimeEndDialogue(handle.pointer, $0.baseAddress, $0.count)
            }
            self.audioIO.stop()
            let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
            DispatchQueue.main.async {
                self.isDialogueActive = false
                self.isAudioRunning = false
                self.status = result == 0 ? "対話セッション終了" : "終了時エラー: \(message)"
            }
        }
    }

    nonisolated func receiveOutput(samples: UnsafePointer<Float>?, count: Int, text: UnsafePointer<CChar>?) {
        let pcm = samples != nil && count > 0 ? Array(UnsafeBufferPointer(start: samples, count: count)) : []
        let message = text.map { String(cString: $0) } ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !pcm.isEmpty { self.audioIO.play(samples: pcm) }
            self.lastFrameSamples = count
            if !message.isEmpty { self.lastText = message }
        }
    }

    deinit {
        inputPump?.cancel()
        audioIO.stop()
        if let runtime { HaruRuntimeDestroy(runtime) }
    }
}
