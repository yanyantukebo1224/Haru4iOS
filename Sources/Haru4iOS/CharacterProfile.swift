import Foundation

struct CharacterProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "ハル"
    var name: String = "ハル"
    var persona: String = "日本語で自然に会話する、親しみやすく反応のよい対話相手。"
    var gender: String = ""
    var backchannel: String = "mid"
    var otherName: String = "あなた"
    var relationship: String = ""
    var situation: String = ""
    var voiceKey: String = ""
    var voiceFileName: String = ""

    var hasVoice: Bool { !voiceKey.isEmpty && !voiceFileName.isEmpty }
}

@MainActor
final class CharacterProfileStore: ObservableObject {
    @Published var profiles: [CharacterProfile] = []
    @Published var selectedID: UUID?
    private let directory: URL
    private let metadataURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Haru4iOS/Profiles", isDirectory: true)
        metadataURL = directory.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode([CharacterProfile].self, from: data) {
            profiles = saved
        }
        if profiles.isEmpty { profiles = [CharacterProfile()] }
        selectedID = profiles.first?.id
        persist()
    }

    var selected: CharacterProfile {
        get { profiles.first(where: { $0.id == selectedID }) ?? profiles[0] }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[index] = newValue
            persist()
        }
    }

    func addProfile() {
        let item = CharacterProfile(title: "新しいキャラクター", name: "ハル")
        profiles.append(item)
        selectedID = item.id
        persist()
    }

    func deleteSelected() {
        guard profiles.count > 1, let id = selectedID,
              let item = profiles.first(where: { $0.id == id }) else { return }
        if item.hasVoice { try? FileManager.default.removeItem(at: voiceURL(for: item)) }
        profiles.removeAll { $0.id == id }
        selectedID = profiles.first?.id
        persist()
    }

    func voiceURL(for profile: CharacterProfile) -> URL {
        directory.appendingPathComponent(profile.voiceFileName)
    }

    func replaceVoice(for id: UUID, with source: URL) throws -> (URL, String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "HaruProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "プロファイルが見つかりません"])
        }
        let key = "voice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fileName = key + ".voice.gguf"
        let destination = directory.appendingPathComponent(fileName)
        profiles[index].voiceKey = key
        profiles[index].voiceFileName = fileName
        persist()
        return (destination, key)
    }

    func persist() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) { try? data.write(to: metadataURL, options: .atomic) }
    }
}
