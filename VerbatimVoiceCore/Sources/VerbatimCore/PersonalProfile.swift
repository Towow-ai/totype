import Foundation

/// Everything a user can carry from one install to another: vocabulary,
/// speaker background, prompt, engine and insertion choices. API keys,
/// history and audio are deliberately not part of it.
///
/// Every field is optional on read. A missing section or key means "leave the
/// current value alone", so files written by an older version, or by hand,
/// import cleanly.
public struct PersonalProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct LexiconEntry: Codable, Equatable, Sendable {
        public var canonical: String
        public var aliases: [String]
        public var pinned: Bool

        public init(canonical: String, aliases: [String] = [], pinned: Bool = false) {
            self.canonical = canonical
            self.aliases = aliases
            self.pinned = pinned
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            canonical = try container.decode(String.self, forKey: .canonical)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }
    }

    public struct Engine: Codable, Equatable, Sendable {
        public var primaryProvider: String?
        public var aliyunRegion: String?
        /// Informational: the app currently sends a fixed zh + en hint list,
        /// so import ignores this field.
        public var languageHints: [String]?
        public var automaticLocalFallback: Bool?

        public init(
            primaryProvider: String? = nil,
            aliyunRegion: String? = nil,
            languageHints: [String]? = nil,
            automaticLocalFallback: Bool? = nil
        ) {
            self.primaryProvider = primaryProvider
            self.aliyunRegion = aliyunRegion
            self.languageHints = languageHints
            self.automaticLocalFallback = automaticLocalFallback
        }
    }

    public struct Insertion: Codable, Equatable, Sendable {
        public var removeChatTerminalPeriod: Bool?
        public var appendTrailingSpaceAfterEnglish: Bool?

        public init(removeChatTerminalPeriod: Bool? = nil, appendTrailingSpaceAfterEnglish: Bool? = nil) {
            self.removeChatTerminalPeriod = removeChatTerminalPeriod
            self.appendTrailingSpaceAfterEnglish = appendTrailingSpaceAfterEnglish
        }
    }

    public struct Retention: Codable, Equatable, Sendable {
        public var audioRetentionDays: Int?
        public var audioQuotaMegabytes: Int?

        public init(audioRetentionDays: Int? = nil, audioQuotaMegabytes: Int? = nil) {
            self.audioRetentionDays = audioRetentionDays
            self.audioQuotaMegabytes = audioQuotaMegabytes
        }
    }

    public struct Hotkey: Codable, Equatable, Sendable {
        /// `TriggerKey` raw value, e.g. "rightOption" or "fn".
        public var trigger: String?

        public init(trigger: String? = nil) {
            self.trigger = trigger
        }
    }

    public struct Interface: Codable, Equatable, Sendable {
        /// `InterfaceLanguage` raw value: "system", "zh-Hans" or "en".
        public var language: String?

        public init(language: String? = nil) {
            self.language = language
        }
    }

    public var version: Int
    public var glossary: [String]?
    public var lexicon: [LexiconEntry]?
    public var speakerBackground: String?
    public var transcriptionPrompt: String?
    public var engine: Engine?
    public var insertion: Insertion?
    public var retention: Retention?
    public var hotkey: Hotkey?
    public var interface: Interface?

    public init(
        version: Int = PersonalProfile.currentVersion,
        glossary: [String]? = nil,
        lexicon: [LexiconEntry]? = nil,
        speakerBackground: String? = nil,
        transcriptionPrompt: String? = nil,
        engine: Engine? = nil,
        insertion: Insertion? = nil,
        retention: Retention? = nil,
        hotkey: Hotkey? = nil,
        interface: Interface? = nil
    ) {
        self.version = version
        self.glossary = glossary
        self.lexicon = lexicon
        self.speakerBackground = speakerBackground
        self.transcriptionPrompt = transcriptionPrompt
        self.engine = engine
        self.insertion = insertion
        self.retention = retention
        self.hotkey = hotkey
        self.interface = interface
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        glossary = try container.decodeIfPresent([String].self, forKey: .glossary)
        lexicon = try container.decodeIfPresent([LexiconEntry].self, forKey: .lexicon)
        speakerBackground = try container.decodeIfPresent(String.self, forKey: .speakerBackground)
        transcriptionPrompt = try container.decodeIfPresent(String.self, forKey: .transcriptionPrompt)
        engine = try container.decodeIfPresent(Engine.self, forKey: .engine)
        insertion = try container.decodeIfPresent(Insertion.self, forKey: .insertion)
        retention = try container.decodeIfPresent(Retention.self, forKey: .retention)
        hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        interface = try container.decodeIfPresent(Interface.self, forKey: .interface)
    }

    // MARK: Encoding

    public static func decode(from data: Data) throws -> PersonalProfile {
        let profile = try JSONDecoder().decode(PersonalProfile.self, from: data)
        guard profile.version <= currentVersion else {
            throw PersonalProfileError.newerVersion(profile.version)
        }
        return profile
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: Lexicon merge

    /// Terms to upsert so the lexicon contains this profile's entries. Merge
    /// only: existing terms keep their state and gain missing aliases, new
    /// canonicals are added, nothing is removed.
    public func lexiconUpserts(into existing: [PersonalTerm]) -> [PersonalTerm] {
        var byKey: [String: PersonalTerm] = [:]
        for term in existing { byKey[Self.key(term.canonical)] = term }
        var changed: [PersonalTerm] = []
        for entry in lexicon ?? [] {
            let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            let key = Self.key(canonical)
            let aliases = Self.uniqueAliases(entry.aliases, excluding: canonical)
            if var term = byKey[key] {
                let have = Set(term.aliases.map(Self.key))
                let missing = aliases.filter { !have.contains(Self.key($0)) }
                guard !missing.isEmpty else { continue }
                term.aliases += missing
                byKey[key] = term
                changed.removeAll { Self.key($0.canonical) == key }
                changed.append(term)
            } else {
                let term = PersonalTerm(canonical: canonical, aliases: aliases, pinned: entry.pinned)
                byKey[key] = term
                changed.append(term)
            }
        }
        return changed
    }

    /// The portable form of a lexicon: confirmed terms only.
    public static func entries(from terms: [PersonalTerm]) -> [LexiconEntry] {
        terms
            .filter { $0.state == .confirmed }
            .map { LexiconEntry(canonical: $0.canonical, aliases: $0.aliases, pinned: $0.pinned) }
    }

    // MARK: Diff

    public struct Change: Equatable, Sendable {
        public let title: String
        public let detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// What importing `incoming` would change, for the confirmation step.
    /// `current` is the profile as it exists now (lexicon included).
    public static func changes(current: PersonalProfile, incoming: PersonalProfile) -> [Change] {
        var result: [Change] = []

        if let glossary = incoming.glossary {
            let have = Set((current.glossary ?? []).map(key))
            let added = glossary.filter { !have.contains(key($0)) }
            let want = Set(glossary.map(key))
            let removed = (current.glossary ?? []).filter { !want.contains(key($0)) }
            if !added.isEmpty || !removed.isEmpty {
                result.append(Change(title: String(localized: "术语表"), detail: String(localized: "新增 \(added.count, format: .number.grouping(.never)) 个，移除 \(removed.count, format: .number.grouping(.never)) 个")))
            }
        }
        if let entries = incoming.lexicon {
            let upserts = PersonalProfile(lexicon: entries).lexiconUpserts(into: lexiconTerms(current))
            if !upserts.isEmpty {
                let existing = Set((current.lexicon ?? []).map { key($0.canonical) })
                let created = upserts.filter { !existing.contains(key($0.canonical)) }.count
                result.append(Change(title: String(localized: "误听别名"), detail: String(localized: "新增 \(created, format: .number.grouping(.never)) 个词，补充 \(upserts.count - created, format: .number.grouping(.never)) 个词的别名")))
            }
        }
        if let value = incoming.speakerBackground, value != (current.speakerBackground ?? "") {
            result.append(Change(title: String(localized: "说话人背景"), detail: value.isEmpty ? String(localized: "清空") : String(localized: "\(value.count, format: .number.grouping(.never)) 字，替换现有内容")))
        }
        if let value = incoming.transcriptionPrompt, value != (current.transcriptionPrompt ?? "") {
            result.append(Change(title: String(localized: "转写提示词"), detail: String(localized: "替换现有内容")))
        }
        if let engine = incoming.engine {
            let now = current.engine ?? Engine()
            appendChange(&result, String(localized: "主引擎"), now.primaryProvider, engine.primaryProvider)
            appendChange(&result, String(localized: "阿里云区域"), now.aliyunRegion, engine.aliyunRegion)
            appendChange(&result, String(localized: "云端异常时用本地模型"), now.automaticLocalFallback, engine.automaticLocalFallback)
        }
        if let insertion = incoming.insertion {
            let now = current.insertion ?? Insertion()
            appendChange(&result, String(localized: "聊天句尾去句号"), now.removeChatTerminalPeriod, insertion.removeChatTerminalPeriod)
            appendChange(&result, String(localized: "英文后补空格"), now.appendTrailingSpaceAfterEnglish, insertion.appendTrailingSpaceAfterEnglish)
        }
        if let retention = incoming.retention {
            let now = current.retention ?? Retention()
            appendChange(&result, String(localized: "录音保留天数"), now.audioRetentionDays, retention.audioRetentionDays)
            appendChange(&result, String(localized: "录音容量上限（MB）"), now.audioQuotaMegabytes, retention.audioQuotaMegabytes)
        }
        if let hotkey = incoming.hotkey {
            appendChange(&result, String(localized: "触发键"), current.hotkey?.trigger, hotkey.trigger)
        }
        if let interface = incoming.interface {
            appendChange(&result, String(localized: "界面语言"), current.interface?.language, interface.language)
        }
        return result
    }

    private static func appendChange<T: Equatable>(_ result: inout [Change], _ title: String, _ now: T?, _ new: T?) {
        guard let new, new != now else { return }
        let before = now.map { "\($0)" } ?? String(localized: "未设置")
        result.append(Change(title: title, detail: "\(before) → \(new)"))
    }

    private static func lexiconTerms(_ profile: PersonalProfile) -> [PersonalTerm] {
        (profile.lexicon ?? []).map { PersonalTerm(canonical: $0.canonical, aliases: $0.aliases, pinned: $0.pinned) }
    }

    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func uniqueAliases(_ aliases: [String], excluding canonical: String) -> [String] {
        var seen: Set<String> = [key(canonical)]
        return aliases.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(key(value)).inserted else { return nil }
            return value
        }
    }
}

public enum PersonalProfileError: LocalizedError, Equatable {
    case newerVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let version):
            return String(localized: "配置文件版本 \(version) 比当前应用支持的版本新，请先更新应用")
        }
    }
}

/// How the terms that follow the personal lexicon in a provider request are
/// assembled: the user's glossary first, then the optional starter pack.
/// One function so the app, the phone app and the tests build the same list.
public enum ContextTermSources {
    public static func builtInTerms(glossary: [String], starterPack: [String]) -> [String] {
        var seen: Set<String> = []
        return (glossary + starterPack).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(PersonalProfile.key(value)).inserted else { return nil }
            return value
        }
    }
}

/// A bundled, optional word list. Shipped as JSON so it can be edited without
/// touching Swift; never enabled unless the user turns it on.
public struct StarterGlossary: Codable, Equatable, Sendable {
    public var version: Int
    public var name: String
    public var terms: [String]

    public static func load(from url: URL?) -> [String] {
        guard let url,
              let data = try? Data(contentsOf: url),
              let pack = try? JSONDecoder().decode(StarterGlossary.self, from: data)
        else { return [] }
        return pack.terms
    }
}


/// The app's interface language setting. macOS picks the UI language from the
/// `AppleLanguages` list in the app's own defaults domain, falling back to the
/// system list when the key is absent; this type maps between the setting and
/// that list. Pure, so it can be tested without touching any defaults.
public enum InterfaceLanguage: String, CaseIterable, Sendable {
    /// No override: the system language order decides.
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// The `AppleLanguages` value to store, or nil to remove the key (follow the system).
    public var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return ["zh-Hans"]
        case .english: return ["en"]
        }
    }

    /// The setting a stored `AppleLanguages` value stands for. The first entry decides, so
    /// a hand-written ["zh-Hans-AU", "en"] reads as Chinese; an unknown language reads as system.
    public init(appleLanguages: [String]?) {
        guard let first = appleLanguages?.first?.lowercased() else { self = .system; return }
        if first.hasPrefix("zh-hans") || first == "zh" || first == "zh_cn" { self = .simplifiedChinese }
        else if first == "en" || first.hasPrefix("en-") || first.hasPrefix("en_") { self = .english }
        else { self = .system }
    }

    /// A profile value; nil for an unknown name (from a newer version), which leaves the setting alone.
    public init?(profileValue: String) {
        self.init(rawValue: profileValue)
    }
}
