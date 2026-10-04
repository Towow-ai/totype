import Combine
import Foundation

enum PrimaryTranscriptionProvider: String, CaseIterable, Identifiable {
    case localSenseVoice
    case aliyun
    case soniox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localSenseVoice: return String(localized: "SenseVoiceSmall q8（本地）")
        case .aliyun: return String(localized: "阿里云千问实时语音（云端）")
        case .soniox: return String(localized: "Soniox stt-rt-v5（云端）")
        }
    }

    var shortName: String {
        switch self {
        case .localSenseVoice: return String(localized: "本地")
        case .aliyun: return String(localized: "阿里云")
        case .soniox: return "Soniox"
        }
    }
}

enum HistoryRetranscriptionProvider: String, CaseIterable, Identifiable {
    case automatic
    case soniox
    case aliyun
    case localSenseVoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "自动")
        case .soniox: return "Soniox"
        case .aliyun: return String(localized: "阿里云")
        case .localSenseVoice: return String(localized: "本地")
        }
    }
}

/// The modifier key whose single tap starts and ends a recording.
enum TriggerKey: String, CaseIterable, Identifiable, Sendable {
    case rightOption
    case rightCommand
    case leftOption
    case leftControl
    case function = "fn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return String(localized: "右 Option")
        case .rightCommand: return String(localized: "右 Command")
        case .leftOption: return String(localized: "左 Option")
        case .leftControl: return String(localized: "左 Control")
        case .function: return String(localized: "Fn（🌐）")
        }
    }

    /// macOS can bind the key to its own action; the settings page says so.
    var systemConflictNote: String? {
        switch self {
        case .function:
            return String(localized: "使用 Fn 前，请到 系统设置 → 键盘，把“按下 🌐 键时”改为“不执行任何操作”；如果 键盘 → 听写 → 快捷键 设为“按两下 🌐”，也请改掉，否则快速开始再结束会同时唤起系统听写。")
        default:
            return nil
        }
    }
}

enum AliyunRegion: String, CaseIterable, Identifiable, Sendable {
    case beijing
    case singapore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beijing: return String(localized: "华北2（北京）")
        case .singapore: return String(localized: "新加坡")
        }
    }

    var webSocketHost: String {
        switch self {
        case .beijing: return "dashscope.aliyuncs.com"
        case .singapore: return "dashscope-intl.aliyuncs.com"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let warmConnectionTTL = "warmConnectionTTL"
        static let preRollMilliseconds = "preRollMilliseconds"
        static let postRollMilliseconds = "postRollMilliseconds"
        static let appleBaselineEnabled = "appleBaselineEnabled"
        static let saveAudio = "saveAudio"
        static let removeChatTerminalPeriod = "removeChatTerminalPeriod"
        static let appendTrailingSpaceAfterEnglish = "appendTrailingSpaceAfterEnglish"
        static let overlayNearFocusedControl = "overlayNearFocusedControl"
        static let glossaryText = "glossaryText"
        static let maximumUtteranceSeconds = "maximumUtteranceSeconds"
        static let audioRetentionDays = "audioRetentionDays"
        static let audioQuotaMegabytes = "audioQuotaMegabytes"
        static let primaryProvider = "primaryProvider"
        static let aliyunRegion = "aliyunRegion"
        static let transcriptionPrompt = "transcriptionPrompt"
        static let automaticLocalFallback = "automaticLocalFallback"
        static let correctionCaptureEnabled = "correctionCaptureEnabled"
        static let hotwordWeight = "hotwordWeight"
        static let speakerBackground = "speakerBackground"
        static let starterGlossaryEnabled = "starterGlossaryEnabled"
        static let triggerKey = "triggerKey"
    }

    @Published var warmConnectionTTL: Double {
        didSet { defaults.set(warmConnectionTTL, forKey: Key.warmConnectionTTL) }
    }
    @Published var preRollMilliseconds: Int {
        didSet { defaults.set(preRollMilliseconds, forKey: Key.preRollMilliseconds) }
    }
    @Published var postRollMilliseconds: Int {
        didSet { defaults.set(postRollMilliseconds, forKey: Key.postRollMilliseconds) }
    }
    @Published var appleBaselineEnabled: Bool {
        didSet { defaults.set(appleBaselineEnabled, forKey: Key.appleBaselineEnabled) }
    }
    @Published var saveAudio: Bool {
        didSet { defaults.set(saveAudio, forKey: Key.saveAudio) }
    }
    @Published var removeChatTerminalPeriod: Bool {
        didSet { defaults.set(removeChatTerminalPeriod, forKey: Key.removeChatTerminalPeriod) }
    }
    @Published var appendTrailingSpaceAfterEnglish: Bool {
        didSet { defaults.set(appendTrailingSpaceAfterEnglish, forKey: Key.appendTrailingSpaceAfterEnglish) }
    }
    @Published var overlayNearFocusedControl: Bool {
        didSet { defaults.set(overlayNearFocusedControl, forKey: Key.overlayNearFocusedControl) }
    }
    @Published var glossaryText: String {
        didSet { defaults.set(glossaryText, forKey: Key.glossaryText) }
    }
    @Published var maximumUtteranceSeconds: Int {
        didSet { defaults.set(maximumUtteranceSeconds, forKey: Key.maximumUtteranceSeconds) }
    }
    @Published var audioRetentionDays: Int {
        didSet { defaults.set(audioRetentionDays, forKey: Key.audioRetentionDays) }
    }
    @Published var audioQuotaMegabytes: Int {
        didSet { defaults.set(audioQuotaMegabytes, forKey: Key.audioQuotaMegabytes) }
    }
    @Published var primaryProvider: PrimaryTranscriptionProvider {
        didSet { defaults.set(primaryProvider.rawValue, forKey: Key.primaryProvider) }
    }
    @Published var aliyunRegion: AliyunRegion {
        didSet { defaults.set(aliyunRegion.rawValue, forKey: Key.aliyunRegion) }
    }
    @Published var transcriptionPrompt: String {
        didSet { defaults.set(transcriptionPrompt, forKey: Key.transcriptionPrompt) }
    }
    @Published var automaticLocalFallback: Bool {
        didSet { defaults.set(automaticLocalFallback, forKey: Key.automaticLocalFallback) }
    }
    @Published var correctionCaptureEnabled: Bool {
        didSet { defaults.set(correctionCaptureEnabled, forKey: Key.correctionCaptureEnabled) }
    }
    @Published var hotwordWeight: Int {
        didSet { defaults.set(hotwordWeight, forKey: Key.hotwordWeight) }
    }
    /// Background about the speaker, sent to Soniox as `context.text`. Empty
    /// by default: the app ships no knowledge of any particular person.
    @Published var speakerBackground: String {
        didSet { defaults.set(speakerBackground, forKey: Key.speakerBackground) }
    }
    @Published var starterGlossaryEnabled: Bool {
        didSet { defaults.set(starterGlossaryEnabled, forKey: Key.starterGlossaryEnabled) }
    }
    @Published var triggerKey: TriggerKey {
        didSet { defaults.set(triggerKey.rawValue, forKey: Key.triggerKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        warmConnectionTTL = defaults.object(forKey: Key.warmConnectionTTL) as? Double ?? 30
        preRollMilliseconds = defaults.object(forKey: Key.preRollMilliseconds) as? Int ?? 300
        postRollMilliseconds = defaults.object(forKey: Key.postRollMilliseconds) as? Int ?? 120
        appleBaselineEnabled = defaults.object(forKey: Key.appleBaselineEnabled) as? Bool ?? false
        saveAudio = defaults.object(forKey: Key.saveAudio) as? Bool ?? true
        // Literal-first defaults: never change punctuation or append spacing
        // unless the user explicitly opts into those insertion conveniences.
        removeChatTerminalPeriod = defaults.object(forKey: Key.removeChatTerminalPeriod) as? Bool ?? false
        appendTrailingSpaceAfterEnglish = defaults.object(forKey: Key.appendTrailingSpaceAfterEnglish) as? Bool ?? false
        // Retire the legacy always-on microphone preference. Older builds may
        // have persisted it as true, but a session-scoped input is required so
        // Continuity features remain available while Totype is idle.
        defaults.set(false, forKey: "keepMicrophoneWarm")
        overlayNearFocusedControl = defaults.object(forKey: Key.overlayNearFocusedControl) as? Bool ?? false
        glossaryText = defaults.string(forKey: Key.glossaryText) ?? Self.defaultGlossary
        maximumUtteranceSeconds = defaults.object(forKey: Key.maximumUtteranceSeconds) as? Int ?? 600
        audioRetentionDays = defaults.object(forKey: Key.audioRetentionDays) as? Int ?? 30
        audioQuotaMegabytes = defaults.object(forKey: Key.audioQuotaMegabytes) as? Int ?? 2_048
        primaryProvider = PrimaryTranscriptionProvider(
            rawValue: defaults.string(forKey: Key.primaryProvider) ?? ""
        ) ?? .localSenseVoice
        aliyunRegion = AliyunRegion(
            rawValue: defaults.string(forKey: Key.aliyunRegion) ?? ""
        ) ?? .beijing
        transcriptionPrompt = defaults.string(forKey: Key.transcriptionPrompt)
            ?? Self.defaultTranscriptionPrompt
        automaticLocalFallback = defaults.object(forKey: Key.automaticLocalFallback) as? Bool ?? true
        correctionCaptureEnabled = defaults.object(forKey: Key.correctionCaptureEnabled) as? Bool ?? AppIdentity.learnFromEditsDefault
        hotwordWeight = defaults.object(forKey: Key.hotwordWeight) as? Int ?? 4
        speakerBackground = defaults.string(forKey: Key.speakerBackground) ?? ""
        starterGlossaryEnabled = defaults.object(forKey: Key.starterGlossaryEnabled) as? Bool ?? false
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Key.triggerKey) ?? "") ?? .rightOption
    }

    var glossaryTerms: [String] {
        var seen: Set<String> = []
        return glossaryText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                guard !$0.isEmpty else { return false }
                return seen.insert($0.lowercased()).inserted
            }
    }

    static let defaultGlossary = ""

    private static let defaultTranscriptionPrompt = """
逐字听写；保留重复、口头语、否定、自我修正与中英文切换；不要总结、改写、补全、纠正语义或结构化。根据真实停顿和句意使用自然的简体中文标点：短停顿优先逗号，语意完整才用句号，只有真实疑问才用问号；不要为了句式整齐删除原话。
"""
}
