import Foundation

struct PCM16Chunk: Sendable {
    let sequence: Int64
    let data: Data
    let capturedAt: Date
    let sampleRate: Int
    let channels: Int

    var durationSeconds: TimeInterval {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return Double(data.count) / Double(sampleRate * channels * 2)
    }
}

struct ASRContext: Sendable {
    let languages: [String]
    let terms: [String]
    let general: [String: String]
    let text: String
    let hotwordWeight: Int
    /// Background about the speaker. Soniox prepends it to `text`; other
    /// providers ignore it. Empty means none.
    let speakerBackground: String

    static func personal(
        terms: [String],
        instructions: String? = nil,
        hotwordWeight: Int = 4,
        speakerBackground: String = ""
    ) -> ASRContext {
        let literalInstructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstructions = literalInstructions?.isEmpty == false
            ? literalInstructions!
            : "逐字听写；保留重复、口头语、否定、自我修正和中英文切换；不要总结、改写、补全或结构化。根据真实停顿和句意使用自然标点。" // l10n:ignore 发给识别引擎的提示词
        return ASRContext(
            languages: ["zh", "en"],
            terms: Array(terms.prefix(2_000)),
            general: [
                "domain": "AI, software engineering, programming, product design and personal conversation",
                "language": "Primarily Simplified Chinese with frequent English technical terms",
                "instructions": resolvedInstructions
            ],
            text: resolvedInstructions,
            hotwordWeight: min(5, max(1, hotwordWeight)),
            speakerBackground: speakerBackground.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct ASRToken: Codable, Hashable, Sendable {
    let text: String
    let startMilliseconds: Int?
    let endMilliseconds: Int?
    let confidence: Double?
    let isFinal: Bool
    let language: String?
}

enum ASREvent: Sendable {
    case connected(providerID: String)
    case partial(providerID: String, text: String)
    case finalized(providerID: String, text: String)
    case warning(providerID: String, message: String)
    case failed(providerID: String, message: String)
}

struct TranscriptResult: Codable, Sendable {
    let providerID: String
    let model: String
    let text: String
    let tokens: [ASRToken]
    let startedAt: Date
    let finishedAt: Date
    let firstPartialLatencyMilliseconds: Int?
    let finalizeLatencyMilliseconds: Int?
    var transportMetrics: ProviderTransportMetrics? = nil
}

struct ProviderTransportMetrics: Codable, Sendable {
    let audioBytesSent: Int
    let audioFrameCount: Int
    let maxSendLatencyMilliseconds: Int
    let backpressureEventCount: Int
    var recoveryAttemptCount: Int? = nil
    /// Handshake + configuration (Soniox) or until `task-started` (Aliyun).
    /// nil when an existing warm socket was reused.
    var connectionSetupLatencyMilliseconds: Int? = nil
    /// 0.3.79+: the socket came from an earlier dictation (no handshake).
    var reusedConnection: Bool? = nil
    /// 0.3.79+: the hedged second connection attempt won the handshake race.
    var hedgedConnection: Bool? = nil
    /// 0.3.79+: sockets opened for this utterance (2 when hedged).
    var connectionAttemptCount: Int? = nil
}

enum DictationState: String, Codable, Sendable {
    case starting
    case listening
    case cancelPending
    case finalizing
    case inserting
    case preview
    case idle
    case failed
}

enum HistoryDisposition: String, Codable, Sendable {
    case committed
    case retainedDraft
    case failed
}

enum HistoryAudioState: String, Codable, Sendable {
    case available
    case unavailable
}

enum TranscriptRevisionSource: String, Codable, Sendable {
    case original
    case retranscription
}

struct TranscriptRevision: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let source: TranscriptRevisionSource
    let providerID: String
    let model: String
    let text: String
    let error: String?
}

enum InsertionStatus: String, Codable, Sendable {
    case inserted
    case dispatched
    case previewOnly
    case copied
    case canceled
    case failed
    case unconfirmed
}

enum InsertionTransport: String, Codable, Sendable {
    case accessibilityDirect
    case unicodeKeyboard
    case clipboardPaste
    case clipboardCopy
    case none
}

enum InsertionAttemptOutcome: String, Codable, Sendable {
    case confirmed
    case unchanged
    case ambiguous
    case unverifiable
    case dispatchFailed
}

struct InsertionAttemptSummary: Codable, Sendable {
    let transport: InsertionTransport
    let outcome: InsertionAttemptOutcome
    let detail: String
}

struct ProviderSummary: Codable, Sendable {
    let providerID: String
    let model: String
    let text: String
    let firstPartialLatencyMilliseconds: Int?
    let finalizeLatencyMilliseconds: Int?
    let error: String?
    let transportMetrics: ProviderTransportMetrics?
    var terminationReason: ProviderTerminationReason? = nil
    /// billing / auth / transient / other; absent in records before 0.3.74.
    var failureKind: ProviderFailureKind? = nil
    /// 0.3.79+: connected / first / last server message, as offsets from the
    /// session timeline origin. Present for failed runs too.
    var liveness: ProviderLivenessRecord? = nil
}

enum ProviderTerminationReason: String, Codable, Sendable {
    case completed
    case timedOut
    case cancelled
    case failed
    case quarantined
}

struct HistoryRecord: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let targetBundleIdentifier: String?
    let targetApplicationName: String?
    let primary: ProviderSummary?
    let appleBaseline: ProviderSummary?
    let comparisons: [ProviderSummary]?
    let effectiveProviderID: String?
    let usedOfflineFallback: Bool?
    let insertedText: String
    let insertionStatus: InsertionStatus
    let insertionTransport: InsertionTransport?
    let insertionAttempts: [InsertionAttemptSummary]?
    let providerContextReceipts: [ProviderContextReceipt]?
    let audioRelativePath: String?
    let preRollMilliseconds: Int
    let notes: [String]
    var schemaVersion: Int? = nil
    var appVersion: String? = nil
    var buildNumber: String? = nil
    var timeline: SessionTimelineSnapshot? = nil
    var selectedReason: String? = nil
    var userPathFinishedAt: Date? = nil
    var persistenceFinishedAt: Date? = nil
    var disposition: HistoryDisposition? = nil
    var audioState: HistoryAudioState? = nil
    var transcriptRevisions: [TranscriptRevision]? = nil
    var selectedRevisionID: UUID? = nil
    /// 0.3.79+: interface type, expensive/constrained, proxy and tunnel hints.
    var networkPath: NetworkPathSnapshot? = nil

    init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        targetBundleIdentifier: String?,
        targetApplicationName: String?,
        primary: ProviderSummary?,
        appleBaseline: ProviderSummary?,
        comparisons: [ProviderSummary]? = nil,
        effectiveProviderID: String? = nil,
        usedOfflineFallback: Bool? = nil,
        insertedText: String,
        insertionStatus: InsertionStatus,
        insertionTransport: InsertionTransport?,
        insertionAttempts: [InsertionAttemptSummary]?,
        providerContextReceipts: [ProviderContextReceipt]? = nil,
        audioRelativePath: String?,
        preRollMilliseconds: Int,
        notes: [String],
        schemaVersion: Int? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        timeline: SessionTimelineSnapshot? = nil,
        selectedReason: String? = nil,
        userPathFinishedAt: Date? = nil,
        persistenceFinishedAt: Date? = nil,
        disposition: HistoryDisposition? = nil,
        audioState: HistoryAudioState? = nil,
        transcriptRevisions: [TranscriptRevision]? = nil,
        selectedRevisionID: UUID? = nil,
        networkPath: NetworkPathSnapshot? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetApplicationName = targetApplicationName
        self.primary = primary
        self.appleBaseline = appleBaseline
        self.comparisons = comparisons
        self.effectiveProviderID = effectiveProviderID
        self.usedOfflineFallback = usedOfflineFallback
        self.insertedText = insertedText
        self.insertionStatus = insertionStatus
        self.insertionTransport = insertionTransport
        self.insertionAttempts = insertionAttempts
        self.providerContextReceipts = providerContextReceipts
        self.audioRelativePath = audioRelativePath
        self.preRollMilliseconds = preRollMilliseconds
        self.notes = notes
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.timeline = timeline
        self.selectedReason = selectedReason
        self.userPathFinishedAt = userPathFinishedAt
        self.persistenceFinishedAt = persistenceFinishedAt
        self.disposition = disposition
        self.audioState = audioState
        self.transcriptRevisions = transcriptRevisions
        self.selectedRevisionID = selectedRevisionID
        self.networkPath = networkPath
    }
}

struct TranscriptRevisionRecord: Codable, Sendable {
    let sessionID: UUID
    let revision: TranscriptRevision
}

struct CorrectionReplacement: Codable, Hashable, Sendable {
    let original: String
    let corrected: String
    let punctuationOnly: Bool
}

struct HistoryActionRecord: Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let occurredAt: Date
    let insertionStatus: InsertionStatus?
    let correctedText: String?
    let message: String
    let originalText: String?
    let correctionSource: String?
    let targetBundleIdentifier: String?
    let replacements: [CorrectionReplacement]?

    init(
        id: UUID,
        sessionID: UUID,
        occurredAt: Date,
        insertionStatus: InsertionStatus?,
        correctedText: String?,
        message: String,
        originalText: String? = nil,
        correctionSource: String? = nil,
        targetBundleIdentifier: String? = nil,
        replacements: [CorrectionReplacement]? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.occurredAt = occurredAt
        self.insertionStatus = insertionStatus
        self.correctedText = correctedText
        self.message = message
        self.originalText = originalText
        self.correctionSource = correctionSource
        self.targetBundleIdentifier = targetBundleIdentifier
        self.replacements = replacements
    }
}

struct CorrectionSuggestion: Identifiable, Sendable {
    let original: String
    let corrected: String
    let occurrences: Int
    let punctuationOnly: Bool

    var id: String { original + "\u{1F}" + corrected }
}

struct StorageMaintenanceResult: Sendable {
    let deletedAudioFiles: Int
    let reclaimedBytes: Int64
}

struct AppProfile: Sendable {
    let bundleIdentifier: String?
    let kind: AppKind
    let removeTerminalPeriod: Bool
    let appendTrailingSpaceAfterEnglish: Bool
    let stripTrailingNewline: Bool

    static func profile(for bundleIdentifier: String?) -> AppProfile {
        let id = bundleIdentifier ?? ""

        let chatIDs: Set<String> = [
            "com.openai.chat",
            "com.openai.codex",
            "com.tencent.xinWeChat",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "ru.keepcoder.Telegram",
            "com.bytedance.macos.feishu",
            "com.lark.mac"
        ]
        let terminalIDs: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable"
        ]
        let codingIDs: Set<String> = [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.apple.dt.Xcode",
            "com.exafunction.windsurf"
        ]

        if chatIDs.contains(id) {
            return AppProfile(bundleIdentifier: bundleIdentifier, kind: .chat, removeTerminalPeriod: true, appendTrailingSpaceAfterEnglish: true, stripTrailingNewline: true)
        }
        if terminalIDs.contains(id) {
            return AppProfile(bundleIdentifier: bundleIdentifier, kind: .terminal, removeTerminalPeriod: false, appendTrailingSpaceAfterEnglish: false, stripTrailingNewline: true)
        }
        if codingIDs.contains(id) {
            return AppProfile(bundleIdentifier: bundleIdentifier, kind: .coding, removeTerminalPeriod: false, appendTrailingSpaceAfterEnglish: false, stripTrailingNewline: true)
        }
        if id.contains("Safari") || id.contains("Chrome") || id.contains("Arc") {
            return AppProfile(bundleIdentifier: bundleIdentifier, kind: .chat, removeTerminalPeriod: true, appendTrailingSpaceAfterEnglish: true, stripTrailingNewline: true)
        }
        return AppProfile(bundleIdentifier: bundleIdentifier, kind: .unknown, removeTerminalPeriod: false, appendTrailingSpaceAfterEnglish: true, stripTrailingNewline: true)
    }
}
