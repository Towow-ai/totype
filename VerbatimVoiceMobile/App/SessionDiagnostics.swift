import Foundation
import os

/// File log of session events for diagnosing background survival on a
/// device: `<App Group container>/Library/diagnostics/session-log.txt`, one line per
/// event, newest at the end, trimmed to the most recent ~1 MB. It lives
/// under `Library/` because `devicectl` only copies from Library, Documents
/// and tmp of a container.
///
/// Pull it with
/// `xcrun devicectl device copy from --device <id> --domain-type appGroupDataContainer
///  --domain-identifier <TOTYPE_APP_GROUP>
///  --source Library/diagnostics/session-log.txt --destination <file>`.
///
/// Never logs transcript text, API keys or audio; only event names, states,
/// error descriptions and timings. Writes happen on one utility queue and
/// never block the caller.
enum SessionDiagnostics {
    static let maximumBytes = 1_048_576
    /// After trimming, keep this much so trimming runs rarely.
    static let keepBytes = 786_432

    private static let queue = DispatchQueue(label: MobileIdentity.label("diagnostics"), qos: .utility)
    private static let logger = Logger(subsystem: MobileIdentity.appBundleID, category: "session")
    private static let processTag = "pid \(ProcessInfo.processInfo.processIdentifier)"

    static let fileURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("diagnostics", isDirectory: true)
        .appendingPathComponent("session-log.txt")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// `event` is a short dotted name (`engine.start`); `detail` is
    /// `key=value` pairs. Both must be free of user text.
    static func log(_ event: String, _ detail: String = "") {
        let now = Date()
        let line = "\(formatter.string(from: now)) [\(processTag)] \(event)\(detail.isEmpty ? "" : " " + detail)\n"
        logger.notice("\(event, privacy: .public) \(detail, privacy: .public)")
        queue.async { append(line) }
    }

    /// Physical footprint in MB (what jetsam compares against its limit).
    static func footprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }

    /// For tests and the "copy log" path: waits for pending writes.
    static func flush() {
        queue.sync {}
    }

    private static func append(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            if Int(size) + data.count > maximumBytes { trim(url) }
        } catch {
            logger.error("diagnostics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the newest `keepBytes`, starting at a line boundary.
    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
