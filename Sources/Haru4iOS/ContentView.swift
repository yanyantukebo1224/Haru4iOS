import SwiftUI

struct ContentView: View {
    @StateObject private var engine = HaruEngine()
    @StateObject private var installer = HaruModelInstaller()

    var body: some View {
        NavigationStack {
            Group {
                if engine.isModelLoaded {
                    dialogueView
                } else {
                    startupView
                }
            }
            .navigationTitle("Haru4iOS")
        }
        .onAppear {
            installer.installIfNeeded()
        }
        .onChange(of: installer.modelURL) { _, url in
            guard let url else { return }
            engine.loadModel(at: url)
        }
    }

    private var startupView: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.tint)

            Text("Haru-4B")
                .font(.largeTitle.bold())

            Text(engine.isModelLoaded ? engine.status : installer.status)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if !installer.hasError {
                ProgressView(value: installer.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 420)
                Text(installer.progress > 0
                     ? "\(Int(installer.progress * 100))%"
                     : "初回起動時にモデルを取得します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("ダウンロードを再試行") {
                    installer.retry()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("モデルは一度取得すると端末内に保存され、次回以降は再ダウンロードしません。初回のみ大容量通信が発生します。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dialogueView: some View {
        Form {
            Section("モデル") {
                LabeledContent("状態", value: engine.status)
                LabeledContent("モデル", value: "Haru-4B Q4_K")
                LabeledContent("保存先", value: "端末内 / Application Support")
            }

            Section("リアルタイム音声対話") {
                Button("会話を開始（マイク・スピーカー）") {
                    engine.startDialogue()
                }
                .disabled(engine.isDialogueActive)

                Button("セッション終了", role: .destructive) {
                    engine.stopDialogue()
                }
                .disabled(!engine.isDialogueActive)

                LabeledContent("対話", value: engine.isDialogueActive ? "会話中" : "停止中")
                LabeledContent("音声入出力", value: engine.isAudioRunning ? "マイク・スピーカー有効" : "停止中")
                LabeledContent("最新フレーム", value: "\(engine.lastFrameSamples) samples")
                LabeledContent("認識・発話テキスト",
                               value: engine.lastText.isEmpty ? "（まだありません）" : engine.lastText)
            }

            Section {
                Text("Haru Dialogue APIにマイク音声を送り、生成された24 kHz音声をスピーカーへ再生します。音声推論は専用ワーカースレッドで実行されます。初回はマイクの使用許可が必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
