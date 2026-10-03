import Foundation

@main
struct PersonalSecretStoreTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerbatimVoiceSecretStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PersonalSecretStore(baseDirectory: root)
        try expect(!store.contains(account: "soniox-api-key"), "new store must be empty")

        try store.set("first-secret", account: "soniox-api-key")
        try store.set("second-secret", account: "aliyun-bailian-api-key")
        try expect(store.get(account: "soniox-api-key") == "first-secret", "Soniox round trip")
        try expect(store.get(account: "aliyun-bailian-api-key") == "second-secret", "Aliyun round trip")

        let reloaded = PersonalSecretStore(baseDirectory: root)
        try expect(reloaded.get(account: "soniox-api-key") == "first-secret", "disk reload")

        let file = root.appendingPathComponent("personal-secrets.json")
        let directoryMode = try mode(at: root)
        let fileMode = try mode(at: file)
        try expect(directoryMode == 0o700, "directory mode expected 0700, got \(String(directoryMode, radix: 8))")
        try expect(fileMode == 0o600, "file mode expected 0600, got \(String(fileMode, radix: 8))")

        try store.delete(account: "soniox-api-key")
        try expect(!store.contains(account: "soniox-api-key"), "delete")
        try expect(store.contains(account: "aliyun-bailian-api-key"), "delete must preserve other accounts")

        print("personal secret store checks passed")
    }

    private static func mode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else {
            throw TestFailure(message: "missing permissions for \(url.path)")
        }
        return number.intValue & 0o777
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure(message: message) }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
