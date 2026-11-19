import Foundation
import Combine

private let haruFrameCallback: HaruFrameCallback = { samples, count, text, context in
    guard let context else { return 0 }
    let engine = Unmanaged<HaruEngine>.fromOpaque(context).takeUnretainedValue()
    let pcm: [Float]
    if let samples, count > 0 {
        pcm = Array(UnsafeBufferPointer(start: samples, count: count))
    } else {
        pcm = []
    }
    let message = text.map { String(cString: $0) } ?? ""
    engine.receiveFrame(samples: pcm, text: message)
    return 0
}

@MainActor
final class HaruEngine: ObservableObject {
    @Published private(set) var status = "モデル未読み込み"
    @Published private(set) var lastText = ""
    @Published private(set) var lastFrameSamples = 0
    @Published private(set) var isModelLoaded = false
    @Published private(set) var isDialogueActive = false

    private let worker = DispatchQueue(label: "dev.haru4ios.inference", qos: .userInitiated)
    private var runtime: OpaquePointer?

    init() {
        runtime = HaruRuntimeCreate()
        if runtime == nil {
            status = "ネイティブランタイムの作成に失敗"
        }
    }

    func loadModel(at url: URL) {
        guard let runtime else {
            status = "ランタイムが初期化されていません"
            return
        }
        status = "モデルを読み込み中…"
        worker.async { [weak self] in
            guard let self else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let result = url.path.withCString { path in
                "auto".withCString { device in
                    error.withUnsafeMutableBufferPointer { buffer in
                        HaruRuntimeLoadModel(runtime, path, device, 4, buffer.baseAddress, buffer.count)
                    }
                }
            }
            let message = error.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { String(cString: $0) } ?? ""
            }
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
        status = "対話セッションを開始中…"
        worker.async { [weak self] in
            guard let self else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = "ja".withCString { language in
                "ハル".withCString { name in
                    "日本語で自然に会話する、親しみやすく反応のよい対話相手。".withCString { persona in
                        "あなた".withCString { otherName in
                            error.withUnsafeMutableBufferPointer { buffer in
                                HaruRuntimeStartDialogue(
                                    runtime, 24_000, language, name, persona, otherName,
                                    30.0, 1, haruFrameCallback, context,
                                    buffer.baseAddress, buffer.count
                                )
                            }
                        }
                    }
                }
            }
            let message = error.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { String(cString: $0) } ?? ""
            }
            DispatchQueue.main.async {
                if result == 0 {
                    self.isDialogueActive = true
                    self.status = "対話セッション開始。マイク接続は次の実装段階です。"
                } else {
                    self.status = "対話開始失敗: \(message) (code \(result))"
                }
            }
        }
    }

    func stopDialogue() {
        guard let runtime, isDialogueActive else { return }
        worker.async { [weak self] in
            guard let self else { return }
            var error = [CChar](repeating: 0, count: 1024)
            let result = error.withUnsafeMutableBufferPointer { buffer in
                HaruRuntimeEndDialogue(runtime, buffer.baseAddress, buffer.count)
            }
            let message = error.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { String(cString: $0) } ?? ""
            }
            DispatchQueue.main.async {
                self.isDialogueActive = false
                self.status = result == 0 ? "対話セッション終了" : "終了時エラー: \(message)"
            }
        }
    }

    nonisolated func receiveFrame(samples: [Float], text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastFrameSamples = samples.count
            if !text.isEmpty {
                self?.lastText = text
            }
        }
    }

    deinit {
        if let runtime {
            HaruRuntimeDestroy(runtime)
        }
    }
}
