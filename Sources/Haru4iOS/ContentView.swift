import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = HaruEngine()
    @StateObject private var installer = HaruModelInstaller()
    @StateObject private var profiles = CharacterProfileStore()

    var body: some View {
        #if targetEnvironment(simulator)
        SimulatorDiagnosticsView()
        #else
        NavigationStack {
            Group {
                if engine.isModelLoaded {
                    ConversationHomeView(engine: engine, profiles: profiles)
                } else {
                    ModelLoadingView(engine: engine, installer: installer)
                }
            }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            AppSettingsView(engine: engine, installer: installer, profiles: profiles)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("設定")
                    }
                }
        }
        .onAppear { installer.installIfNeeded() }
        .onChange(of: installer.modelURL) { _, url in
            guard let url else { return }
            engine.loadModel(at: url)
        }
        #endif
    }
}


private struct ModelLoadingView: View {
    @ObservedObject var engine: HaruEngine
    @ObservedObject var installer: HaruModelInstaller

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Haru-4B").font(.largeTitle.bold())
            Text(engine.status == "モデル未読み込み" ? installer.status : engine.status)
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if installer.hasError {
                Button("ダウンロードを再試行") { installer.retry() }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView(value: installer.progress).frame(maxWidth: 320)
                Text(installer.progress > 0 ? "\(Int(installer.progress * 100))%" : "初回起動時にモデルを準備します")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("モデルは端末内に保存されます。初回のみ約4.5 GBのダウンロードが必要です。")
                .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Haru").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConversationHomeView: View {
    @ObservedObject var engine: HaruEngine
    @ObservedObject var profiles: CharacterProfileStore

    private var selectedVoiceURL: URL? {
        profiles.selected.hasVoice ? profiles.voiceURL(for: profiles.selected) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: engine.isDialogueActive ? "waveform" : "waveform")
                    .font(.title2).foregroundStyle(engine.isDialogueActive ? .green : .secondary)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(profiles.selected.title).font(.headline)
                    Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if engine.isDialogueActive {
                    Label("LIVE", systemImage: "circle.fill")
                        .font(.caption2.bold()).foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if engine.lastText.isEmpty {
                        ContentUnavailableView("会話を始めよう", systemImage: "waveform",
                            description: Text("開始ボタンを押すと、Haruがマイク入力を聞きながらリアルタイムで応答します。"))
                            .padding(.top, 54)
                    } else {
                        Text(engine.lastText)
                            .font(.title3).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(20)
            }

            VStack(spacing: 10) {
                if engine.isDialogueActive {
                    Button(role: .destructive) { engine.stopDialogue() } label: {
                        Label("会話を終了", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity).frame(height: 54)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        engine.startDialogue(profile: profiles.selected, voiceURL: selectedVoiceURL)
                    } label: {
                        Label(engine.isDialogueStarting ? "準備中…" : "会話を始める",
                              systemImage: engine.isDialogueStarting ? "hourglass" : "mic.fill")
                            .frame(maxWidth: .infinity).frame(height: 58)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.isDialogueStarting || !engine.isModelLoaded)
                }
                Text(engine.isDialogueStarting ? "モデルを準備しています" :
                     (engine.isDialogueActive ? "マイクとスピーカーが有効です" : "設定は右上のメニューから変更できます"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            .background(.bar)
        }
        .navigationTitle("Haru")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusLabel: String {
        if engine.isDialogueStarting { return "接続準備中" }
        if engine.isDialogueActive { return "会話中" }
        if engine.isModelLoaded { return "準備完了" }
        return engine.status
    }
}

private struct AppSettingsView: View {
    @ObservedObject var engine: HaruEngine
    @ObservedObject var installer: HaruModelInstaller
    @ObservedObject var profiles: CharacterProfileStore

    var body: some View {
        List {
            Section("キャラクター") {
                NavigationLink {
                    CharacterSettingsView(profiles: profiles)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("キャラクター設定")
                            Text(profiles.selected.title + " · " + profiles.selected.name)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "person.crop.circle") }
                }
                NavigationLink {
                    VoiceSettingsView(engine: engine, profiles: profiles)
                } label: {
                    Label("ボイス設定", systemImage: "waveform.badge.mic")
                }
            }
            Section("アプリ") {
                NavigationLink {
                    ModelStatusView(engine: engine, installer: installer)
                } label: {
                    Label("モデルとストレージ", systemImage: "externaldrive")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CharacterSettingsView: View {
    @ObservedObject var profiles: CharacterProfileStore

    var body: some View {
        Form {
            Section("使用するキャラクター") {
                Picker("キャラクター", selection: $profiles.selectedID) {
                    ForEach(profiles.profiles) { profile in
                        Text(profile.title).tag(Optional(profile.id))
                    }
                }
                HStack {
                    Button { profiles.addProfile() } label: { Label("新規作成", systemImage: "plus") }
                    Spacer()
                    Button(role: .destructive) { profiles.deleteSelected() } label: {
                        Label("削除", systemImage: "trash")
                    }.disabled(profiles.profiles.count <= 1)
                }
            }
            Section("基本情報") {
                TextField("表示名", text: field(\.title))
                TextField("キャラクター名", text: field(\.name))
                TextField("話し相手の名前", text: field(\.otherName))
            }
            Section("性格・会話") {
                TextField("ペルソナ", text: field(\.persona), axis: .vertical).lineLimit(4...8)
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
                TextField("関係性", text: field(\.relationship))
                TextField("会話する状況", text: field(\.situation))
            }
        }
        .navigationTitle("キャラクター")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field<T>(_ keyPath: WritableKeyPath<CharacterProfile, T>) -> Binding<T> {
        Binding(get: { profiles.selected[keyPath: keyPath] }, set: { value in
            var updated = profiles.selected
            updated[keyPath: keyPath] = value
            profiles.selected = updated
        })
    }
}

private struct VoiceSettingsView: View {
    @ObservedObject var engine: HaruEngine
    @ObservedObject var profiles: CharacterProfileStore
    @State private var showingImporter = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("登録済みボイス") {
                LabeledContent("状態", value: profiles.selected.hasVoice ? "カスタムボイス" : "Haru標準ボイス")
                Button { showingImporter = true } label: {
                    Label("音声ファイルを読み込む", systemImage: "plus")
                }.disabled(busy || engine.isDialogueActive || engine.isDialogueStarting)
                if busy { ProgressView("ボイスを作成中…") }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Text("3秒以上の音声を選択してください。形式は端末が読み込める音声ファイルに対応します。元音声と生成したボイスは端末内に保存されます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ボイス")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { message = "ファイルが選択されていません"; return }
                importVoice(url)
            case .failure(let error): message = "ファイル選択失敗: " + error.localizedDescription
            }
        }
    }

    private func importVoice(_ source: URL) {
        let selected = profiles.selected
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (destination, key) = profiles.newVoiceDestination(for: selected)
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let recording = profiles.sourceAudioDestination(for: key, fileExtension: ext)
        do { try FileManager.default.copyItem(at: source, to: recording) }
        catch { message = "音声を保存できません: " + error.localizedDescription; return }
        busy = true
        message = "音声を解析しています…"
        engine.makeAndRegisterVoice(from: recording, voiceURL: destination, voiceName: key) { result in
            busy = false
            switch result {
            case .success:
                profiles.setVoice(for: selected.id, key: key, fileName: destination.lastPathComponent,
                                  sourceAudioFileName: recording.lastPathComponent)
                message = "このキャラクターにボイスを登録しました"
            case .failure(let error):
                try? FileManager.default.removeItem(at: recording)
                message = "登録失敗: " + error.localizedDescription
            }
        }
    }
}

private struct ModelStatusView: View {
    @ObservedObject var engine: HaruEngine
    @ObservedObject var installer: HaruModelInstaller

    var body: some View {
        List {
            Section("モデル") {
                LabeledContent("モデル", value: "Haru-4B Q4_K")
                LabeledContent("状態", value: engine.status)
                LabeledContent("保存先", value: "端末内")
            }
            Section("ダウンロード") {
                Text(installer.status).font(.footnote).foregroundStyle(.secondary)
                if installer.progress > 0 && installer.progress < 1 {
                    ProgressView(value: installer.progress)
                }
                if installer.hasError {
                    Button("再試行") { installer.retry() }
                }
            }
        }
        .navigationTitle("モデル")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutView: View {
    var body: some View {
        List {
            LabeledContent("アプリ", value: "Haru4iOS")
            LabeledContent("推論", value: "端末内で実行")
            LabeledContent("通信", value: "初回モデル取得時のみ")
        }
        .navigationTitle("このアプリについて")
    }
}
