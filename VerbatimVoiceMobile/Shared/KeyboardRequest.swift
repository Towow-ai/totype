import Foundation

enum KeyboardRequestAction: String, Codable, Sendable {
    case start
    case stop
    case cancel
    /// Re-transcribe the archived audio of the failed dictation
    /// `targetSessionID`; the result replaces its mailbox entry in place.
    case retry
}

/// What the app did with a keyboard request, published in
/// `SharedSessionState.handledRequestResult`.
enum KeyboardRequestResult: String, Codable, Sendable {
    /// Acted on it.
    case accepted
    /// Read it but nothing to do (stop while idle, start while recording…).
    case ignored
    /// No running audio engine: a background start would fail, so the
    /// keyboard should open the app instead.
    case needsForeground
}

/// A keyboard → app command while a session is alive. Only the latest
/// request matters, so it is one small file that each tap overwrites; the
/// Darwin notification `.keyboardRequest` says "look again".
struct KeyboardRequest: Codable, Equatable, Sendable {
    /// The app ignores requests older than this by its own clock, so a stale
    /// "start" never fires when the app is next woken or foregrounded.
    static let expiresAfter: TimeInterval = 3
    /// How long the keyboard waits for an answer before opening the app.
    static let answerTimeout: TimeInterval = 0.8

    let id: UUID
    let action: KeyboardRequestAction
    let issuedAt: Date
    /// For stop/cancel: the dictation the keyboard saw (nil means "whatever
    /// is current"). For retry: the failed dictation.
    var targetSessionID: UUID?
    /// Diagnostics only: the heartbeat in the state the keyboard decided
    /// from, so the app can log how far behind its own last write it was.
    var seenHeartbeatAt: Date?

    init(id: UUID = UUID(), action: KeyboardRequestAction, issuedAt: Date = Date(),
         targetSessionID: UUID? = nil, seenHeartbeatAt: Date? = nil) {
        self.id = id
        self.action = action
        self.issuedAt = issuedAt
        self.targetSessionID = targetSessionID
        self.seenHeartbeatAt = seenHeartbeatAt
    }

    func isExpired(now: Date = Date()) -> Bool {
        abs(now.timeIntervalSince(issuedAt)) > Self.expiresAfter
    }
}

/// Single writer (the keyboard, which needs Full Access to write); the app
/// reads. Atomic rename, so readers never see a torn file.
final class KeyboardRequestStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("keyboard-request.json")
    }

    func write(_ request: KeyboardRequest) throws {
        try AtomicFile.write(try JSONEncoder.precise.encode(request), to: fileURL)
    }

    func read() -> KeyboardRequest? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.precise.decode(KeyboardRequest.self, from: data)
    }

    /// The request the app should act on: fresh and not yet answered.
    func unhandled(after handledID: UUID?, now: Date = Date()) -> KeyboardRequest? {
        guard let request = read(), request.id != handledID, !request.isExpired(now: now) else { return nil }
        return request
    }
}

/// Recent microphone levels for the keyboard's waveform. Written by the app
/// at ~15 Hz while recording, so it skips the fsync that `AtomicFile` does;
/// a lost update only costs one frame.
struct SharedLevelSnapshot: Codable, Equatable, Sendable {
    static let capacity = 32

    var sessionID: UUID?
    var updatedAt: Date
    /// Oldest first, 0…255.
    var levels: [UInt8]
}

final class SharedLevelStore: Sendable {
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("levels.json")
    }

    func write(_ snapshot: SharedLevelSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var trimmed = snapshot
        if trimmed.levels.count > SharedLevelSnapshot.capacity {
            trimmed.levels.removeFirst(trimmed.levels.count - SharedLevelSnapshot.capacity)
        }
        try JSONEncoder.precise.encode(trimmed).write(to: fileURL, options: .atomic)
    }

    func read() -> SharedLevelSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.precise.decode(SharedLevelSnapshot.self, from: data)
    }
}

/// Written by the keyboard each time it appears. The write only succeeds
/// with Full Access, so its presence tells the app's onboarding that the
/// keyboard is installed and trusted.
enum KeyboardPresence {
    static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent("keyboard-seen.json")
    }

    static func mark(directory: URL, now: Date = Date()) {
        try? JSONEncoder.precise.encode(["seenAt": now]).write(to: fileURL(directory: directory), options: .atomic)
    }

    static func lastSeen(directory: URL) -> Date? {
        guard let data = try? Data(contentsOf: fileURL(directory: directory)),
              let value = try? JSONDecoder.precise.decode([String: Date].self, from: data) else { return nil }
        return value["seenAt"]
    }
}
