import Foundation

// Network robustness (0.3.79). Evidence: see docs/DESIGN.md.
// The pure rules here are shared by macOS (`AppModel.finish`) and the
// deterministic self-test; the async drivers only feed them observations.

// MARK: - Provider liveness

/// Per-session, per-provider record of what the server has done so far.
/// Providers mark it from their own transport callbacks; the session owns it,
/// so a pooled provider instance cannot write into a later session's record.
public final class ProviderLivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: ContinuousClock.Instant?
    private var connectedAt: ContinuousClock.Instant?
    private var firstServerMessageAt: ContinuousClock.Instant?
    private var lastServerMessageAt: ContinuousClock.Instant?
    private var failedAt: ContinuousClock.Instant?
    private var finishedWithoutResult = false
    private var serverMessageCount = 0
    private var reusedConnection: Bool?
    private var hedgedConnection: Bool?

    public init() {}

    /// The provider task started (connection attempts begin here).
    public func markStarted(at instant: ContinuousClock.Instant = .now) {
        lock.lock()
        if startedAt == nil { startedAt = instant }
        lock.unlock()
    }

    /// The transport can carry audio: Soniox configuration accepted on a
    /// fresh or reused socket, Aliyun `task-started`.
    public func markConnected(
        reused: Bool? = nil,
        hedged: Bool? = nil,
        at instant: ContinuousClock.Instant = .now
    ) {
        lock.lock()
        if connectedAt == nil { connectedAt = instant }
        if let reused { reusedConnection = reused }
        if let hedged { hedgedConnection = hedged }
        lock.unlock()
    }

    /// Any frame from the server, including frames without text.
    public func markServerMessage(at instant: ContinuousClock.Instant = .now) {
        lock.lock()
        if firstServerMessageAt == nil { firstServerMessageAt = instant }
        lastServerMessageAt = instant
        serverMessageCount += 1
        lock.unlock()
    }

    /// A transport or server failure was observed (recoverable or not).
    public func markFailed(at instant: ContinuousClock.Instant = .now) {
        lock.lock()
        if failedAt == nil { failedAt = instant }
        lock.unlock()
    }

    /// The provider task ended; `usable` is false for failures, cancellation
    /// and empty finals.
    public func markFinished(usable: Bool) {
        lock.lock()
        if !usable { finishedWithoutResult = true }
        lock.unlock()
    }

    public func view(now: ContinuousClock.Instant = .now) -> ProviderLivenessView {
        lock.lock()
        defer { lock.unlock() }
        func since(_ instant: ContinuousClock.Instant?) -> UInt64? {
            guard let instant else { return nil }
            return Self.nanoseconds(instant.duration(to: now))
        }
        return ProviderLivenessView(
            sinceStarted: since(startedAt),
            sinceConnected: since(connectedAt),
            sinceLastServerMessage: since(lastServerMessageAt),
            failed: failedAt != nil,
            finishedWithoutResult: finishedWithoutResult
        )
    }

    /// Offsets relative to `origin` (the session timeline origin).
    public func record(origin: ContinuousClock.Instant) -> ProviderLivenessRecord {
        lock.lock()
        defer { lock.unlock() }
        func offset(_ instant: ContinuousClock.Instant?) -> Int? {
            guard let instant else { return nil }
            return Int(Self.signedNanoseconds(origin.duration(to: instant)) / 1_000_000)
        }
        return ProviderLivenessRecord(
            startedAtMilliseconds: offset(startedAt),
            connectedAtMilliseconds: offset(connectedAt),
            firstServerMessageAtMilliseconds: offset(firstServerMessageAt),
            lastServerMessageAtMilliseconds: offset(lastServerMessageAt),
            failedAtMilliseconds: offset(failedAt),
            serverMessageCount: serverMessageCount,
            reusedConnection: reusedConnection,
            hedgedConnection: hedgedConnection
        )
    }

    public static func nanoseconds(_ duration: Duration) -> UInt64 {
        UInt64(max(0, signedNanoseconds(duration)))
    }

    public static func signedNanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return Int64(clamping: components.seconds) &* 1_000_000_000
            &+ Int64(clamping: components.attoseconds / 1_000_000_000)
    }
}

/// History form of `ProviderLivenessProbe`: milliseconds from the session's
/// timeline origin (the trigger), so they line up with `timeline.marks`.
public struct ProviderLivenessRecord: Codable, Equatable, Sendable {
    public var startedAtMilliseconds: Int?
    public var connectedAtMilliseconds: Int?
    public var firstServerMessageAtMilliseconds: Int?
    public var lastServerMessageAtMilliseconds: Int?
    public var failedAtMilliseconds: Int?
    public var serverMessageCount: Int?
    /// Soniox: the socket was kept from an earlier dictation (no handshake).
    public var reusedConnection: Bool?
    /// Soniox: the second, hedged connection attempt won.
    public var hedgedConnection: Bool?

    public init(
        startedAtMilliseconds: Int? = nil,
        connectedAtMilliseconds: Int? = nil,
        firstServerMessageAtMilliseconds: Int? = nil,
        lastServerMessageAtMilliseconds: Int? = nil,
        failedAtMilliseconds: Int? = nil,
        serverMessageCount: Int? = nil,
        reusedConnection: Bool? = nil,
        hedgedConnection: Bool? = nil
    ) {
        self.startedAtMilliseconds = startedAtMilliseconds
        self.connectedAtMilliseconds = connectedAtMilliseconds
        self.firstServerMessageAtMilliseconds = firstServerMessageAtMilliseconds
        self.lastServerMessageAtMilliseconds = lastServerMessageAtMilliseconds
        self.failedAtMilliseconds = failedAtMilliseconds
        self.serverMessageCount = serverMessageCount
        self.reusedConnection = reusedConnection
        self.hedgedConnection = hedgedConnection
    }
}

/// Elapsed times as seen at one checkpoint; nil means "never happened".
public struct ProviderLivenessView: Equatable, Sendable {
    public var sinceStarted: UInt64?
    public var sinceConnected: UInt64?
    public var sinceLastServerMessage: UInt64?
    public var failed: Bool
    /// The provider task already ended without a usable result.
    public var finishedWithoutResult: Bool

    public init(
        sinceStarted: UInt64?,
        sinceConnected: UInt64? = nil,
        sinceLastServerMessage: UInt64? = nil,
        failed: Bool = false,
        finishedWithoutResult: Bool = false
    ) {
        self.sinceStarted = sinceStarted
        self.sinceConnected = sinceConnected
        self.sinceLastServerMessage = sinceLastServerMessage
        self.failed = failed
        self.finishedWithoutResult = finishedWithoutResult
    }
}

public enum ProviderLivenessPolicy {
    /// A provider unheard for this long while unconnected (or already
    /// failing) will not finalize inside the 750 ms preference window.
    public static let silenceNanoseconds: UInt64 = 3_000_000_000
    /// A connected provider with no server frame for this long is treated as
    /// half-dead for the "start local at stop" decision only. It still races.
    public static let connectedStallNanoseconds: UInt64 = 8_000_000_000

    /// Skip the primary preference window at stop. Deliberately narrow: only
    /// "never connected for 3 s" or "already reported a failure". Soniox does
    /// not document a response cadence, so a connected-but-quiet socket is
    /// not judged here (the new `lastServerMessageAt` field calibrates it).
    public static func isSilent(_ view: ProviderLivenessView) -> Bool {
        if view.finishedWithoutResult || view.failed { return true }
        guard view.sinceConnected == nil, let started = view.sinceStarted else { return false }
        let lastHeard = view.sinceLastServerMessage ?? started
        return lastHeard >= silenceNanoseconds
    }

    /// Unusable for this dictation: start the local engine as soon as the
    /// microphone closes instead of waiting for the cloud budget.
    public static func isDead(_ view: ProviderLivenessView) -> Bool {
        if view.finishedWithoutResult { return true }
        if view.failed, view.sinceConnected == nil { return true }
        guard let started = view.sinceStarted else { return false }
        guard let connected = view.sinceConnected else {
            return started >= silenceNanoseconds
        }
        let lastHeard = min(connected, view.sinceLastServerMessage ?? connected)
        return lastHeard >= connectedStallNanoseconds
    }

    /// Both clouds unusable at stop (a missing standby counts as dead).
    public static func cloudsDeadAtStop(
        primary: ProviderLivenessView,
        standby: ProviderLivenessView?
    ) -> Bool {
        isDead(primary) && (standby.map(isDead) ?? true)
    }
}

// MARK: - Cloud / local race after stop

/// Why the local engine was started.
public enum LocalRaceStart: String, Codable, Sendable {
    /// Both clouds were already unusable when the microphone closed.
    case cloudsDeadAtStop
    /// No usable cloud result `localRaceDelay` after stop.
    case cloudStalled
    /// The cloud selection ended without a usable result (legacy path).
    case cloudExhausted

    public var selectedReason: String {
        switch self {
        case .cloudsDeadAtStop: return "local_raced_clouds_dead"
        case .cloudStalled: return "local_raced_cloud_stalled"
        case .cloudExhausted: return "dual_cloud_failed_local_completed"
        }
    }
}

public enum CloudRacePhase: Equatable, Sendable {
    /// The cloud selection (preference window, standby race, 8 s budget) is
    /// still running.
    case pending
    case usable
    /// The cloud selection ended without a usable result.
    case exhausted
}

public enum LocalRacePhase: Equatable, Sendable {
    /// Local fallback disabled or model missing.
    case unavailable
    case notStarted
    case running
    case usable
    case failed
}

public enum CloudLocalRaceDecision: Equatable, Sendable {
    case wait
    case startLocal(LocalRaceStart)
    case takeCloud
    case takeLocal(reason: String)
    case noUsableResult
}

/// First usable result wins. The cloud keeps its own 8 s budget and its own
/// preference rules (`CloudSelectionPolicy`); the local engine is started in
/// parallel once the cloud looks stalled, instead of after the budget.
public enum CloudLocalRacePolicy {
    /// Forensics replay: "rescued by the cloud after X s without a result"
    /// is 68% at 2 s, 50% at 3 s; 2.5 s saved 107 s of 347 s with no session
    /// made slower.
    public static let localRaceDelayNanoseconds: UInt64 = 2_500_000_000
    public static let cloudDeadlineNanoseconds: UInt64 = 8_000_000_000
    public static let userPathDeadlineNanoseconds: UInt64 = 12_000_000_000

    public static func localStartDelay(cloudsDeadAtStop: Bool) -> UInt64 {
        cloudsDeadAtStop ? 0 : localRaceDelayNanoseconds
    }

    /// `localStart` is why the running/finished local engine was started.
    public static func decide(
        elapsedSinceStop: UInt64,
        cloud: CloudRacePhase,
        local: LocalRacePhase,
        cloudsDeadAtStop: Bool,
        localStart: LocalRaceStart?
    ) -> CloudLocalRaceDecision {
        if cloud == .usable { return .takeCloud }
        if local == .usable {
            return .takeLocal(reason: (localStart ?? .cloudExhausted).selectedReason)
        }
        switch cloud {
        case .usable:
            return .takeCloud
        case .exhausted:
            switch local {
            case .notStarted: return .startLocal(.cloudExhausted)
            case .running: return .wait
            case .unavailable, .failed, .usable: return .noUsableResult
            }
        case .pending:
            if local == .notStarted,
               elapsedSinceStop >= localStartDelay(cloudsDeadAtStop: cloudsDeadAtStop) {
                return .startLocal(cloudsDeadAtStop ? .cloudsDeadAtStop : .cloudStalled)
            }
            return .wait
        }
    }
}

/// Deterministic replay of `CloudLocalRacePolicy` on a fake timeline. All
/// times are nanoseconds after stop (input closed).
public enum CloudLocalRaceSimulator {
    public struct Scenario: Sendable {
        /// When the cloud selection yields a usable result; nil = never.
        public var cloudUsableAt: UInt64?
        /// When the cloud selection gives up (budget or both failed).
        public var cloudExhaustedAt: UInt64
        public var cloudsDeadAtStop: Bool
        public var localAvailable: Bool
        /// Local run time once started; nil = the local engine fails.
        public var localDuration: UInt64?
        public var localFailsAfter: UInt64

        public init(
            cloudUsableAt: UInt64?,
            cloudExhaustedAt: UInt64 = CloudLocalRacePolicy.cloudDeadlineNanoseconds,
            cloudsDeadAtStop: Bool = false,
            localAvailable: Bool = true,
            localDuration: UInt64?,
            localFailsAfter: UInt64 = 500_000_000
        ) {
            self.cloudUsableAt = cloudUsableAt
            self.cloudExhaustedAt = cloudExhaustedAt
            self.cloudsDeadAtStop = cloudsDeadAtStop
            self.localAvailable = localAvailable
            self.localDuration = localDuration
            self.localFailsAfter = localFailsAfter
        }
    }

    public enum Source: String, Sendable { case cloud, local, none }

    public struct Outcome: Equatable, Sendable {
        public let source: Source
        public let selectedAt: UInt64
        public let reason: String?
        public let localStartedAt: UInt64?
    }

    public static func simulate(_ scenario: Scenario) -> Outcome {
        var now: UInt64 = 0
        var localStartedAt: UInt64?
        var localStart: LocalRaceStart?
        for _ in 0..<16 {
            let cloud: CloudRacePhase
            if let usable = scenario.cloudUsableAt, usable <= now, usable < scenario.cloudExhaustedAt {
                cloud = .usable
            } else if scenario.cloudExhaustedAt <= now {
                cloud = .exhausted
            } else {
                cloud = .pending
            }
            let local: LocalRacePhase
            if !scenario.localAvailable {
                local = .unavailable
            } else if let started = localStartedAt {
                if let duration = scenario.localDuration {
                    local = started &+ duration <= now ? .usable : .running
                } else {
                    local = started &+ scenario.localFailsAfter <= now ? .failed : .running
                }
            } else {
                local = .notStarted
            }

            switch CloudLocalRacePolicy.decide(
                elapsedSinceStop: now,
                cloud: cloud,
                local: local,
                cloudsDeadAtStop: scenario.cloudsDeadAtStop,
                localStart: localStart
            ) {
            case .takeCloud:
                return Outcome(source: .cloud, selectedAt: now, reason: nil, localStartedAt: localStartedAt)
            case .takeLocal(let reason):
                return Outcome(source: .local, selectedAt: now, reason: reason, localStartedAt: localStartedAt)
            case .noUsableResult:
                return Outcome(source: .none, selectedAt: now, reason: "all_providers_failed", localStartedAt: localStartedAt)
            case .startLocal(let start):
                localStartedAt = now
                localStart = start
                continue
            case .wait:
                break
            }

            // Advance to the next event strictly after `now`.
            var candidates: [UInt64] = [scenario.cloudExhaustedAt]
            if let usable = scenario.cloudUsableAt { candidates.append(usable) }
            if scenario.localAvailable, localStartedAt == nil {
                candidates.append(CloudLocalRacePolicy.localStartDelay(cloudsDeadAtStop: scenario.cloudsDeadAtStop))
            }
            if let started = localStartedAt {
                candidates.append(started &+ (scenario.localDuration ?? scenario.localFailsAfter))
            }
            guard let next = candidates.filter({ $0 > now }).min() else {
                return Outcome(source: .none, selectedAt: now, reason: "all_providers_failed", localStartedAt: localStartedAt)
            }
            now = next
        }
        return Outcome(source: .none, selectedAt: now, reason: "all_providers_failed", localStartedAt: localStartedAt)
    }
}

// MARK: - Network path

/// The network the session ran on (macOS `NWPathMonitor` plus system proxy
/// settings). Lets later analysis split sessions by Wi-Fi / hotspot / VPN.
public struct NetworkPathSnapshot: Codable, Equatable, Sendable {
    /// satisfied / unsatisfied / requiresConnection
    public var status: String
    /// wifi / cellular / wired / loopback / other / none
    public var interface: String
    /// e.g. ["utun4", "en0"]; the first is the path's preferred interface.
    public var interfaceNames: [String]
    public var isExpensive: Bool
    public var isConstrained: Bool
    /// An HTTP/HTTPS/SOCKS proxy or PAC is enabled in system settings.
    public var systemProxy: Bool?
    /// The preferred interface is a tunnel (utun/ipsec/ppp/tun/tap), as with
    /// a VPN or a TUN-mode proxy client.
    public var tunnelInterface: Bool?
    /// The path changed between the start of recording and persistence.
    public var changedDuringSession: Bool?

    public init(
        status: String,
        interface: String,
        interfaceNames: [String],
        isExpensive: Bool,
        isConstrained: Bool,
        systemProxy: Bool? = nil,
        tunnelInterface: Bool? = nil,
        changedDuringSession: Bool? = nil
    ) {
        self.status = status
        self.interface = interface
        self.interfaceNames = interfaceNames
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.systemProxy = systemProxy
        self.tunnelInterface = tunnelInterface
        self.changedDuringSession = changedDuringSession
    }

    public static func isTunnelInterfaceName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) }
    }
}
