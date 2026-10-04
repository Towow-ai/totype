import Foundation

// Portable profile and context-term wiring. Kept out of AppSettings.swift so the
// standalone tool builds that compile only that file do not need VerbatimCore.
@MainActor
extension AppSettings {
    /// Terms sent after the personal lexicon: the user's glossary, then the
    /// starter pack when it is switched on.
    var contextBuiltInTerms: [String] {
        ContextTermSources.builtInTerms(
            glossary: glossaryTerms,
            starterPack: starterGlossaryEnabled ? Self.starterGlossaryTerms : []
        )
    }

    /// The bundled starter pack. Empty when the resource is not part of the
    /// build (the phone app and plain `swiftc` builds do not copy it).
    static var starterGlossaryTerms: [String] {
        StarterGlossary.load(from: Bundle.main.url(forResource: "starter-glossary-developer", withExtension: "json"))
    }

    // MARK: Personal profile

    /// Current settings as a portable profile (no keys, history or audio).
    func makeProfile(lexicon: [PersonalTerm]) -> PersonalProfile {
        PersonalProfile(
            glossary: glossaryTerms,
            lexicon: PersonalProfile.entries(from: lexicon),
            speakerBackground: speakerBackground,
            transcriptionPrompt: transcriptionPrompt,
            engine: .init(
                primaryProvider: primaryProvider.rawValue,
                aliyunRegion: aliyunRegion.rawValue,
                languageHints: ["zh", "en"],
                automaticLocalFallback: automaticLocalFallback
            ),
            insertion: .init(
                removeChatTerminalPeriod: removeChatTerminalPeriod,
                appendTrailingSpaceAfterEnglish: appendTrailingSpaceAfterEnglish
            ),
            retention: .init(audioRetentionDays: audioRetentionDays, audioQuotaMegabytes: audioQuotaMegabytes),
            hotkey: .init(trigger: triggerKey.rawValue),
            interface: .init(language: interfaceLanguage.rawValue)
        )
    }

    /// Applies the settings part of a profile; only present fields change.
    /// The lexicon part is merged by the caller, which owns the lexicon store.
    func apply(_ profile: PersonalProfile) {
        if let glossary = profile.glossary { glossaryText = glossary.joined(separator: "\n") }
        if let value = profile.speakerBackground { speakerBackground = value }
        if let value = profile.transcriptionPrompt { transcriptionPrompt = value }
        if let engine = profile.engine {
            if let raw = engine.primaryProvider, let value = PrimaryTranscriptionProvider(rawValue: raw) { primaryProvider = value }
            if let raw = engine.aliyunRegion, let value = AliyunRegion(rawValue: raw) { aliyunRegion = value }
            if let value = engine.automaticLocalFallback { automaticLocalFallback = value }
        }
        if let insertion = profile.insertion {
            if let value = insertion.removeChatTerminalPeriod { removeChatTerminalPeriod = value }
            if let value = insertion.appendTrailingSpaceAfterEnglish { appendTrailingSpaceAfterEnglish = value }
        }
        if let retention = profile.retention {
            if let value = retention.audioRetentionDays { audioRetentionDays = max(0, value) }
            if let value = retention.audioQuotaMegabytes { audioQuotaMegabytes = max(0, value) }
        }
        // An unknown key name (from a newer version) leaves the current key alone.
        if let raw = profile.hotkey?.trigger, let value = TriggerKey(rawValue: raw) { triggerKey = value }
        if let raw = profile.interface?.language, let value = InterfaceLanguage(profileValue: raw) { interfaceLanguage = value }
    }

    // MARK: Interface language

    /// The language setting stored in this app's own defaults domain (not the merged
    /// view, which would also show the system list). Takes effect on the next launch.
    var interfaceLanguage: InterfaceLanguage {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            return InterfaceLanguage(appleLanguages: domain?["AppleLanguages"] as? [String])
        }
        set {
            if let languages = newValue.appleLanguages {
                UserDefaults.standard.set(languages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            UserDefaults.standard.synchronize() // a restart may follow at once
        }
    }

    /// What this process started with; a different `interfaceLanguage` needs a restart.
    static let launchInterfaceLanguage: InterfaceLanguage = {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return InterfaceLanguage(appleLanguages: domain?["AppleLanguages"] as? [String])
    }()
}
