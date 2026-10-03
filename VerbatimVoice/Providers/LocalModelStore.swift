import CryptoKit
import Foundation

/// Where the local SenseVoice runtime comes from. A build can bundle it
/// (Contents/Resources/SenseVoice, the "full" build) or leave it out (the "lite"
/// build) and fetch it into ~/Library/Application Support/<data dir>/models on
/// first use. The bundled copy wins when both exist.
///
/// URLs and SHA-256 values are the ones in scripts/setup_local_sensevoice.sh;
/// scripts/verify.sh fails when the two drift apart.
enum LocalModelFiles {
    static let bundledDirectoryName = "SenseVoice"
    static let executableName = "llama-funasr-sensevoice"
    static let modelName = "sensevoice-small-q8.gguf"
    static let vadName = "fsmn-vad.gguf"

    enum Source: Equatable {
        case bundled
        case downloaded
    }

    struct Asset {
        enum Kind {
            /// A gzip tarball holding `executableName`; the executable has its own hash.
            case runtimeArchive
            case file(name: String)
        }

        let key: String
        let label: String
        let url: URL
        let sha256: String
        let kind: Kind
        /// Only used to weigh the progress bar before the server reports a length.
        let approximateBytes: Int64
    }

    static let runtimeArchive = Asset(
        key: "runtime",
        label: "运行程序",
        url: URL(string: "https://github.com/QwenAudio/SenseVoice/releases/download/runtime-llamacpp-v0.1.9/funasr-llamacpp-macos-arm64.tar.gz")!,
        sha256: "2d5786784ad09d8f4def1d942f678728638fe601d00acf0dad7cf094a9328363",
        kind: .runtimeArchive,
        approximateBytes: 7_017_860
    )
    static let executableSHA256 = "49d66b2f79d439e2db7933627e1deb9eb7f3ebf0d708473757828130f3619435"
    static let model = Asset(
        key: "model",
        label: "识别模型",
        url: URL(string: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF/resolve/main/sensevoice-small-q8.gguf")!,
        sha256: "4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5",
        kind: .file(name: modelName),
        approximateBytes: 254_208_320
    )
    static let vad = Asset(
        key: "vad",
        label: "语音检测模型",
        url: URL(string: "https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/resolve/main/fsmn-vad.gguf")!,
        sha256: "1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479",
        kind: .file(name: vadName),
        approximateBytes: 1_720_512
    )
    static let assets = [runtimeArchive, model, vad]
    static let approximateTotalBytes = assets.reduce(Int64(0)) { $0 + $1.approximateBytes }

    /// ~/Library/Application Support/<data dir>/models
    static func downloadedDirectory(supportDirectory: URL? = nil) -> URL {
        let root = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppIdentity.dataDirectory(in: root).appendingPathComponent("models", isDirectory: true)
    }

    static func bundledDirectory(resources: URL? = Bundle.main.resourceURL) -> URL? {
        resources?.appendingPathComponent(bundledDirectoryName, isDirectory: true)
    }

    static func isComplete(_ directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: directory.appendingPathComponent(executableName).path)
            && fm.fileExists(atPath: directory.appendingPathComponent(modelName).path)
            && fm.fileExists(atPath: directory.appendingPathComponent(vadName).path)
    }

    /// The runtime directory the provider should use: bundled first, then downloaded.
    static func current(
        bundled: URL? = bundledDirectory(),
        downloaded: URL = downloadedDirectory()
    ) -> (directory: URL, source: Source)? {
        if let bundled, isComplete(bundled) { return (bundled, .bundled) }
        if isComplete(downloaded) { return (downloaded, .downloaded) }
        return nil
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

enum LocalModelError: LocalizedError {
    case checksum(String)
    case extraction(String)

    var errorDescription: String? {
        switch self {
        case .checksum(let label): return "\(label)校验失败，已删除下载的文件"
        case .extraction(let detail): return "运行程序解压失败：\(detail)"
        }
    }
}

/// Downloads and verifies the local model. One instance per process: the
/// background URLSession identifier is derived from the bundle ID.
@MainActor
final class LocalModelStore: ObservableObject {
    struct Progress: Equatable {
        var receivedBytes: Int64
        var totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    }

    enum FailureKind: Equatable {
        case checksum
        case network
        case other
    }

    enum Status: Equatable {
        case bundled
        case installed
        case notInstalled
        case downloading(Progress)
        case verifying
        case failed(kind: FailureKind, message: String)
    }

    @Published private(set) var status: Status = .notInstalled
    /// Called on the main actor whenever availability may have changed.
    var onChange: (() -> Void)?

    private let modelsDirectory: URL
    private let partialDirectory: URL
    private let bundledDirectory: URL?
    private let relay: DownloadRelay
    private var session: URLSession?

    /// Assets of the current attempt, their progress, and where each one stands:
    /// `pending` until installed, `verifying` once its bytes have arrived.
    private var tracked: [String] = []
    private var received: [String: Int64] = [:]
    private var expected: [String: Int64] = [:]
    private var pending: Set<String> = []
    private var verifying: Set<String> = []
    private var resumeData: [String: Data] = [:]
    private var userCancelled = false
    private var lastPublishedFraction = -1.0

    /// `modelsDirectory` and `bundledDirectory` exist for tests; the app uses the defaults.
    init(modelsDirectory: URL? = nil, bundledDirectory: URL? = LocalModelFiles.bundledDirectory()) {
        let models = modelsDirectory ?? LocalModelFiles.downloadedDirectory()
        self.modelsDirectory = models
        self.partialDirectory = models.appendingPathComponent(".partial", isDirectory: true)
        self.bundledDirectory = bundledDirectory
        self.relay = DownloadRelay(partialDirectory: partialDirectory)
        relay.store = self
        refresh()
    }

    var isAvailable: Bool { LocalModelFiles.current(bundled: bundledDirectory, downloaded: modelsDirectory) != nil }

    /// Re-reads the disk, and re-attaches to a download that kept running while
    /// the app was closed.
    func refresh() {
        switch status {
        case .downloading, .verifying: return
        default: break
        }
        if let current = LocalModelFiles.current(bundled: bundledDirectory, downloaded: modelsDirectory) {
            status = current.source == .bundled ? .bundled : .installed
            return
        }
        if case .failed = status { return }
        status = .notInstalled
        // An unfinished session from an earlier launch may still be running.
        activeSession().getAllTasks { [weak self] tasks in
            let keys = tasks.compactMap(\.taskDescription)
            guard !keys.isEmpty else { return }
            Task { @MainActor [weak self] in self?.reattach(keys: keys) }
        }
    }

    func startDownload() {
        switch status {
        case .notInstalled, .failed: break
        default: return
        }
        do {
            try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        } catch {
            status = .failed(kind: .other, message: "无法创建模型目录：\(error.localizedDescription)")
            return
        }
        userCancelled = false
        received = [:]
        expected = [:]
        pending = []
        verifying = []
        lastPublishedFraction = -1
        let session = activeSession()
        for asset in LocalModelFiles.assets where !isInstalled(asset) {
            pending.insert(asset.key)
            let task: URLSessionDownloadTask
            if let data = resumeData.removeValue(forKey: asset.key) {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: asset.url)
            }
            task.taskDescription = asset.key
            task.resume()
        }
        tracked = LocalModelFiles.assets.map(\.key).filter { pending.contains($0) }
        if pending.isEmpty {
            finishIfComplete()
        } else {
            publishProgress(force: true)
        }
    }

    /// Stops the transfer and keeps what was received, so the next start resumes.
    func cancelDownload() {
        guard case .downloading = status else { return }
        userCancelled = true
        activeSession().getAllTasks { [weak self] tasks in
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask, let key = task.taskDescription else { continue }
                download.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    Task { @MainActor [weak self] in self?.resumeData[key] = data }
                })
            }
        }
        pending = []
        verifying = []
        status = .notInstalled
    }

    /// Removes the downloaded copy (the bundled one is part of the app).
    func removeDownloadedFiles() {
        guard !isDownloading else { return }
        try? FileManager.default.removeItem(at: modelsDirectory)
        status = .notInstalled
        refresh()
        onChange?()
    }

    private var isDownloading: Bool {
        if case .downloading = status { return true }
        if case .verifying = status { return true }
        return false
    }

    // MARK: - Session

    private func activeSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(AppIdentity.bundleID).model-download")
        configuration.isDiscretionary = false
        // Background transfers wait for the network by themselves; this bound turns a
        // transfer that never gets going into a "failed, retry" state.
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        configuration.allowsCellularAccess = true
        let created = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
        session = created
        return created
    }

    private func reattach(keys: [String]) {
        guard case .notInstalled = status else { return }
        userCancelled = false
        pending = Set(keys)
        verifying = []
        tracked = LocalModelFiles.assets.map(\.key).filter { pending.contains($0) }
        publishProgress(force: true)
    }

    private func isInstalled(_ asset: LocalModelFiles.Asset) -> Bool {
        let fm = FileManager.default
        switch asset.kind {
        case .runtimeArchive:
            return fm.isExecutableFile(atPath: modelsDirectory.appendingPathComponent(LocalModelFiles.executableName).path)
        case .file(let name):
            return fm.fileExists(atPath: modelsDirectory.appendingPathComponent(name).path)
        }
    }

    // MARK: - Events from the session (hopped onto the main actor by DownloadRelay)

    fileprivate func didWrite(key: String, total: Int64, expectedTotal: Int64) {
        guard !userCancelled else { return }
        received[key] = total
        if expectedTotal > 0 { expected[key] = expectedTotal }
        publishProgress(force: false)
    }

    fileprivate func didDownload(key: String, file: URL) {
        guard let asset = LocalModelFiles.assets.first(where: { $0.key == key }) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard pending.contains(key) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        received[key] = expected[key] ?? asset.approximateBytes
        verifying.insert(key)
        publishProgress(force: true)
        let models = modelsDirectory
        Task.detached(priority: .utility) {
            let result = Result { try Self.install(asset: asset, from: file, into: models) }
            await self.installed(key: key, result: result)
        }
    }

    private func installed(key: String, result: Result<Void, Error>) {
        verifying.remove(key)
        // A sibling transfer already failed or the user cancelled: the verified
        // file stays on disk for the next attempt, but the status is not ours to set.
        guard pending.contains(key) else { return }
        switch result {
        case .success:
            pending.remove(key)
            finishIfComplete()
        case .failure(let error):
            abandonTransfers()
            let kind: FailureKind
            if case LocalModelError.checksum = error { kind = .checksum } else { kind = .other }
            status = .failed(kind: kind, message: error.localizedDescription)
            onChange?()
        }
    }

    fileprivate func didFail(key: String, error: Error) {
        // Transfers cancelled by `abandonTransfers` or `cancelDownload` report here too.
        guard !userCancelled, pending.contains(key) else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { resumeData[key] = data }
        abandonTransfers()
        let detail = nsError.domain == NSURLErrorDomain
            ? "网络中断（\(error.localizedDescription)）"
            : error.localizedDescription
        status = .failed(kind: .network, message: detail)
        onChange?()
    }

    /// Stops the other transfers of a failed attempt, keeping their resume data.
    private func abandonTransfers() {
        pending = []
        verifying = []
        activeSession().getAllTasks { [weak self] tasks in
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask, let key = task.taskDescription else { continue }
                download.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    Task { @MainActor [weak self] in self?.resumeData[key] = data }
                })
            }
        }
    }

    private func finishIfComplete() {
        guard pending.isEmpty else {
            publishProgress(force: true)
            return
        }
        if LocalModelFiles.isComplete(modelsDirectory) {
            try? FileManager.default.removeItem(at: partialDirectory)
            resumeData = [:]
            status = isAvailableFromBundle ? .bundled : .installed
            onChange?()
        } else {
            status = .failed(kind: .other, message: "模型文件不完整，请重试")
            onChange?()
        }
    }

    private var isAvailableFromBundle: Bool {
        LocalModelFiles.current(bundled: bundledDirectory, downloaded: modelsDirectory)?.source == .bundled
    }

    private func publishProgress(force: Bool) {
        let total = LocalModelFiles.assets
            .filter { tracked.contains($0.key) }
            .reduce(Int64(0)) { $0 + (expected[$1.key] ?? $1.approximateBytes) }
        let done = tracked.reduce(Int64(0)) { $0 + (received[$1] ?? 0) }
        let progress = Progress(receivedBytes: min(done, max(total, 1)), totalBytes: max(total, 1))
        if !pending.isEmpty, pending.isSubset(of: verifying) {
            status = .verifying
            return
        }
        if !force, abs(progress.fraction - lastPublishedFraction) < 0.005 { return }
        lastPublishedFraction = progress.fraction
        status = .downloading(progress)
    }

    // MARK: - Verification and installation (off the main actor)

    private nonisolated static func install(
        asset: LocalModelFiles.Asset,
        from downloaded: URL,
        into modelsDirectory: URL
    ) throws {
        let fm = FileManager.default
        guard try sha256(of: downloaded) == asset.sha256 else {
            try? fm.removeItem(at: downloaded)
            throw LocalModelError.checksum(asset.label)
        }
        try fm.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        switch asset.kind {
        case .file(let name):
            try makeUsable(downloaded, permissions: 0o644)
            try place(downloaded, at: modelsDirectory.appendingPathComponent(name))
        case .runtimeArchive:
            let staging = downloaded.deletingLastPathComponent()
                .appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try extract(archive: downloaded, to: staging)
            let executable = staging.appendingPathComponent(LocalModelFiles.executableName)
            guard fm.fileExists(atPath: executable.path) else {
                throw LocalModelError.extraction("压缩包里没有 \(LocalModelFiles.executableName)")
            }
            guard try sha256(of: executable) == LocalModelFiles.executableSHA256 else {
                throw LocalModelError.checksum(asset.label)
            }
            try makeUsable(executable, permissions: 0o755)
            try place(executable, at: modelsDirectory.appendingPathComponent(LocalModelFiles.executableName))
            try? fm.removeItem(at: downloaded)
        }
    }

    /// Sets the mode and drops the quarantine flag so Gatekeeper never blocks the
    /// runtime the app starts as a child process.
    private nonisolated static func makeUsable(_ url: URL, permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        _ = removexattr(url.path, "com.apple.quarantine", 0)
    }

    /// Both URLs are on one volume, so this is a rename: the destination is either
    /// the old file or the new one, never half written.
    private nonisolated static func place(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    private nonisolated static func extract(archive: URL, to directory: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalModelError.extraction(detail.isEmpty ? "tar 退出状态 \(process.terminationStatus)" : detail)
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Session delegate. It is not main-actor isolated, because the finished file
/// has to leave the system's temporary location before the callback returns.
private final class DownloadRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let partialDirectory: URL
    weak var store: LocalModelStore?

    init(partialDirectory: URL) {
        self.partialDirectory = partialDirectory
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor [weak store] in
            store?.didWrite(key: key, total: totalBytesWritten, expectedTotal: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorBadServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"]
            )
            Task { @MainActor [weak store] in store?.didFail(key: key, error: error) }
            return
        }
        let destination = partialDirectory.appendingPathComponent("\(key).download")
        do {
            try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor [weak store] in store?.didFail(key: key, error: error) }
            return
        }
        Task { @MainActor [weak store] in store?.didDownload(key: key, file: destination) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription else { return }
        Task { @MainActor [weak store] in store?.didFail(key: key, error: error) }
    }
}
