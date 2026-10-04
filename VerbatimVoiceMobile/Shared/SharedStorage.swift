import Foundation

enum AppGroup {
    static var identifier: String { MobileIdentity.appGroup }

    /// Directory shared by the app, keyboard and widgets. Nil when the App
    /// Group entitlement is missing (for example an unsigned build).
    static func sharedDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else { return nil }
        return container.appendingPathComponent("VerbatimShared", isDirectory: true)
    }
}

enum AtomicFile {
    /// Writes to a temporary file in the same directory, flushes it, then
    /// rename(2)s it over the destination. Readers see the old or the new
    /// file, never a partial one.
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw POSIXError(.EIO)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }
}

/// Cross-process exclusive lock backed by flock(2). Every call opens its own
/// descriptor, so two threads of one process also exclude each other.
/// Keep the critical section short and synchronous: iOS terminates a
/// suspended process that still holds a lock inside the shared container.
struct FileLock: Sendable {
    let url: URL

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

extension JSONEncoder {
    static var shared: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Sub-second dates for the live protocol files (session state, keyboard
    /// requests, levels): ISO 8601 drops fractions, which would break the
    /// 800 ms answer window and the recording timer.
    static var precise: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var shared: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Pairs with `JSONEncoder.precise`.
    static var precise: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
