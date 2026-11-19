import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = HaruEngine()
    @StateObject private var installer = HaruModelInstaller()
    @StateObject private var profiles = CharacterProfileStore()
    @State private var showingAudioImporter = false
    @State private var voiceBusy = false
    @State private var voiceMessage = ""

    private var profileBinding: Binding<CharacterProfile> {
        Binding(get: { profiles.selected }, set: { profiles.selected = $0 })
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.isModelLoaded { dialogueView } else { startupView }
            }
            .navigationTitle("Haru4iOS")
        }
        .onAppear { installer.installIfNeeded() }
        .onChange(of: installer.modelURL) { _, url in
            guard let url else { return }
            engine.loadModel(at: url)
        }
        .fileImporter(isPresented: $showingAudioImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let url): importVoice(url)
            case .failure(let error): voiceMessage = "ファイル選択失敗: \(error.localizedDescription)"
            }
        }
    }

    private var startupView: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform").font(.system(size: 54, weight: .medium)).foregroundStyle(.tint)
            Text("Haru-4B").font(.largeTitle.bold())
            Text(engine.isModelLoaded ? engine.status : installer.status)
                .font(.headline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if !installer.hasError {
                ProgressView(value: installer.progress).progressViewStyle(.linear).frame(maxWidth: 420)
                Text(installer.progress > 0 ? "\(Int(installer.progress * 100))%" : "初回起動時にモデルを取得します")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("ダウンロードを再試行") { installer.retry() }.buttonStyle(.borderedProminent)
            }
            Text("モデルは一度取得すると端末内に保存され、次回以降は再ダウンロードしません。初回のみ大容量通信が発生します。")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dialogueView: some View {
        Form {
            Section("モデル") {
                LabeledContent("状態", value: engine.status)
                LabeledContent("モデル", value: "Haru-4B Q4_K")
                LabeledContent("保存先", value: "端末内 / Application Support")
            }

            Section("キャラクタープロファイル") {
                Picker("使用するキャラクター", selection: $profiles.selectedID) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.title).tag(Optional(profile.id))
                    }
                }
                HStack {
                    Button("新規作成") { profiles.addProfile() }
                    Spacer()
                    Button("削除", role: .destructive) { profiles.deleteSelected() }
                        .disabled(profiles.profiles.count <= 1)
                }
                TextField("プロファイル名", text: field(\.title))
                TextField("キャラクター名", text: field(\.name))
                TextField("ペルソナ", text: field(\.persona), axis: .vertical).lineLimit(3...7)
                Picker("性別", selection: field(\.gender)) {
                    Text("指定なし").tag("")
                    Text("女性").tag("female")
                    Text("男性").tag("male")
                }
                Picker("相槌の頻度", selection: field(\.backchannel)) {
                    Text("少なめ").tag("low")
                    Text("標準").tag("mid")
                    Text("多め").tag("high")
                }
                TextField("話し相手の名前", text: field(\.otherName))
                TextField("関係性", text: field(\.relationship))
                TextField("会話する状況", text: field(\.situation))

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ボイス")
                        Text(profiles.selected.hasVoice ? "登録済み：このプロファイルに保存" : "未登録：Haru標準ボイスを使用")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("音声を読み込む") { showingAudioImporter = true }
                        .disabled(voiceBusy)
                }
                if voiceBusy { ProgressView("ボイスを作成中…") }
                if !voiceMessage.isEmpty {
                    Text(voiceMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("音声は3秒以上必要です。読み込み可能な音声形式は端末のデコーダーに依存します。取り込んだ音声は内部で変換され、ボイスデータとペルソナが一緒に保存されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("リアルタイム音声対話") {
                Button("会話を開始（マイク・スピーカー）") {
                    engine.startDialogue(profile: profiles.selected)
                }.disabled(engine.isDialogueActive || voiceBusy)
                Button("セッション終了", role: .destructive) {
                    engine.stopDialogue()
                }.disabled(!engine.isDialogueActive)
                LabeledContent("対話", value: engine.isDialogueActive ? "会話中" : "停止中")
                LabeledContent("音声入出力", value: engine.isAudioRunning ? "マイク・スピーカー有効" : "停止中")
                LabeledContent("最新フレーム", value: "\(engine.lastFrameSamples) samples")
                LabeledContent("認識・発話テキスト",
                               value: engine.lastText.isEmpty ? "（まだありません）" : engine.lastText)
            }
            Section {
                Text("Haru Dialogue APIにマイク音声を送り、生成された24 kHz音声をスピーカーへ再生します。音声推論は専用ワーカースレッドで実行されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func field<T>(_ keyPath: WritableKeyPath<CharacterProfile, T>) -> Binding<T> {
        Binding(get: { profiles.selected[keyPath: keyPath] }, set: { value in
            var updated = profiles.selected
            updated[keyPath: keyPath] = value
            profiles.selected = updated
        })
    }

    private func importVoice(_ source: URL) {
        let id = profiles.selected.id
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (destination, key) = profiles.newVoiceDestination(for: profiles.selected)
        voiceBusy = true
        voiceMessage = "音声を解析・変換しています…"
        engine.makeAndRegisterVoice(from: source, voiceURL: destination, voiceName: key) { result in
            voiceBusy = false
            switch result {
            case .success:
                profiles.setVoice(for: id, key: key, fileName: destination.lastPathComponent)
                voiceMessage = "ボイスを登録し、プロファイルに保存しました"
            case .failure(let error):
                voiceMessage = "ボイス登録失敗: \(error.localizedDescription)"
            }
        }
    }
}
