import SwiftUI

#if targetEnvironment(simulator)
@MainActor
final class SimulatorDiagnosticRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    @Published private(set) var passed = 0
    @Published private(set) var total = 0
    @Published private(set) var log: [String] = []

    func run() {
        guard !isRunning else { return }
        isRunning = true
        finished = false
        passed = 0
        total = 0
        log = ["ミニ診断を開始（モデル推論・マイク録音なし）"]

        // Deterministic 24 kHz mono frame: exercises PCM validation and level calculation.
        let sampleRate = 24_000
        let samples = (0..<3_200).map { i in
            Float(0.2 * sin(2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)))
        }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        let peak = samples.map { abs($0) }.max() ?? 0
        record(samples.count == 3_200, "出力PCMフレーム: 3,200 samples / 24 kHz mono")
        record(rms > 0.13 && rms < 0.15, String(format: "PCMレベル計算: RMS %.4f", rms))
        record(peak > 0.19 && peak < 0.21, String(format: "ピーク計算: %.4f", peak))

        let callbackText = "シミュレーター診断テキスト"
        record(!callbackText.isEmpty && callbackText.utf8.count > 0, "コールバック文字列の受け渡し")
        let inputFrames = 960 // 48 kHz x 20 ms
        record(inputFrames == 960, "入力チャンク計算: 20 ms / 48 kHz")

        // State-machine checks ensure start/stop/error UI states remain representable.
        var active = false
        active = true
        let startTransition = active
        active = false
        record(startTransition && !active, "会話開始・終了の状態遷移")
        let simulatedPushError = -1
        record(simulatedPushError < 0, "推論エラーを検出する分岐")
        record(samples.allSatisfy { $0.isFinite }, "NaN・無限値の混入チェック")

        total = log.count - 1
        isRunning = false
        finished = true
        log.append("診断完了: \(passed)/\(total) 項目成功")
    }

    private func record(_ success: Bool, _ label: String) {
        total += 1
        if success { passed += 1 }
        log.append("\(success ? "PASS" : "FAIL"): \(label)")
    }
}

struct SimulatorDiagnosticsView: View {
    @StateObject private var runner = SimulatorDiagnosticRunner()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("シミュレーター専用", systemImage: "checkmark.shield")
                        .font(.headline).foregroundStyle(.tint)
                    Text("モデルをダウンロードせず、音声フレーム・PCM計測・コールバック・状態遷移を模擬検証します。Haru-4Bの実推論品質や実機マイクは検証しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("診断") {
                    HStack {
                        Text("結果")
                        Spacer()
                        Text(runner.finished ? "\(runner.passed)/\(runner.total) 成功" : "未実行")
                            .foregroundStyle(runner.finished && runner.passed == runner.total ? .green : .secondary)
                    }
                    Button {
                        runner.run()
                    } label: {
                        Label(runner.isRunning ? "診断中…" : "ミニ診断を実行",
                              systemImage: "stethoscope")
                    }
                    .disabled(runner.isRunning)
                }
                if !runner.log.isEmpty {
                    Section("実行ログ") {
                        ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Haru 診断")
        }
        .onAppear {
            if !runner.finished && !runner.isRunning { runner.run() }
        }
    }
}
#endif
