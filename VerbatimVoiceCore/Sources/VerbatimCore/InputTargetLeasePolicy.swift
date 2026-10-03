import Foundation

/// Platform-neutral evidence used to resolve where a completed dictation may
/// be committed. The lease intentionally binds to an application, not to one
/// ephemeral Accessibility object: input methods commit at the current caret,
/// while modern editors routinely rebuild their AX/DOM nodes.
public struct InputTargetLeaseEvidence: Equatable, Sendable {
    public let processExists: Bool
    public let bundleIdentifierMatches: Bool
    public let applicationIsFrontmost: Bool
    public let secureInputEnabled: Bool
    public let liveEditableTargetAvailable: Bool
    public let liveTargetIsSecure: Bool
    public let liveTargetHasComposition: Bool

    public init(
        processExists: Bool,
        bundleIdentifierMatches: Bool,
        applicationIsFrontmost: Bool,
        secureInputEnabled: Bool,
        liveEditableTargetAvailable: Bool,
        liveTargetIsSecure: Bool,
        liveTargetHasComposition: Bool
    ) {
        self.processExists = processExists
        self.bundleIdentifierMatches = bundleIdentifierMatches
        self.applicationIsFrontmost = applicationIsFrontmost
        self.secureInputEnabled = secureInputEnabled
        self.liveEditableTargetAvailable = liveEditableTargetAvailable
        self.liveTargetIsSecure = liveTargetIsSecure
        self.liveTargetHasComposition = liveTargetHasComposition
    }
}

public enum InputTargetLeaseRejection: String, Equatable, Sendable {
    case applicationExited
    case applicationIdentityChanged
    case applicationNotFrontmost
    case secureInputEnabled
    case secureField
    case compositionActive
}

public enum InputTargetLeaseDecision: Equatable, Sendable {
    /// Commit to the freshly resolved editable target and verify when the app
    /// exposes enough Accessibility evidence.
    case liveEditableTarget
    /// Commit to the application's current keyboard focus. This covers remote
    /// canvases, terminals and custom editors that deliberately expose no AX
    /// text node; the result is dispatchable but locally unverifiable.
    case keyboardFocus
    case reject(InputTargetLeaseRejection)
}

public enum InputTargetLeasePolicy {
    public static func resolve(_ evidence: InputTargetLeaseEvidence) -> InputTargetLeaseDecision {
        guard evidence.processExists else { return .reject(.applicationExited) }
        guard evidence.bundleIdentifierMatches else { return .reject(.applicationIdentityChanged) }
        guard evidence.applicationIsFrontmost else { return .reject(.applicationNotFrontmost) }
        guard !evidence.secureInputEnabled else { return .reject(.secureInputEnabled) }
        guard !evidence.liveTargetIsSecure else { return .reject(.secureField) }
        guard !evidence.liveTargetHasComposition else { return .reject(.compositionActive) }
        return evidence.liveEditableTargetAvailable ? .liveEditableTarget : .keyboardFocus
    }
}
