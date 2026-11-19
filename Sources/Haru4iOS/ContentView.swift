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

            Section("Dialogue API スモークテスト") {
                Button("対話セッション開始（初回フレーム生成）") {
                    engine.startDialogue()
                }
                .disabled(engine.isDialogueActive)

                Button("セッション終了", role: .destructive) {
                    engine.stopDialogue()
                }
                .disabled(!engine.isDialogueActive)

                LabeledContent("対話", value: engine.isDialogueActive ? "Active" : "Stopped")
                LabeledContent("最新フレーム", value: "\(engine.lastFrameSamples) samples")
                LabeledContent("認識・発話テキスト",
                               value: engine.lastText.isEmpty ? "（まだありません）" : engine.lastText)
            }

            Section {
                Text("現在はモデルの自動取得・読み込みとDialogue APIのスモークテスト段階です。マイク入力・スピーカー出力はまだ接続していません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
