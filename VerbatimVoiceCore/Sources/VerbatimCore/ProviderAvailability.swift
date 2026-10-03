import Foundation

/// Why a cloud provider refused or lost a request. Only `transient` may be
/// retried inside a session; `billing` and `auth` take the provider out of the
/// user path until it is proven healthy again.
public enum ProviderFailureKind: String, Codable, Sendable, CaseIterable {
    /// Balance, budget or purchased quota exhausted (Soniox 402, Aliyun Arrearage).
    case billing
    /// Key invalid, expired, revoked or lacking permission (401/403).
    case auth
    /// Timeouts, overload and server errors that a new request can fix.
    case transient
    case other

    /// Retrying cannot help; the provider stays unusable until the user acts.
    public var disablesProvider: Bool { self == .billing || self == .auth }
    public var isRetryable: Bool { self == .transient }
}

/// Maps provider error identifiers onto `ProviderFailureKind`.
///
/// Sources (checked 2026-10-01):
/// - Soniox: https://soniox.com/docs/api-reference/errors — one `error_type`
///   taxonomy for REST and the STT WebSocket; the WebSocket sends
///   `{error_code, error_type, error_message}` and then closes.
/// - Aliyun Model Studio (百炼/DashScope): https://help.aliyun.com/zh/model-studio/error-code
///   — the realtime WebSocket reports `task-failed` with `header.error_code`.
public enum ProviderFailureClassifier {
    public static let sonioxBillingTypes: Set<String> = [
        "organization_balance_exhausted",          // 402, balance is zero
        "organization_monthly_budget_exhausted",   // 402, org monthly cap
        "project_monthly_budget_exhausted",        // 402, project monthly cap
    ]
    public static let sonioxAuthTypes: Set<String> = [
        "unauthenticated",                 // 401, missing/malformed/revoked/expired key
        "permission_denied",               // 403, key lacks the permission
        "temp_api_key_session_expired",    // 403, temporary key session cap
    ]
    /// Identical to `SonioxRecoveryPolicy.isRetryableServerError`.
    public static let sonioxTransientTypes: Set<String> = [
        "request_timeout",       // 408
        "service_unavailable",   // 503, early termination
        "internal_error",        // 500
    ]

    public static let aliyunBillingCodes: Set<String> = [
        "Arrearage",                    // 400, account in arrears
        "AllocationQuota.FreeTierOnly", // 403, free tier used up, "free tier only" on
        "AccessDenied.Unpurchased",     // 403, model not purchased
        "CommodityNotPurchased",        // 429, workspace not purchased
        "PrepaidBillOverdue",           // 429
        "PostpaidBillOverdue",          // 429
        "BudgetLimitExceeded",          // 429, budget stop reached
    ]
    public static let aliyunAuthCodes: Set<String> = [
        "InvalidApiKey", "invalid_api_key",   // 401
        "NOT AUTHORIZED",                     // 401
        "AccessDenied", "access_denied",      // 403
        "Model.AccessDenied", "App.AccessDenied",
        "Workspace.AccessDenied", "Endpoint.AccessDenied",
    ]
    public static let aliyunTransientCodes: Set<String> = [
        "InternalError", "internal_error", "InternalError.Timeout", "InternalError.Algo",
        "SystemError", "ModelServiceFailed", "RequestTimeOut", "ResponseTimeout",
        "ServiceUnavailable", "ServiceUnavailableError", "ModelUnavailable",
        "Throttling.ServiceOverloaded", "Throttling.ResourceExhausted", "Throttling.Concurrency",
    ]
    /// `Throttling.AllocationQuota` / `insufficient_quota` is a TPS/TPM rate
    /// limit on Aliyun, not billing — except the "Free allocated quota
    /// exceeded" variant, where a free-only model has no paid fallback.
    public static let aliyunQuotaCodes: Set<String> = [
        "Throttling.AllocationQuota", "insufficient_quota",
    ]

    public static func soniox(errorType: String?, errorCode: Int?) -> ProviderFailureKind {
        if let errorType {
            if sonioxBillingTypes.contains(errorType) { return .billing }
            if sonioxAuthTypes.contains(errorType) { return .auth }
            if sonioxTransientTypes.contains(errorType) { return .transient }
        }
        // Unknown slug: the documented status code is the same on every surface.
        if let errorCode { return httpStatus(errorCode) }
        return .other
    }

    public static func aliyun(code: String?, message: String?) -> ProviderFailureKind {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
            return message.map(classify(message:)) ?? .other
        }
        if aliyunBillingCodes.contains(code) { return .billing }
        if aliyunAuthCodes.contains(code) { return .auth }
        if aliyunTransientCodes.contains(code) { return .transient }
        if aliyunQuotaCodes.contains(code) {
            let lowered = (message ?? "").lowercased()
            return lowered.contains("free allocated quota exceeded") ? .billing : .other
        }
        return .other
    }

    /// For WebSocket handshakes rejected with an HTTP status.
    public static func httpStatus(_ status: Int) -> ProviderFailureKind {
        switch status {
        case 402: return .billing
        case 401, 403: return .auth
        case 408, 500...599: return .transient
        default: return .other
        }
    }

    /// Fallback for an error that only survives as text (history written
    /// before failure kinds existed). Billing identifiers win over auth ones
    /// because `AccessDenied.Unpurchased` also contains `AccessDenied`.
    public static func classify(message: String) -> ProviderFailureKind {
        let billingMarkers = Array(sonioxBillingTypes) + Array(aliyunBillingCodes)
            + ["free allocated quota exceeded", "please make sure your account is in good standing"]
        let lowered = message.lowercased()
        if billingMarkers.contains(where: { lowered.contains($0.lowercased()) }) { return .billing }
        if sonioxAuthTypes.contains(where: { lowered.contains($0) })
            || aliyunAuthCodes.contains(where: { message.contains($0) })
            || lowered.contains("incorrect api key") || lowered.contains("invalid api-key") {
            return .auth
        }
        if sonioxTransientTypes.contains(where: { lowered.contains($0) }) { return .transient }
        return .other
    }

    /// One line for the user, e.g. "Soniox 余额不足，已改用阿里云".
    public static func notice(
        kind: ProviderFailureKind,
        providerName: String,
        fallbackName: String?
    ) -> String {
        let reason: String
        switch kind {
        case .billing: reason = "\(providerName) 余额不足"
        case .auth: reason = "\(providerName) Key 无效"
        case .transient, .other: reason = "\(providerName) 暂时不可用"
        }
        guard let fallbackName else { return reason }
        return "\(reason)，已改用\(fallbackName)"
    }
}

/// A provider known to reject requests for a reason retrying cannot fix.
/// Lives for the process lifetime only: a relaunch tries the provider again.
public struct ProviderOutage: Codable, Equatable, Sendable {
    public let providerID: String
    public var kind: ProviderFailureKind
    public var message: String
    public let since: Date
    /// Last time the outage was confirmed by a session or a probe.
    public var confirmedAt: Date

    public init(providerID: String, kind: ProviderFailureKind, message: String, since: Date, confirmedAt: Date? = nil) {
        self.providerID = providerID
        self.kind = kind
        self.message = message
        self.since = since
        self.confirmedAt = confirmedAt ?? since
    }
}

public enum ProviderProbeResult: Equatable, Sendable {
    /// The provider accepted a request and finalized it.
    case available
    case failed(kind: ProviderFailureKind, message: String)
}

/// Pure routing and recovery rules for an unusable cloud provider.
public enum ProviderAvailabilityPolicy {
    /// A background probe of an unusable provider runs at most this often
    /// (unless the user presses 重试).
    public static let probeIntervalSeconds: TimeInterval = 600

    public struct Route: Equatable, Sendable {
        public let primaryID: String
        public let standbyID: String?
        /// Set when the configured primary is skipped because of this outage.
        public let bypassedOutage: ProviderOutage?
    }

    /// Session-start routing. A primary in outage hands the user path to the
    /// standby (no extra wait, no preference window); a standby in outage is
    /// not started. If both are out, run the configuration as is — one of
    /// them may have recovered, and the local fallback still follows.
    public static func route(
        configuredPrimaryID: String,
        configuredStandbyID: String?,
        outages: [String: ProviderOutage]
    ) -> Route {
        let primaryOut = outages[configuredPrimaryID]
        let standbyOut = configuredStandbyID.flatMap { outages[$0] }
        if let primaryOut, let standby = configuredStandbyID, standbyOut == nil {
            return Route(primaryID: standby, standbyID: nil, bypassedOutage: primaryOut)
        }
        if primaryOut == nil, standbyOut != nil {
            return Route(primaryID: configuredPrimaryID, standbyID: nil, bypassedOutage: nil)
        }
        return Route(primaryID: configuredPrimaryID, standbyID: configuredStandbyID, bypassedOutage: nil)
    }

    public static func shouldProbe(
        outage: ProviderOutage?,
        lastProbeAt: Date?,
        now: Date,
        userRequested: Bool = false
    ) -> Bool {
        guard outage != nil else { return false }
        if userRequested { return true }
        guard let lastProbeAt else { return true }
        return now.timeIntervalSince(lastProbeAt) >= probeIntervalSeconds
    }

    /// State after a provider ran in a real session. `completed` means the
    /// provider finalized (even with empty text): it is reachable and paid up.
    public static func record(
        providerID: String,
        completed: Bool,
        failureKind: ProviderFailureKind?,
        message: String?,
        now: Date,
        current: ProviderOutage?
    ) -> ProviderOutage? {
        if completed { return nil }
        guard let failureKind, failureKind.disablesProvider else { return current }
        if var current, current.providerID == providerID {
            current.kind = failureKind
            current.message = message ?? current.message
            current.confirmedAt = now
            return current
        }
        return ProviderOutage(
            providerID: providerID,
            kind: failureKind,
            message: message ?? failureKind.rawValue,
            since: now
        )
    }

    /// Recovery: success clears; billing/auth re-confirms; a transient or
    /// unknown failure proves nothing and keeps the outage as it was.
    public static func apply(
        probe: ProviderProbeResult,
        now: Date,
        current: ProviderOutage?
    ) -> ProviderOutage? {
        switch probe {
        case .available:
            return nil
        case .failed(let kind, let message):
            guard var current else { return nil }
            guard kind.disablesProvider else { return current }
            current.kind = kind
            current.message = message
            current.confirmedAt = now
            return current
        }
    }
}

/// Thread-safe holder of the outages for the process lifetime. Nothing is
/// written to disk: a relaunch simply tries every provider again.
public final class ProviderOutageTracker: @unchecked Sendable {
    public enum Change: Equatable, Sendable {
        case unchanged
        /// The provider has just become unusable.
        case began(ProviderOutage)
        case refreshed(ProviderOutage)
        case recovered(providerID: String)
    }

    private let lock = NSLock()
    private var outages: [String: ProviderOutage] = [:]
    private var lastProbeAt: [String: Date] = [:]

    public init() {}

    public func snapshot() -> [String: ProviderOutage] {
        lock.lock()
        defer { lock.unlock() }
        return outages
    }

    public func outage(for providerID: String) -> ProviderOutage? {
        lock.lock()
        defer { lock.unlock() }
        return outages[providerID]
    }

    @discardableResult
    public func record(
        providerID: String,
        completed: Bool,
        failureKind: ProviderFailureKind?,
        message: String?,
        now: Date = Date()
    ) -> Change {
        lock.lock()
        defer { lock.unlock() }
        let before = outages[providerID]
        let after = ProviderAvailabilityPolicy.record(
            providerID: providerID,
            completed: completed,
            failureKind: failureKind,
            message: message,
            now: now,
            current: before
        )
        return store(providerID: providerID, before: before, after: after)
    }

    /// Atomically claims the probe slot. Returns false when no probe is due.
    public func beginProbeIfDue(providerID: String, now: Date = Date(), userRequested: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ProviderAvailabilityPolicy.shouldProbe(
            outage: outages[providerID],
            lastProbeAt: lastProbeAt[providerID],
            now: now,
            userRequested: userRequested
        ) else { return false }
        lastProbeAt[providerID] = now
        return true
    }

    @discardableResult
    public func apply(probe: ProviderProbeResult, providerID: String, now: Date = Date()) -> Change {
        lock.lock()
        defer { lock.unlock() }
        let before = outages[providerID]
        let after = ProviderAvailabilityPolicy.apply(probe: probe, now: now, current: before)
        return store(providerID: providerID, before: before, after: after)
    }

    private func store(providerID: String, before: ProviderOutage?, after: ProviderOutage?) -> Change {
        outages[providerID] = after
        switch (before, after) {
        case (nil, nil): return .unchanged
        case (nil, let began?): return .began(began)
        case (_?, nil):
            lastProbeAt[providerID] = nil
            return .recovered(providerID: providerID)
        case (let old?, let new?): return old == new ? .unchanged : .refreshed(new)
        }
    }
}

// MARK: - Result selection after stop

/// What is known about one cloud provider at a selection checkpoint.
public enum CloudCandidateState: Equatable, Sendable {
    case pending
    /// Finalized with non-empty text.
    case usable
    /// Finished without usable text; the kind is nil for cancellations and
    /// empty finals.
    case failed(ProviderFailureKind?)
}

/// Where the post-stop selection is.
public enum CloudSelectionStage: Equatable, Sendable {
    /// The primary's preference window has not ended and it is still pending.
    case preference
    /// First check after the preference window ended or the primary finished.
    case softDeadline
    /// A race between both providers produced a result.
    case race
    /// The shared cloud deadline has passed.
    case deadline
}

public enum CloudSelectionDecision: Equatable, Sendable {
    case takePrimary(reason: String)
    case takeStandby(reason: String)
    /// Keep waiting for the primary (no standby, or still in its window).
    case waitForPrimary
    /// The primary can no longer produce a result; wait for the standby only.
    case waitForStandby
    /// Both may still finish: the first usable final wins.
    case waitForFirstUsable
    case noUsableResult
}

/// Single source of the cloud selection rules for macOS (`AppModel.finish`)
/// and iOS (`MobileTranscriptionSession.selectResult`). The async drivers only
/// gather `CloudCandidateState`s at checkpoints and act on the decision.
///
/// Rules, in order:
/// 1. A usable primary always wins.
/// 2. A primary that failed with billing/auth is out immediately: a usable
///    standby wins at once, a pending standby is waited for alone, with no
///    preference window (`standby_after_primary_billing|auth`).
/// 3. Inside the preference window a pending primary is waited for.
/// 4. After it, an already-finished standby wins; otherwise the first usable
///    final wins inside the cloud deadline.
public enum CloudSelectionPolicy {
    /// The primary's preference window after stop. A primary that is already
    /// silent (never connected for 3 s, or reported a failure) gets none: the
    /// standby is taken at once when ready instead of after 750 ms.
    public static func preferenceWindowNanoseconds(primarySilent: Bool) -> UInt64 {
        primarySilent ? 0 : RealtimeCompletionPolicy.primaryPreferenceNanoseconds
    }

    public static func decide(
        primary: CloudCandidateState,
        standby: CloudCandidateState?,
        stage: CloudSelectionStage,
        primarySilent: Bool = false
    ) -> CloudSelectionDecision {
        let afterSoftDeadline = stage == .race || stage == .deadline
        if primary == .usable {
            return .takePrimary(reason: afterSoftDeadline ? "primary_completed_after_soft_deadline" : "primary_completed")
        }

        if case .failed(let kind?) = primary, kind.disablesProvider {
            switch standby {
            case .usable?:
                return .takeStandby(reason: "standby_after_primary_\(kind.rawValue)")
            case .pending?:
                return stage == .deadline ? .noUsableResult : .waitForStandby
            case .failed?, nil:
                return .noUsableResult
            }
        }

        if primary == .pending, stage == .preference {
            return .waitForPrimary
        }
        if standby == .usable {
            if primarySilent, primary == .pending, !afterSoftDeadline {
                return .takeStandby(reason: "standby_primary_silent")
            }
            return .takeStandby(reason: afterSoftDeadline ? "standby_won_after_soft_deadline" : "standby_ready_at_soft_deadline")
        }
        if stage == .deadline { return .noUsableResult }

        switch (primary, standby) {
        case (.pending, nil):
            return .waitForPrimary
        case (.pending, .pending?), (.pending, .failed?):
            return .waitForFirstUsable
        case (.failed, .pending?):
            return .waitForStandby
        default:
            return .noUsableResult
        }
    }
}
