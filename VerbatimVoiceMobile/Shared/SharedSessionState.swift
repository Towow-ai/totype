import Foundation

enum SharedSessionPhase: String, Codable, Sendable {
    case idle
    case starting
    case recording
    case finalizing
}

/// Recording and session status published by the app for the keyboard and
/// widgets.
///
/// Two layers: `phase` is the current dictation; `sessionActive` means the
/// app holds a running audio engine in the background, so the keyboard can
/// start the next dictation through `KeyboardRequest` without opening the
/// app. Both are only trusted while the heartbeat is fresh.
struct SharedSessionState: Codable, Equatable, Sendable {
    /// The app refreshes the heartbeat every second while a dictation or a
    /// session is alive. A stale heartbeat means the app was suspended or
    /// killed.
    static let staleAfter: TimeInterval = 6
    /// Heartbeat age beyond which the keyboard opens the app at once when
    /// the state carries no idle timeout ("until ended manually", or a state file
    /// written before 2026-10-02): the longest timeout the settings offer.
    static let unresponsiveCapWithoutTimeout: TimeInterval = 3_600

    var phase: SharedSessionPhase
    var sessionID: UUID?
    /// Set only once the first PCM buffer has arrived.
    var recordingStartedAt: Date?
    var heartbeatAt: Date
    var revision: UInt64

    /// The app's audio engine is running and can record without coming to
    /// the foreground.
    var sessionActive = false
    /// Interrupted (call, Siri, other audio); the keyboard opens the app.
    var sessionPaused = false
    /// When the idle session ends by itself. Nil while recording, or when the
    /// user chose "until ended manually".
    var sessionEndsAt: Date?
    /// Keyboard request (or URL `request=` parameter) that started the
    /// current dictation. Lets the keyboard recognise its own result.
    var originRequestID: UUID?
    /// Last keyboard request the app read, with what it did about it. Every
    /// request read gets an answer, including no-ops.
    var handledRequestID: UUID?
    var handledRequestResult: KeyboardRequestResult?
    /// Last failed dictation, for the keyboard to explain. Retrying happens in
    /// the app's history.
    var lastError: String?
    var lastErrorAt: Date?
    /// Display name of the hot standby ("阿里云") while it carries the user
    /// path: the primary is unusable (balance, key) or the last result came
    /// from the standby. The keyboard shows "已用阿里云". Optional, so state
    /// files written before 0.3.74 still decode.
    var fallbackProviderName: String?
    /// Why the primary is unusable, e.g. "Soniox 余额不足，已改用阿里云".
    var providerNotice: String?
    /// The session's idle timeout in seconds; nil for "until ended
    /// manually" (and in files written before 2026-10-02). A heartbeat older
    /// than this means the app is gone: an alive session either beats or
    /// has ended by itself.
    var sessionIdleTimeout: TimeInterval?

    static let idle = SharedSessionState(
        phase: .idle,
        sessionID: nil,
        recordingStartedAt: nil,
        heartbeatAt: .distantPast,
        revision: 0
    )

    func effectivePhase(now: Date = Date()) -> SharedSessionPhase {
        guard phase != .idle else { return .idle }
        return now.timeIntervalSince(heartbeatAt) > Self.staleAfter ? .idle : phase
    }

    /// How the keyboard's mic should reach the app, judged from a state read
    /// `heartbeatAge` seconds after its last heartbeat (age at the read, not
    /// at render: the keyboard does not re-read while idle, so comparing a
    /// cached heartbeat with the render clock made live sessions look stale,
    /// device log 2026-10-01).
    ///
    /// A request is cheap (800 ms answer timeout, then the URL), so any
    /// session that says it is active gets one unless its heartbeat is
    /// older than the idle timeout, which an alive app never lets happen.
    func keyboardRoute(heartbeatAge: TimeInterval) -> KeyboardMicRoute {
        if sessionPaused { return .openApp(why: "paused") }
        if !sessionActive { return .openApp(why: "noSession") }
        let limit = sessionIdleTimeout ?? Self.unresponsiveCapWithoutTimeout
        return heartbeatAge > limit ? .openApp(why: "stale") : .request
    }

    /// The app's answer to `requestID`, or nil if it has not answered yet.
    func answer(to requestID: UUID) -> KeyboardRequestResult? {
        handledRequestID == requestID ? handledRequestResult : nil
    }
}

/// What the keyboard mic does with the current session state.
enum KeyboardMicRoute: Equatable, Sendable {
    /// Write a `KeyboardRequest` and wait for the answer; open the app only
    /// if none comes.
    case request
    /// Open the app now; `why` goes to the diagnostics log.
    case openApp(why: String)
}

/// Single writer (the app); any number of lock-free readers.
final class SharedSessionStateStore: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private var current: SharedSessionState?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("session-state.json")
    }

    func read() -> SharedSessionState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder.precise.decode(SharedSessionState.self, from: data) else {
            return .idle
        }
        return state
    }

    /// Applies `update` to the last published state, refreshes the
    /// heartbeat, bumps the revision and writes atomically.
    func publish(now: Date = Date(), _ update: (inout SharedSessionState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = current ?? read()
        var next = previous
        update(&next)
        if next.phase == .idle {
            next.sessionID = nil
            next.recordingStartedAt = nil
            next.originRequestID = nil
        }
        if !next.sessionActive, !next.sessionPaused { next.sessionEndsAt = nil }
        next.heartbeatAt = now
        next.revision = previous.revision &+ 1
        try AtomicFile.write(try JSONEncoder.precise.encode(next), to: fileURL)
        current = next
    }

    func publish(
        phase: SharedSessionPhase,
        sessionID: UUID?,
        recordingStartedAt: Date?,
        now: Date = Date()
    ) throws {
        try publish(now: now) { state in
            state.phase = phase
            state.sessionID = sessionID
            state.recordingStartedAt = recordingStartedAt
        }
    }

    /// Heartbeat of the last write by this process (publish or beat), for
    /// the diagnostics comparison with what the keyboard read.
    var lastWrittenHeartbeat: Date? {
        lock.lock()
        defer { lock.unlock() }
        return current?.heartbeatAt
    }

    /// Atomic rename without fsync: a heartbeat lost to a power cut does
    /// not matter, and this runs every second for the whole session,
    /// including an idle armed or paused one.
    func heartbeat(now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var state = current, state.phase != .idle || state.sessionActive || state.sessionPaused else { return }
        state.heartbeatAt = now
        try JSONEncoder.precise.encode(state).write(to: fileURL, options: .atomic)
        current = state
    }
}
