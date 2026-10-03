import Foundation
import Security

struct KeychainStore: Sendable {
    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case let .unhandled(status):
                let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "无法读取系统钥匙串（\(systemMessage)，状态码 \(status)）"
            case .invalidData:
                return "系统钥匙串中的 API Key 数据无法识别"
            }
        }
    }

    private let service = AppIdentity.bundleID

    func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return string
    }

    /// Checks whether a credential item exists without requesting its secret
    /// data.  Keychain can temporarily refuse a data read while the app is
    /// launching or while an access prompt is being resolved; that must not be
    /// misreported to the user as "API Key not configured".
    func contains(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        return true
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

/// A deliberately personal, single-user credential store.
///
/// The locally signed development app receives a new code hash after every
/// rebuild. macOS Keychain therefore asks for access again even when the user
/// previously chose "Always Allow". Personal mode keeps cloud credentials in
/// the user's Application Support directory instead, with owner-only Unix
/// permissions, and caches them in memory for the lifetime of the process.
/// It is intended for this user's own Mac, not for a distributed multi-user
/// build.
final class PersonalSecretStore: @unchecked Sendable {
    enum StoreError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "个人模式密钥文件无法读取；请在设置中重新保存 API Key"
            }
        }
    }

    private struct Payload: Codable {
        let version: Int
        var values: [String: String]
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private var cachedValues: [String: String]?

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let defaultRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        directoryURL = baseDirectory
            ?? AppIdentity.dataDirectory(in: defaultRoot)
        fileURL = directoryURL.appendingPathComponent("personal-secrets.json", isDirectory: false)
    }

    func set(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try loadLocked()
        values[account] = value
        try persistLocked(values)
        cachedValues = values
    }

    func get(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()[account]
    }

    func contains(account: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()[account] != nil
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var values = try loadLocked()
        values.removeValue(forKey: account)
        try persistLocked(values)
        cachedValues = values
    }

    private func loadLocked() throws -> [String: String] {
        if let cachedValues { return cachedValues }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedValues = [:]
            return [:]
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == 1 else { throw StoreError.unreadable }
            cachedValues = payload.values
            return payload.values
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable
        }
    }

    private func persistLocked(_ values: [String: String]) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let data = try JSONEncoder().encode(Payload(version: 1, values: values))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(resourceValues)
    }
}
