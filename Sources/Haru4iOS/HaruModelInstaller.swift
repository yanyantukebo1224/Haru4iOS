import Foundation
import CryptoKit
import Combine

/// Downloads the speech.cpp-compatible Haru Q4_K model on first launch.
/// The model is stored in Application Support, never in the app bundle.
final class HaruModelInstaller: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var status = "モデルの準備を確認中…"
    @Published private(set) var progress: Double = 0
    @Published private(set) var modelURL: URL?
    @Published private(set) var hasError = false

    private static let modelFileName = "Haru-4B-Q4_K.gguf"
    private static let remoteModelURL = URL(string:
        "https://huggingface.co/sakasegawa/Haru-4B-GGUF/resolve/main/Haru-4B-Q4_K.gguf?download=true"
    )!
    private static let expectedBytes: Int64 = 4_522_673_920
    private static let expectedSHA256 =
        "e0e5fdd049b41c0510cac04f30468795565ec7f532aeb4552730d75406be19df"
    private static let verifiedModelDefaultsKey = "Haru4iOS.VerifiedModelSHA256.v1"

    private let fileManager = FileManager.default
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var started = false

    private var modelDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HaruModels", isDirectory: true)
    }

    private var destinationURL: URL {
        modelDirectory.appendingPathComponent(Self.modelFileName)
    }

    private var stagingURL: URL {
        modelDirectory.appendingPathComponent(Self.modelFileName + ".partial")
    }

    private var resumeDataURL: URL {
        modelDirectory.appendingPathComponent("HaruModelDownload.resume")
    }

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 8
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func installIfNeeded() {
        guard !started else { return }
        started = true

        #if targetEnvironment(simulator)
        // Simulator runs are for UI/startup crash diagnosis only. Never download
        // the multi-gigabyte model or attempt inference in the simulator smoke test.
        publish(status: "シミュレーター検証モード（モデル取得・推論は無効）", progress: 0, error: false)
        return
        #endif

        publish(status: "保存済みモデルを確認中…", progress: 0, error: false)

        let fileURL = destinationURL
        // Once the exact model has passed SHA-256 verification, persist that fact.
        // Future launches only check the marker and file existence; they do not re-hash 4.5 GB.
        if fileManager.fileExists(atPath: fileURL.path),
           UserDefaults.standard.string(forKey: Self.verifiedModelDefaultsKey) == Self.expectedSHA256 {
            publish(status: "検証済みモデルを読み込み中…", progress: 1, error: false)
            modelURL = fileURL
            return
        }

        let partialURL = stagingURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let destinationValid = self.isValidModel(at: fileURL)
            let partialExists = self.fileManager.fileExists(atPath: partialURL.path)
            let partialValid = !destinationValid && partialExists && self.isValidModel(at: partialURL)
            DispatchQueue.main.async {
                if destinationValid {
                    UserDefaults.standard.set(Self.expectedSHA256, forKey: Self.verifiedModelDefaultsKey)
                    self.publish(status: "初回検証完了。モデルを読み込み中…", progress: 1, error: false)
                    self.modelURL = fileURL
                } else if partialValid {
                    do {
                        try? self.fileManager.removeItem(at: fileURL)
                        try self.fileManager.moveItem(at: partialURL, to: fileURL)
                        UserDefaults.standard.set(Self.expectedSHA256, forKey: Self.verifiedModelDefaultsKey)
                        self.publish(status: "中断前のダウンロードを復旧しました。モデルを読み込み中…", progress: 1, error: false)
                        self.modelURL = fileURL
                    } catch {
                        self.beginDownload()
                    }
                } else {
                    if partialExists { try? self.fileManager.removeItem(at: partialURL) }
                    UserDefaults.standard.removeObject(forKey: Self.verifiedModelDefaultsKey)
                    self.beginDownload()
                }
            }
        }
    }

    func retry() {
        guard downloadTask == nil else { return }
        hasError = false
        started = true
        beginDownload()
    }

    private func beginDownload() {
        do {
            try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            publish(status: "Haru-4B Q4_K をダウンロード中…", progress: 0, error: false)

            if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
                try? fileManager.removeItem(at: resumeDataURL)
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: Self.remoteModelURL)
            }
            downloadTask?.resume()
        } catch {
            fail("保存先を作成できません: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.expectedBytes
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        DispatchQueue.main.async {
            self.progress = fraction
            let received = Self.byteString(totalBytesWritten)
            let expected = Self.byteString(total)
            self.status = "ダウンロード中… \(received) / \(expected)"
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let stagingURL = self.stagingURL
            try? fileManager.removeItem(at: stagingURL)
            try fileManager.moveItem(at: location, to: stagingURL)
            try? fileManager.removeItem(at: resumeDataURL)

            DispatchQueue.main.async {
                self.publish(status: "ダウンロード完了。ファイルを検証中…", progress: 1, error: false)
            }

            DispatchQueue.global(qos: .utility).async {
                do {
                    guard try Self.validateModel(at: stagingURL) else {
                        throw InstallerError.integrityCheckFailed
                    }
                    try? self.fileManager.removeItem(at: self.destinationURL)
                    try self.fileManager.moveItem(at: stagingURL, to: self.destinationURL)
                    DispatchQueue.main.async {
                        UserDefaults.standard.set(Self.expectedSHA256, forKey: Self.verifiedModelDefaultsKey)
                        self.downloadTask = nil
                        self.publish(status: "初回検証完了。モデルを読み込み中…", progress: 1, error: false)
                        self.modelURL = self.destinationURL
                    }
                } catch {
                    try? self.fileManager.removeItem(at: stagingURL)
                    DispatchQueue.main.async {
                        UserDefaults.standard.removeObject(forKey: Self.verifiedModelDefaultsKey)
                        self.downloadTask = nil
                        self.fail("モデル検証に失敗しました: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.fail("ダウンロードファイルを保存できません: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }
        DispatchQueue.main.async {
            self.downloadTask = nil
            self.fail("ダウンロードに失敗しました。通信を確認して再試行してください。")
        }
    }

    private func isValidModel(at url: URL) -> Bool {
        (try? Self.validateModel(at: url)) == true
    }

    private static func validateModel(at url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value == expectedBytes else { return false }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256
    }

    private func publish(status: String, progress: Double, error: Bool) {
        self.status = status
        self.progress = progress
        self.hasError = error
    }

    private func fail(_ message: String) {
        publish(status: message, progress: progress, error: true)
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private enum InstallerError: LocalizedError {
        case integrityCheckFailed
        var errorDescription: String? {
            "ファイルサイズまたはSHA-256が配布元の値と一致しません"
        }
    }
}
