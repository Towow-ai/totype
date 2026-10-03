import Foundation

public enum ModifierPressObservation: Equatable, Sendable {
    case acceptedPress
    case release
    case ignoredDuplicate
}

/// De-duplicates the CGEventTap/NSEvent copies of one modifier transition while
/// remaining able to recover when macOS drops a modifier-up event. A boolean
/// latch alone can permanently swallow the next physical press after such a
/// drop, which is especially harmful when the same modifier toggles recording.
public struct ModifierPressEdgePolicy: Sendable {
    /// Hardware/OS modifier delivery can bounce for longer than a typical key
    /// event. A deliberate stop after speaking is comfortably outside 350 ms;
    /// a second edge inside this window is the same physical press.
    public static let duplicateWindowNanoseconds: UInt64 = 350_000_000

    private var isPressed = false
    private var lastAcceptedPressNanoseconds: UInt64?

    public init() {}

    public mutating func observe(
        pressed: Bool,
        nowNanoseconds: UInt64
    ) -> ModifierPressObservation {
        guard pressed else {
            guard isPressed else { return .ignoredDuplicate }
            isPressed = false
            return .release
        }

        if let lastAcceptedPressNanoseconds {
            let elapsed = nowNanoseconds >= lastAcceptedPressNanoseconds
                ? nowNanoseconds - lastAcceptedPressNanoseconds
                : UInt64.max
            if elapsed < Self.duplicateWindowNanoseconds {
                isPressed = true
                return .ignoredDuplicate
            }
        }

        // Accept a later press even if `isPressed` is still true. This is the
        // recovery path for a missing modifier-up event; real duplicate backend
        // delivery has already been filtered by the short time window above.
        isPressed = true
        lastAcceptedPressNanoseconds = nowNanoseconds
        return .acceptedPress
    }

    public mutating func reset() {
        isPressed = false
        lastAcceptedPressNanoseconds = nil
    }
}

public enum RealtimeCompletionPolicy {
    /// Recent real sessions show Soniox normally finalizing in 0.4-0.6 s while
    /// Aliyun is often ready in 0.05-0.7 s. Preserve Soniox preference briefly,
    /// but do not hold a completed standby result for the old fixed 2.5 s.
    public static let primaryPreferenceNanoseconds: UInt64 = 750_000_000

    /// Soniox currently documents `finished: true`; older manual-finalization
    /// responses used a final `<fin>` token. Accept both during migration.
    public static func sonioxDidFinish(
        finishedFlag: Bool?,
        sawLegacyFinalMarker: Bool
    ) -> Bool {
        finishedFlag == true || sawLegacyFinalMarker
    }
}

/// Soniox documents a small set of transient WebSocket failures that should
/// be retried by opening a new request. Keep the policy typed and bounded so a
/// bad credential/configuration never turns into an authorization loop and a
/// transient service failure cannot retry forever.
public enum SonioxRecoveryPolicy {
    public static let maximumRecoveryAttempts = 1
    /// Normal setup is 1.0-1.3 s, but on a lossy phone hotspot it reached
    /// 2.2 s and repeatedly crossed the old 2.5 s limit (2026-09-27). Audio
    /// captured meanwhile is queued and flushed after the handshake.
    public static let configurationSendDeadlineNanoseconds: UInt64 = 5_000_000_000
    /// Successful handshakes: P95 1.68 s, P99 2.24 s (network forensics §3.1).
    /// A first attempt still pending at 1.8 s is raced by a second socket;
    /// the first to accept the configuration wins, the other is closed. Both
    /// stay inside `configurationSendDeadlineNanoseconds` from the first try.
    public static let connectionHedgeDelayNanoseconds: UInt64 = 1_800_000_000
    /// Soniox closes a stream after 300 minutes. A warm socket older than
    /// this is not reused for a new dictation.
    public static let warmConnectionMaximumAgeNanoseconds: UInt64 = 3_600_000_000_000
    /// Idle warm sockets: Soniox wants a keepalive at least every 20 s; a
    /// WebSocket ping without a pong inside the deadline closes the socket.
    public static let warmKeepaliveIntervalNanoseconds: UInt64 = 8_000_000_000
    public static let warmPongDeadlineNanoseconds: UInt64 = 3_000_000_000
    public static let audioSendDeadlineNanoseconds: UInt64 = 1_200_000_000
    public static let finalizeSendDeadlineNanoseconds: UInt64 = 1_500_000_000
    public static let recoveryBackoffNanoseconds: UInt64 = 150_000_000
    public static let replayPacingNanoseconds: UInt64 = 10_000_000
    public static let maximumReplayBytes = 32_000 * 600

    public static func isRetryableServerError(_ errorType: String) -> Bool {
        switch errorType {
        case "request_timeout", "service_unavailable", "internal_error":
            return true
        default:
            return false
        }
    }
}

/// The local fallback only starts after the cloud race has used most of the
/// fixed post-stop budget. A long recording cannot finish in whatever is left:
/// SenseVoice q8 took about 6 s for 176 s of audio, and the leftover ~4 s
/// dropped that whole utterance (2026-09-27). Guarantee a floor that scales
/// with the audio instead of failing a recording we already have.
public enum LocalFallbackPolicy {
    public static let baseBudgetNanoseconds: UInt64 = 4_000_000_000
    public static let realtimeDivisor: UInt64 = 15

    public static func minimumBudgetNanoseconds(pcmByteCount: Int) -> UInt64 {
        let duration = HistoryRetranscriptionPolicy.audioDurationNanoseconds(pcmByteCount: pcmByteCount)
        return baseBudgetNanoseconds &+ duration / realtimeDivisor
    }
}

/// Historical audio is replayed through providers whose transport is designed
/// for a live PCM stream. A fixed 20 second wall-clock deadline cannot possibly
/// handle a multi-minute recording reliably: the transport and service still
/// need time proportional to the amount of audio. Archived input is therefore
/// paced like live capture instead of being burst into the socket.
public enum HistoryRetranscriptionPolicy {
    public static let pcmBytesPerSecond = 16_000 * 2
    public static let minimumCloudDeadlineNanoseconds: UInt64 = 30_000_000_000
    public static let cloudCompletionGraceNanoseconds: UInt64 = 30_000_000_000
    public static let maximumCloudDeadlineNanoseconds: UInt64 = 930_000_000_000
    public static let minimumLocalDeadlineNanoseconds: UInt64 = 60_000_000_000
    public static let maximumLocalDeadlineNanoseconds: UInt64 = 600_000_000_000

    public static func audioDurationNanoseconds(pcmByteCount: Int) -> UInt64 {
        let seconds = Double(max(0, pcmByteCount)) / Double(pcmBytesPerSecond)
        return UInt64((seconds * 1_000_000_000).rounded(.up))
    }

    /// Realtime ASR WebSockets apply backpressure when archived audio is sent
    /// substantially faster than capture time. Pace against one absolute audio
    /// timeline so socket-send latency is included rather than added on top of
    /// every chunk's duration.
    public static func cloudReplayPacingNanoseconds(
        cumulativePCMByteCount: Int,
        elapsedNanoseconds: UInt64
    ) -> UInt64 {
        let target = audioDurationNanoseconds(pcmByteCount: cumulativePCMByteCount)
        return target > elapsedNanoseconds ? target - elapsedNanoseconds : 0
    }

    public static func deadlineNanoseconds(
        pcmByteCount: Int,
        isRealtimeCloud: Bool
    ) -> UInt64 {
        let duration = audioDurationNanoseconds(pcmByteCount: pcmByteCount)
        if isRealtimeCloud {
            return min(
                maximumCloudDeadlineNanoseconds,
                max(minimumCloudDeadlineNanoseconds, duration &+ cloudCompletionGraceNanoseconds)
            )
        }
        return min(
            maximumLocalDeadlineNanoseconds,
            max(minimumLocalDeadlineNanoseconds, duration / 2 &+ cloudCompletionGraceNanoseconds)
        )
    }

    public static func progressPercent(completedChunks: Int, totalChunks: Int) -> Int {
        guard totalChunks > 0 else { return 100 }
        return min(100, max(0, completedChunks * 100 / totalChunks))
    }
}

public enum AudioInputRecoveryPolicy {
    public static let delaysNanoseconds: [UInt64] = [
        250_000_000,
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        3_000_000_000
    ]

    public static func receivedFreshFrame(
        sequenceBeforeStart: Int64,
        sequenceAfterProbe: Int64
    ) -> Bool {
        sequenceAfterProbe > sequenceBeforeStart
    }
}

public enum AudioInputWatchdogPolicy {
    public static let probeIntervalNanoseconds: UInt64 = 1_000_000_000
    public static let staleProbeLimit = 2
    public static let recoveryProbeNanoseconds: UInt64 = 850_000_000
    public static let recoveryCyclePauseNanoseconds: UInt64 = 5_000_000_000
    /// `AVAudioEngine.start()` can block synchronously while CoreAudio rebuilds
    /// an aggregate device. The UI/recovery coordinator must never wait longer.
    public static let engineStartDeadlineNanoseconds: UInt64 = 2_000_000_000
    /// A blocked system call cannot be force-cancelled safely. Bound the number
    /// of isolated calls retained until CoreAudio eventually releases them.
    public static let maximumOutstandingStartAttempts = 2

    public static func nextStaleProbeCount(
        engineClaimsRunning: Bool,
        previousSequence: Int64,
        currentSequence: Int64,
        previousStaleProbeCount: Int
    ) -> Int {
        guard engineClaimsRunning else { return 0 }
        guard currentSequence <= previousSequence else { return 0 }
        return previousStaleProbeCount + 1
    }
}

public enum SessionLifecycleState: String, Codable, Sendable {
    case idle
    case starting
    case listening
    case cancelPending
    case finalizing
    case committing
    case completed
    case failed
}

public struct SessionGenerationToken: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64

    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

/// Thread-safe ownership and exactly-once commit gate for one active dictation.
/// Late tasks can retain a token, but they cannot mutate or commit a newer
/// generation after the active session has advanced.
public final class DictationSessionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeToken: SessionGenerationToken?
    private var lifecycleState: SessionLifecycleState = .idle
    private var committed = false

    public init() {}

    public func begin(sessionID: UUID = UUID()) -> SessionGenerationToken? {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycleState == .idle || lifecycleState == .completed || lifecycleState == .failed else {
            return nil
        }
        generation &+= 1
        let token = SessionGenerationToken(sessionID: sessionID, generation: generation)
        activeToken = token
        lifecycleState = .starting
        committed = false
        return token
    }

    @discardableResult
    public func transition(
        _ token: SessionGenerationToken,
        to next: SessionLifecycleState
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == token, Self.allows(lifecycleState, next) else { return false }
        lifecycleState = next
        return true
    }

    /// Returns true exactly once for the current generation.
    public func claimCommit(_ token: SessionGenerationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == token,
              lifecycleState == .finalizing || lifecycleState == .committing,
              !committed else { return false }
        lifecycleState = .committing
        committed = true
        return true
    }

    public func isCurrent(_ token: SessionGenerationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken == token
    }

    public func snapshot() -> (token: SessionGenerationToken?, state: SessionLifecycleState) {
        lock.lock()
        defer { lock.unlock() }
        return (activeToken, lifecycleState)
    }

    @discardableResult
    public func finish(
        _ token: SessionGenerationToken,
        as terminalState: SessionLifecycleState
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == token,
              terminalState == .completed || terminalState == .failed else { return false }
        lifecycleState = terminalState
        activeToken = nil
        committed = false
        lifecycleState = .idle
        return true
    }

    @discardableResult
    public func cancel(_ token: SessionGenerationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeToken == token else { return false }
        activeToken = nil
        committed = false
        lifecycleState = .idle
        return true
    }

    private static func allows(
        _ current: SessionLifecycleState,
        _ next: SessionLifecycleState
    ) -> Bool {
        switch (current, next) {
        case (.starting, .listening),
             (.starting, .cancelPending),
             (.starting, .finalizing),
             (.starting, .failed),
             (.listening, .finalizing),
             (.listening, .cancelPending),
             (.listening, .failed),
             (.cancelPending, .finalizing),
             (.cancelPending, .completed),
             (.cancelPending, .failed),
             (.finalizing, .committing),
             (.finalizing, .failed),
             (.committing, .completed),
             (.committing, .failed):
            return true
        default:
            return current == next
        }
    }
}

public enum SessionTimelineEvent: String, Codable, Sendable {
    case trigger
    case overlayPresented
    case audioHardwareReady
    case firstAudioChunk
    case sessionActivated
    case stopRequested
    case cancelRequested
    case cancelUndone
    case cancelRetained
    case inputClosed
    case sonioxFinal
    case aliyunFinal
    case localFinal
    /// The local engine was started (raced against the cloud or after it).
    case localFallbackStarted
    case resultSelected
    case unicodeDispatched
    case overlayDismissed
    case userPathFinished
    case persistenceFinished
    case failed
}

public struct SessionTimelineMark: Codable, Hashable, Sendable {
    public let event: SessionTimelineEvent
    public let offsetNanoseconds: Int64
    public let providerID: String?

    public init(event: SessionTimelineEvent, offsetNanoseconds: Int64, providerID: String? = nil) {
        self.event = event
        self.offsetNanoseconds = offsetNanoseconds
        self.providerID = providerID
    }
}

public struct SessionTimelineSnapshot: Codable, Sendable {
    public let metricSpecVersion: Int
    public let wallClockStartedAt: Date
    public let marks: [SessionTimelineMark]

    public init(metricSpecVersion: Int, wallClockStartedAt: Date, marks: [SessionTimelineMark]) {
        self.metricSpecVersion = metricSpecVersion
        self.wallClockStartedAt = wallClockStartedAt
        self.marks = marks
    }

    public func milliseconds(from start: SessionTimelineEvent, to end: SessionTimelineEvent) -> Int? {
        guard let startMark = marks.first(where: { $0.event == start }),
              let endMark = marks.first(where: { $0.event == end }),
              endMark.offsetNanoseconds >= startMark.offsetNanoseconds else { return nil }
        return Int((endMark.offsetNanoseconds - startMark.offsetNanoseconds) / 1_000_000)
    }
}

public final class SessionTimelineRecorder: @unchecked Sendable {
    public static let metricSpecVersion = 1

    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private let wallClockStartedAt: Date
    private var marks: [SessionTimelineMark] = []

    public init(wallClockStartedAt: Date = Date()) {
        self.wallClockStartedAt = wallClockStartedAt
    }

    public func mark(_ event: SessionTimelineEvent, providerID: String? = nil) {
        let duration = origin.duration(to: .now).components
        let nanoseconds = Int64(clamping: duration.seconds) * 1_000_000_000
            + Int64(clamping: duration.attoseconds / 1_000_000_000)
        lock.lock()
        if !marks.contains(where: { $0.event == event && $0.providerID == providerID }) {
            marks.append(SessionTimelineMark(
                event: event,
                offsetNanoseconds: max(0, nanoseconds),
                providerID: providerID
            ))
        }
        lock.unlock()
    }

    /// The clock origin of every mark, for converting provider-side instants.
    public var originInstant: ContinuousClock.Instant { origin }

    public func snapshot() -> SessionTimelineSnapshot {
        lock.lock()
        let currentMarks = marks
        lock.unlock()
        return SessionTimelineSnapshot(
            metricSpecVersion: Self.metricSpecVersion,
            wallClockStartedAt: wallClockStartedAt,
            marks: currentMarks
        )
    }
}
