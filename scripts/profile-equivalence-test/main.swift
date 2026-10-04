import Foundation

/// Offline check that moving personal content out of the code changed nothing
/// for the person it was written for, and leaks nothing to anyone else.
///
/// Reads, from `VERBATIM_PRIVATE_DIR` (default `../private` next to the checkout,
/// set by scripts/profile_equivalence_test.sh):
///   golden/before-requests.json   request JSON captured before the change
///   golden/lexicon-snapshot.jsonl lexicon those requests were built from
///   owner-profile.json           the owner's exported profile
///   oss-scan-patterns.txt         one regex per line, words that must not ship
/// Missing files skip the corresponding check with a message. No network, no keys.
@main
enum ProfileEquivalenceTest {
    @MainActor static func main() async throws {
        let privateDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VERBATIM_PRIVATE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/../private")
        let patterns = loadPatterns(privateDir.appendingPathComponent("oss-scan-patterns.txt"))

        try await testEmptyProfile(patterns: patterns)
        try await testOwnerEquivalence(privateDir: privateDir)
        print("profile equivalence test passed")
    }

    // MARK: Empty profile

    @MainActor static func testEmptyProfile(patterns: [NSRegularExpression]?) async throws {
        let settings = freshSettings()
        let requests = try await build(settings: settings, lexicon: [])
        for (name, json) in requests {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            try check(object != nil, "\(name) 请求不是 JSON 对象")
            if let patterns {
                for pattern in patterns {
                    let range = NSRange(json.startIndex..., in: json)
                    try check(pattern.firstMatch(in: json, range: range) == nil,
                              "空 profile 的 \(name) 请求命中黑名单：\(pattern.pattern)")
                }
            }
        }
        let soniox = try require(try JSONSerialization.jsonObject(with: Data(requests["soniox"]!.utf8)) as? [String: Any])
        let context = try require(soniox["context"] as? [String: Any])
        let text = try require(context["text"] as? String)
        try check(!text.hasPrefix("\n"), "背景为空时 context.text 不应有前缀")
        try check(text == settings.transcriptionPrompt, "背景为空时 context.text 应只有转写提示词")
        try check((context["terms"] as? [String])?.isEmpty == true, "空 profile 不应发送任何术语")
        print(patterns == nil
            ? "skip blacklist scan: oss-scan-patterns.txt not found"
            : "ok  empty profile: no blacklisted word in Soniox/Aliyun requests, no context prefix")
    }

    // MARK: Owner equivalence

    @MainActor static func testOwnerEquivalence(privateDir: URL) async throws {
        let golden = privateDir.appendingPathComponent("golden/before-requests.json")
        let lexiconURL = privateDir.appendingPathComponent("golden/lexicon-snapshot.jsonl")
        let profileURL = privateDir.appendingPathComponent("owner-profile.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: golden.path), fm.fileExists(atPath: lexiconURL.path), fm.fileExists(atPath: profileURL.path) else {
            print("skip owner equivalence: golden files or profile not found in \(privateDir.path)")
            return
        }
        let before = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: String])
        let profile = try PersonalProfile.decode(from: Data(contentsOf: profileURL))

        let scratch = fm.temporaryDirectory.appendingPathComponent("profile-equivalence-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.copyItem(at: lexiconURL, to: scratch.appendingPathComponent("personal-lexicon-v1.jsonl"))
        var lexicon = try await PersonalLexiconStore(baseDirectory: scratch).load()
        // Importing the profile's lexicon part must be a no-op for an
        // existing lexicon that already holds those aliases.
        let upserts = profile.lexiconUpserts(into: lexicon)
        try check(upserts.isEmpty, "profile 的别名应已全部在词库中，实际需补 \(upserts.map(\.canonical))")
        lexicon += upserts

        let settings = freshSettings()
        settings.apply(profile)
        let after = try await build(settings: settings, lexicon: lexicon)
        for name in ["soniox", "aliyun"] {
            let expected = try require(before[name])
            let actual = try require(after[name])
            try check(Data(expected.utf8) == Data(actual.utf8), "\(name) 请求与改动前不一致\n前：\(expected)\n后：\(actual)")
        }
        print("ok  owner profile: Soniox and Aliyun start requests are byte-identical to the pre-change capture")
    }

    // MARK: Helpers

    @MainActor static func freshSettings() -> AppSettings {
        let suite = "profile-equivalence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// Mirrors AppModel.compileProviderContexts: the same compiler, the same
    /// term sources. Keys are sorted so process-random dictionary order does
    /// not matter; both providers serialize unsorted dictionaries.
    @MainActor static func build(settings: AppSettings, lexicon: [PersonalTerm]) async throws -> [String: String] {
        let personal = lexicon.isEmpty
            ? settings.glossaryTerms.map { PersonalTerm(canonical: $0, pinned: true) }
            : lexicon
        var result: [String: String] = [:]
        for (name, providerID) in [("soniox", "soniox"), ("aliyun", "aliyun-qwen-audio-asr")] {
            let context = ProviderContextCompiler.compile(
                sessionID: UUID(),
                providerID: providerID,
                personalTerms: personal,
                builtInTerms: settings.contextBuiltInTerms,
                targetBundleIdentifier: nil,
                prompt: settings.transcriptionPrompt,
                hotwordWeight: settings.hotwordWeight,
                speakerBackground: settings.speakerBackground,
                referenceDate: Date(timeIntervalSince1970: 1_790_000_000)
            ).context
            let json = name == "soniox"
                ? try SonioxProvider.configurationJSONForTesting(context: context)
                : try AliyunRealtimeProtocol.runTaskJSON(
                    taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, context: context)
            result[name] = try canonical(json)
        }
        return result
    }

    static func canonical(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func loadPatterns(_ url: URL) -> [NSRegularExpression]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { try? NSRegularExpression(pattern: $0) }
    }

    static func require<T>(_ value: T?, _ message: String = "缺少必需的值") throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }
}

private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
