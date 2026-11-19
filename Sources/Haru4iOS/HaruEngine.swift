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
private final class HaruAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let capacity = 96_000
    private var ring = [Float](repeating: 0, count: 96_000)
    private var readIndex = 0
    private var writeIndex = 0
    private var queued = 0
    private var droppedInputSamples: Int64 = 0
    private var queuedOutputSamples = 0
    private(set) var inputSampleRate: Double = 48_000
    private var running = false
    private var playerAttached = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Use the default mode for a diagnostic baseline. voiceChat enables
        // voice processing/AEC, which can suppress or reshape speaker playback
        // while the microphone is active.
        try session.setCategory(.playAndRecord, mode: .default,
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

        if !playerAttached {
            engine.attach(player)
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 24_000, channels: 1,
                                             interleaved: false)!
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            playerAttached = true
        }
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
                // Preserve the newest audio, but make every lost sample visible
                // to the latency monitor instead of silently hiding overflow.
                readIndex = (readIndex + 1) % capacity
                queued -= 1
                droppedInputSamples += 1
            }
            ring[writeIndex] = mono
            writeIndex = (writeIndex + 1) % capacity
            queued += 1
        }
    }

    func takeInput(maxSamples: Int = Int.max) -> [Float] {
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

    /// Mirrors the upstream CLI: audio captured while dialogue_start() is
    /// computing its first frame must not be fed into the new conversation.
    @discardableResult
    func discardPendingInput() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let discarded = queued
        readIndex = writeIndex
        queued = 0
        return discarded
    }

    func queuedInputSamples() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return queued
    }

    func takeDroppedInputSamples() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let result = droppedInputSamples
        droppedInputSamples = 0
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
        lock.lock()
        queuedOutputSamples += samples.count
        lock.unlock()
        let scheduledSampleCount = samples.count
        player.scheduleBuffer(buffer, completionHandler: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedOutputSamples = max(0, self.queuedOutputSamples - scheduledSampleCount)
            self.lock.unlock()
        })
    }

    func queuedOutputMilliseconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(queuedOutputSamples) / 24_000 * 1000.0
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
        droppedInputSamples = 0
        queuedOutputSamples = 0
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
    @Published private(set) var inputDiagnostics = "入力: 診断待機中"
    @Published private(set) var outputDiagnostics = "出力: 診断待機中"
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isDialogueActive = false
    @Published private(set) var isDialogueStarting = false
    @Published private(set) var isAudioRunning = false

    private let worker = DispatchQueue(label: "dev.haru4ios.inference", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "dev.haru4ios.output", qos: .userInitiated)
    private let audioIO = HaruAudioIO()
    private var runtime: OpaquePointer?
    private var modelPath: String?
    private var registeredVoiceKeys = Set<String>()
    private var inputPump: DispatchSourceTimer?

    init() {
        runtime = HaruRuntimeCreate()
        if runtime == nil { status = "ネイティブランタイムの作成に失敗" }
    }

    func loadModel(at url: URL) {
        guard let runtime else { status = "ランタイムが初期化されていません"; return }
        status = "モデルを読み込み中…"
        modelPath = url.path
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


    private func registerVoice(name: String, at url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let runtime else {
            completion(.failure(NSError(domain: "HaruVoice", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ランタイムが利用できません"])))
            return
        }
        let handle = HaruRuntimeHandle(runtime)
        worker.async {
            var error = [CChar](repeating: 0, count: 1024)
            let result = name.withCString { voiceName in
                url.path.withCString { path in
                    error.withUnsafeMutableBufferPointer {
                        HaruRuntimeAddVoice(handle.pointer, voiceName, path, $0.baseAddress, $0.count)
                    }
                }
            }
            let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
            DispatchQueue.main.async {
                if result == 0 {
                    self.registeredVoiceKeys.insert(name)
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "HaruVoice", code: Int(result),
                        userInfo: [NSLocalizedDescriptionKey: message])))
                }
            }
        }
    }

    func makeAndRegisterVoice(from sourceURL: URL, voiceURL: URL, voiceName: String,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        guard let runtime, let modelPath else {
            completion(.failure(NSError(domain: "HaruVoice", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "モデルが読み込まれていません"])))
            return
        }
        let handle = HaruRuntimeHandle(runtime)
        worker.async {
            do {
                let wavURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("haru-reference-\\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: wavURL) }
                try Self.convertReferenceAudio(sourceURL, to: wavURL)
                var error = [CChar](repeating: 0, count: 1024)
                let makeResult = modelPath.withCString { model in
                    wavURL.path.withCString { wav in
                        voiceURL.path.withCString { voice in
                            error.withUnsafeMutableBufferPointer {
                                HaruRuntimeMakeVoice(model, wav, voice, $0.baseAddress, $0.count)
                            }
                        }
                    }
                }
                guard makeResult == 0 else {
                    let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                    throw NSError(domain: "HaruVoice", code: Int(makeResult),
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                error = [CChar](repeating: 0, count: 1024)
                let addResult = voiceName.withCString { name in
                    voiceURL.path.withCString { path in
                        error.withUnsafeMutableBufferPointer {
                            HaruRuntimeAddVoice(handle.pointer, name, path, $0.baseAddress, $0.count)
                        }
                    }
                }
                guard addResult == 0 else {
                    let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                    throw NSError(domain: "HaruVoice", code: Int(addResult),
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                DispatchQueue.main.async {
                    self.registeredVoiceKeys.insert(voiceName)
                    completion(.success(()))
                }
            } catch {
                try? FileManager.default.removeItem(at: voiceURL)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    nonisolated private static func convertReferenceAudio(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let duration = Double(input.length) / format.sampleRate
        guard duration >= 3.0 else {
            throw NSError(domain: "HaruVoice", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "参照音声は3秒以上必要です"])
        }
        let frames = AVAudioFrameCount(min(duration, 180.0) * format.sampleRate)
        if duration > 180 {
            input.framePosition = input.length - AVAudioFramePosition(frames)
        }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "HaruVoice", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "音声バッファを作成できません"])
        }
        try input.read(into: sourceBuffer, frameCount: frames)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                   channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: target) else {
            throw NSError(domain: "HaruVoice", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "音声形式を変換できません"])
        }
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * 24_000 / format.sampleRate + 2048)
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "HaruVoice", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "変換先バッファを作成できません"])
        }
        var supplied = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: converted, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if conversionStatus == .error {
            throw conversionError ?? NSError(domain: "HaruVoice", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "音声変換に失敗しました"])
        }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        try output.write(from: converted)
    }

    func startDialogue(profile: CharacterProfile, voiceURL: URL?) {
        guard profile.hasVoice else { beginDialogue(profile: profile); return }
        if registeredVoiceKeys.contains(profile.voiceKey) {
            beginDialogue(profile: profile)
            return
        }
        guard let voiceURL else { status = "保存済みボイスファイルが見つかりません"; return }
        registerVoice(name: profile.voiceKey, at: voiceURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.beginDialogue(profile: profile)
            case .failure(let error): self.status = "ボイス読み込み失敗: " + error.localizedDescription
            }
        }
    }

    private func beginDialogue(profile: CharacterProfile) {
        guard let runtime, isModelLoaded else {
            status = "先にHaru GGUFモデルを読み込んでください"
            return
        }
        guard !isDialogueActive, !isDialogueStarting else { return }
        isDialogueStarting = true
        status = "マイクを準備中…"
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.isDialogueStarting = false
                    self.status = "マイクへのアクセスが許可されていません"
                }
                return
            }
            let handle = HaruRuntimeHandle(runtime)
            self.worker.async { [weak self, handle] in
                guard let self else { return }
                do {
                    try self.audioIO.start()
                } catch {
                    DispatchQueue.main.async {
                        self.isDialogueStarting = false
                        self.status = "オーディオ開始失敗: \(error.localizedDescription)"
                    }
                    return
                }

                // The official CLI discards samples captured while start()
                // computes its first frame. Do the same immediately after it
                // returns, before starting the input pump.
                var error = [CChar](repeating: 0, count: 1024)
                let context = Unmanaged.passUnretained(self).toOpaque()
                let sampleRate = Int32(self.audioIO.inputSampleRate.rounded())
                let result = "ja".withCString { language in
                    profile.name.withCString { name in
                        profile.persona.withCString { persona in
                            profile.otherName.withCString { otherName in
                                profile.gender.withCString { gender in
                                    profile.backchannel.withCString { backchannel in
                                        profile.relationship.withCString { relationship in
                                            profile.situation.withCString { situation in
                                                profile.voiceKey.withCString { voice in
                                                    error.withUnsafeMutableBufferPointer {
                                                        HaruRuntimeStartDialogue(handle.pointer, sampleRate, language, name,
                                                            persona, otherName, gender, backchannel, relationship, situation,
                                                            voice, 30.0, 0, haruFrameCallback, context,
                                                            $0.baseAddress, $0.count)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                guard result == 0 else {
                    self.audioIO.stop()
                    DispatchQueue.main.async {
                        self.isDialogueStarting = false
                        self.status = "対話開始失敗: \(message) (code \(result))"
                    }
                    return
                }

                let discarded = self.audioIO.discardPendingInput()
                let startupOverflow = self.audioIO.takeDroppedInputSamples()
                let timer = DispatchSource.makeTimerSource(queue: self.worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
                timer.setEventHandler { [weak self, handle] in
                    guard let self else { return }
                    let queuedBeforePush = self.audioIO.queuedInputSamples()
                    let queuedMilliseconds = Double(queuedBeforePush) / self.audioIO.inputSampleRate * 1000.0
                    let outputQueuedMilliseconds = self.audioIO.queuedOutputMilliseconds()
                    let dropped = self.audioIO.takeDroppedInputSamples()
                    if queuedMilliseconds + outputQueuedMilliseconds > 1_000 || dropped > 0 {
                        self.inputPump?.cancel()
                        self.inputPump = nil
                        var endError = [CChar](repeating: 0, count: 1024)
                        _ = endError.withUnsafeMutableBufferPointer {
                            HaruRuntimeEndDialogue(handle.pointer, $0.baseAddress, $0.count)
                        }
                        self.outputQueue.sync { self.audioIO.stop() }
                        DispatchQueue.main.async {
                            self.isDialogueStarting = false
                            self.isDialogueActive = false
                            self.isAudioRunning = false
                            self.status = "入力遅延が上限を超えたため停止しました。\(Int(queuedMilliseconds))ms / overflow \(dropped) samples"
                            self.inputDiagnostics = "入力遅延超過。端末が推論速度に追いついていません。"
                        }
                        return
                    }

                    // Drain the complete currently queued segment. Sending only
                    // 20 ms after a long inference stall makes the app remain
                    // permanently behind; the upstream CLI submits all audio
                    // accumulated during its microphone polling interval.
                    let pcm = self.audioIO.takeInput()
                    guard !pcm.isEmpty else { return }
                    let pushStart = DispatchTime.now().uptimeNanoseconds
                    var pushError = [CChar](repeating: 0, count: 1024)
                    let pushResult = pcm.withUnsafeBufferPointer { samples in
                        pushError.withUnsafeMutableBufferPointer { errorBuffer in
                            HaruRuntimePushAudio(handle.pointer, samples.baseAddress, samples.count,
                                                 errorBuffer.baseAddress, errorBuffer.count)
                        }
                    }
                    let pushMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - pushStart) / 1_000_000.0
                    DispatchQueue.main.async {
                        self.inputDiagnostics = String(format: "入力 %.0f ms / push %.0f ms / 出力待ち %.0f ms / 初回破棄 %.0f ms",
                                                        Double(pcm.count) / self.audioIO.inputSampleRate * 1000.0,
                                                        pushMilliseconds,
                                                        outputQueuedMilliseconds,
                                                        Double(discarded) / self.audioIO.inputSampleRate * 1000.0)
                    }
                    if pushResult < 0 {
                        let detail = pushError.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
                        self.inputPump?.cancel()
                        self.inputPump = nil
                        var endError = [CChar](repeating: 0, count: 1024)
                        _ = endError.withUnsafeMutableBufferPointer {
                            HaruRuntimeEndDialogue(handle.pointer, $0.baseAddress, $0.count)
                        }
                        self.outputQueue.sync { self.audioIO.stop() }
                        DispatchQueue.main.async {
                            self.isDialogueStarting = false
                            self.isDialogueActive = false
                            self.isAudioRunning = false
                            self.status = "音声処理エラー: \(detail) (code \(pushResult))"
                        }
                    }
                }
                self.inputPump = timer
                timer.resume()
                DispatchQueue.main.async {
                    self.lastText = ""
                    self.lastFrameSamples = 0
                    self.inputDiagnostics = "初回入力破棄: \(Int(Double(discarded) / self.audioIO.inputSampleRate * 1000.0)) ms / 起動中overflow \(startupOverflow)"
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
            self.outputQueue.sync { self.audioIO.stop() }
            let message = error.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
            DispatchQueue.main.async {
                self.isDialogueActive = false
                self.isAudioRunning = false
                self.status = result == 0 ? "対話セッション終了" : "終了時エラー: \(message)"
            }
        }
    }

    nonisolated func receiveOutput(samples: UnsafePointer<Float>?, count: Int, text: UnsafePointer<CChar>?) {
        // C API pointers are valid only during the callback: copy both before
        // returning. Playback is serialized separately from inference/UI work.
        let pcm = samples != nil && count > 0 ? Array(UnsafeBufferPointer(start: samples, count: count)) : []
        let message = text.map { String(cString: $0) } ?? ""
        var sumSquares = 0.0
        var peak = 0.0
        for sample in pcm {
            let value = Double(sample)
            sumSquares += value * value
            peak = max(peak, abs(value))
        }
        let rms = pcm.isEmpty ? 0 : sqrt(sumSquares / Double(pcm.count))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outputQueue.async { [audioIO = self.audioIO] in
                audioIO.play(samples: pcm)
            }
            self.lastFrameSamples = count
            // The API returns text fragments per frame, not a complete transcript.
            // Concatenate them in callback order; do not overwrite with the latest fragment.
            if !message.isEmpty {
                self.lastText += message
                if self.lastText.count > 8_000 {
                    self.lastText = String(self.lastText.suffix(8_000))
                }
            }
            self.outputDiagnostics = String(format: "PCM=%d / RMS=%.4f / peak=%.4f / text=%d bytes",
                                             count, rms, peak, message.utf8.count)
        }
    }

    func startDialogue() { beginDialogue(profile: CharacterProfile()) }

    deinit {
        inputPump?.cancel()
        audioIO.stop()
        if let runtime { HaruRuntimeDestroy(runtime) }
    }
}
