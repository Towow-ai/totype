import Foundation

/// Personal terms, stored with the macOS `PersonalLexiconStore` format
/// (`personal-lexicon-v1.jsonl`) inside the App Group. Only canonical terms
/// are sent to the engines; aliases are kept for later misrecognition
/// restore and never sent.
@MainActor
final class LexiconModel: ObservableObject {
    @Published private(set) var terms: [PersonalTerm] = []
    @Published var status: String?

    private let store = MobileEnvironment.lexiconStore

    func reload() async {
        do {
            var loaded = try await store.load()
            if loaded.isEmpty, let seeded = try await importBundledSeed() {
                loaded = seeded
                status = "已从 Mac 词库导入 \(seeded.filter { $0.state == .confirmed }.count) 个词"
            }
            if let merged = try await importBundledProfileIfNeeded(into: loaded) {
                loaded = merged
            }
            apply(loaded)
        } catch {
            status = "词库读取失败：\(error.localizedDescription)"
        }
    }

    func add(_ raw: String) async {
        let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        if let existing = terms.first(where: { $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame }) {
            guard existing.state != .confirmed || !existing.pinned else {
                status = "“\(existing.canonical)”已在词库中"
                return
            }
            var updated = existing
            updated.state = .confirmed
            updated.pinned = true
            await upsert(updated, message: "已重新启用“\(existing.canonical)”")
            return
        }
        await upsert(PersonalTerm(canonical: canonical, pinned: true), message: "已加入“\(canonical)”，下次录音生效")
    }

    func delete(_ term: PersonalTerm) async {
        do {
            apply(try await store.delete(termID: term.id))
            status = "已删除“\(term.canonical)”"
        } catch {
            status = "删除失败：\(error.localizedDescription)"
        }
    }

    private func upsert(_ term: PersonalTerm, message: String) async {
        do {
            apply(try await store.upsert(term))
            status = message
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }

    /// `scripts/prepare-seed.sh` copies a lexicon (VERBATIM_LEXICON_SEED) into the bundle at
    /// build time. It is read through a throwaway store so the event log is
    /// replayed exactly as on the Mac.
    private func importBundledSeed() async throws -> [PersonalTerm]? {
        guard let seedURL = Bundle.main.url(forResource: "personal-lexicon-seed", withExtension: "jsonl", subdirectory: "Seed")
        else { return nil }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexicon-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.copyItem(at: seedURL, to: scratch.appendingPathComponent("personal-lexicon-v1.jsonl"))
        let seedTerms = try await PersonalLexiconStore(baseDirectory: scratch).load()
        guard !seedTerms.isEmpty else { return nil }
        return try await store.seedIfMissing(seedTerms)
    }

    /// `scripts/prepare-seed.sh` copies a personal profile into the bundle when
    /// one exists. Only what identifies the speaker is taken from it (speaker
    /// background, glossary, aliases); the phone keeps its own prompt, engine,
    /// insertion and retention settings. Applied once per install, whatever
    /// state the lexicon is in; the lexicon part is merged, never pruned.
    private static let profileSeedKey = "bundledProfileSeedImportedV1"

    private func importBundledProfileIfNeeded(into current: [PersonalTerm]) async throws -> [PersonalTerm]? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.profileSeedKey),
              let url = Bundle.main.url(forResource: "personal-profile-seed", withExtension: "json", subdirectory: "Seed")
        else { return nil }
        let full = try PersonalProfile.decode(from: Data(contentsOf: url))
        let profile = PersonalProfile(glossary: full.glossary, lexicon: full.lexicon, speakerBackground: full.speakerBackground)
        DictationController.shared.settings.apply(profile)
        var merged = current
        for term in profile.lexiconUpserts(into: current) {
            merged = try await store.upsert(term)
        }
        defaults.set(true, forKey: Self.profileSeedKey)
        status = "已导入个人资料"
        return merged
    }

    private func apply(_ loaded: [PersonalTerm]) {
        terms = loaded.filter { $0.state == .confirmed }
        DictationController.shared.personalTerms = loaded
    }
}
