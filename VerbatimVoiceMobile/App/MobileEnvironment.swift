import Foundation
import Security

/// iOS credential store. The macOS `KeychainStore.swift` is not reused
/// because its file also contains `PersonalSecretStore`, which depends on
/// `homeDirectoryForCurrentUser` (unavailable on iOS).
///
/// No explicit access group is passed: items land in the first entry of the
/// `keychain-access-groups` entitlement, which project.yml sets to the group
/// shared by all three targets.
struct MobileKeychain: Sendable {
    enum Account: String, Sendable {
        case soniox = "soniox-api-key"
        case aliyun = "aliyun-api-key"
    }

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串操作失败（\(message)，状态码 \(status)）"
            }
        }
    }

    /// The main app's bundle ID (unchanged since the first release, so saved
    /// keys stay readable).
    private let service = MobileIdentity.appBundleID

    /// Saving an empty value deletes the item.
    func set(_ value: String, for account: Account) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(account)
            return
        }
        let query = baseQuery(account)
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unhandled(status) }
        var item = query
        item[kSecValueData as String] = data
        // Readable after first unlock so a Control Center or Action Button
        // start works while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
    }

    func get(_ account: Account) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = result as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func contains(_ account: Account) -> Bool {
        (try? get(account)) != nil
    }

    func delete(_ account: Account) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
    }
}

enum MobileEnvironment {
    static let keychain = MobileKeychain()

    /// Mailbox, session state and the personal lexicon live in the App Group.
    /// History and audio stay in the app's own container (`HistoryStore`).
    static var sharedDirectory: URL {
        if let directory = AppGroup.sharedDirectory() { return directory }
        // Unsigned or misconfigured build: keep working inside the app
        // container; the keyboard simply will not see the mailbox.
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerbatimShared-fallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static let mailbox = Mailbox(directory: sharedDirectory)
    static let sessionState = SharedSessionStateStore(directory: sharedDirectory)
    static let keyboardRequests = KeyboardRequestStore(directory: sharedDirectory)
    static let levels = SharedLevelStore(directory: sharedDirectory)
    static let lexiconStore = PersonalLexiconStore(baseDirectory: sharedDirectory)

    static let sonioxProviderID = "soniox"
    static let aliyunProviderID = "aliyun-qwen-audio-asr"
    /// Apple on-device recognition: the engine when no cloud key is saved.
    static let localProviderID = OnDeviceSpeechProvider.providerID

    static var hasCloudKey: Bool { keychain.contains(.soniox) || keychain.contains(.aliyun) }

    static func makeLocalProvider(terms: [PersonalTerm] = []) -> OnDeviceSpeechProvider {
        OnDeviceSpeechProvider(terms: terms.map(\.canonical))
    }

    static func makeSonioxProvider() -> SonioxProvider {
        SonioxProvider(
            apiKeyProvider: {
                guard let key = try MobileKeychain().get(.soniox) else {
                    throw ASRProviderError.missingAPIKey("Soniox")
                }
                return key
            },
            // Session-owned socket, same as macOS: never returned to a warm pool.
            warmTTLProvider: { 0 }
        )
    }

    static func makeAliyunProvider() -> AliyunASRProvider {
        AliyunASRProvider(
            apiKeyProvider: {
                guard let key = try MobileKeychain().get(.aliyun) else {
                    throw ASRProviderError.missingAPIKey("阿里云百炼")
                }
                return key
            },
            regionProvider: {
                AliyunRegion(rawValue: UserDefaults.standard.string(forKey: "aliyunRegion") ?? "") ?? .beijing
            }
        )
    }

    static func makeProvider(id: String) -> (any ASRProvider)? {
        switch id {
        case sonioxProviderID: return makeSonioxProvider()
        case aliyunProviderID: return makeAliyunProvider()
        case localProviderID: return makeLocalProvider()
        default: return nil
        }
    }

    static func displayName(providerID: String?) -> String {
        switch providerID {
        case sonioxProviderID: return "Soniox"
        case aliyunProviderID: return "百炼"
        case localProviderID: return "本机识别"
        default: return providerID ?? "—"
        }
    }

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
