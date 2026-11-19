import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = HaruEngine()
    @State private var showingImporter = false
    @State private var selectedModelName = "未選択"

    private var ggufType: UTType {
        UTType(filenameExtension: "gguf") ?? .data
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("モデル") {
                    LabeledContent("ファイル", value: selectedModelName)
                    Button("Haru GGUFを選択") {
                        showingImporter = true
                    }
                    .disabled(engine.isModelLoaded)
                }

                Section("ランタイム") {
                    LabeledContent("状態", value: engine.status)
                    LabeledContent("モデル", value: engine.isModelLoaded ? "Loaded" : "Not loaded")
                    LabeledContent("対話", value: engine.isDialogueActive ? "Active" : "Stopped")
                }

                Section("Dialogue API スモークテスト") {
                    Button("対話セッション開始（初回フレーム生成）") {
                        engine.startDialogue()
                    }
                    .disabled(!engine.isModelLoaded || engine.isDialogueActive)

                    Button("セッション終了", role: .destructive) {
                        engine.stopDialogue()
                    }
                    .disabled(!engine.isDialogueActive)

                    LabeledContent("最新フレーム", value: "\(engine.lastFrameSamples) samples")
                    LabeledContent("認識・発話テキスト", value: engine.lastText.isEmpty ? "（まだありません）" : engine.lastText)
                }

                Section {
                    Text("これはランタイムとHaruのDialogue APIを確認する初期テスト画面です。現在はマイク入力・スピーカー出力をまだ接続していません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Haru4iOS")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [ggufType],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let source = try result.get().first else { return }
                    let didAccess = source.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { source.stopAccessingSecurityScopedResource() }
                    }
                    let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent(source.lastPathComponent)
                    if source.standardizedFileURL != destination.standardizedFileURL {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                    selectedModelName = destination.lastPathComponent
                    engine.loadModel(at: destination)
                } catch {
                    selectedModelName = "読み込みエラー: \(error.localizedDescription)"
                }
            }
        }
    }
}
