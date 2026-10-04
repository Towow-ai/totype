import Foundation

/// The keyboard's own event log, next to the app's:
/// `<App Group container>/Library/diagnostics/keyboard-log.txt` (same pull
/// command as `session-log.txt`, README "诊断日志"). One line per event,
/// trimmed to the newest ~256 KB. Writing needs Full Access (the container
/// is read-only without it), so without it nothing is logged.
///
/// Never logs typed or transcribed text, host field contents or keys; only
/// event names, states, counts and timings. Writes run on one utility queue
/// and never block the keyboard.
enum KeyboardDiagnostics {
    static let maximumBytes = 262_144
    static let keepBytes = 196_608

    private static let queue = DispatchQueue(label: MobileIdentity.label("keyboard-diagnostics"), qos: .utility)
    private static let processTag = "kb pid \(ProcessInfo.processInfo.processIdentifier)"

    static let fileURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("diagnostics", isDirectory: true)
        .appendingPathComponent("keyboard-log.txt")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func log(_ event: String, _ detail: String = "") {
        let line = "\(formatter.string(from: Date())) [\(processTag)] \(event)\(detail.isEmpty ? "" : " " + detail)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        guard let url = fileURL, let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard manager.createFile(atPath: url.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            if Int(size) + data.count > maximumBytes { trim(url) }
        } catch {
            // No Full Access, or the container is gone: nothing to do.
        }
    }

    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > keepBytes else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
