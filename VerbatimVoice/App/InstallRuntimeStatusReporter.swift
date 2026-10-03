import Foundation

enum InstallRuntimeState: String, Codable, Sendable {
    case idle
    case listening
    case finalizing
    case inserting
    case criticalPersist
    case preview
    case failed
}

struct InstallRuntimeStatus: Codable, Sendable {
    let installProtocolVersion: Int
    let pid: Int32
    let processStartIdentity: String
    let launchID: UUID
    let executablePath: String
    let state: InstallRuntimeState
    let updatedAtUnixMilliseconds: Int64
}

@MainActor
final class InstallRuntimeStatusReporter {
    static let protocolVersion = 1
    static let fileName = "install-runtime-status.json"

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let launchID = UUID()
    private let processStartIdentity: String
    private let executablePath: String
    private var dictationState: DictationState = .idle
    private var criticalPersistDepth = 0
    private var heartbeat: Timer?

    init(baseDirectory: URL? = nil, startHeartbeat: Bool = true) {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = AppIdentity.dataDirectory(in: root)
        }
        fileURL = directory.appendingPathComponent(Self.fileName)
        executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
        processStartIdentity = Self.readProcessStartIdentity(pid: getpid())
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        writeStatus()
        if startHeartbeat {
            heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.writeStatus()
                }
            }
            heartbeat?.tolerance = 0.25
        }
    }

    deinit {
        heartbeat?.invalidate()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func update(dictationState: DictationState) {
        self.dictationState = dictationState
        writeStatus()
    }

    func beginCriticalPersistence() {
        criticalPersistDepth += 1
        writeStatus()
    }

    func endCriticalPersistence() {
        criticalPersistDepth = max(0, criticalPersistDepth - 1)
        writeStatus()
    }

    func stop(removeStatusFile: Bool = true) {
        heartbeat?.invalidate()
        heartbeat = nil
        if removeStatusFile {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private var runtimeState: InstallRuntimeState {
        if criticalPersistDepth > 0 { return .criticalPersist }
        switch dictationState {
        case .starting, .listening: return .listening
        case .cancelPending, .finalizing: return .finalizing
        case .inserting: return .inserting
        case .preview: return .preview
        case .failed: return .failed
        case .idle: return .idle
        }
    }

    private func writeStatus() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let status = InstallRuntimeStatus(
                installProtocolVersion: Self.protocolVersion,
                pid: getpid(),
                processStartIdentity: processStartIdentity,
                launchID: launchID,
                executablePath: executablePath,
                state: runtimeState,
                updatedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            let data = try encoder.encode(status)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Installation must fail closed when this file is absent or stale.
            // Dictation itself must remain usable if the diagnostic write fails.
        }
    }

    private static func readProcessStartIdentity(pid: pid_t) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "unavailable" }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
        } catch {
            return "unavailable"
        }
    }
}
