import Foundation

/// Names that differ between builds of the same source: set in
/// Config/Shared.xcconfig (overridden by Config/Local.xcconfig) and written
/// into each target's Info.plist by project.yml. The app, keyboard and widgets
/// all carry the same values, so they agree on the App Group, the URL scheme
/// and the notification names. Nothing else in the iOS code spells them out.
enum MobileIdentity {
    /// Public defaults, also used outside an app bundle (scripts/shared-self-test).
    static let fallbackAppBundleID = "ai.towow.totype"
    static let fallbackAppGroup = "group.ai.towow.totype"
    static let fallbackURLScheme = "totype"
    static let fallbackDisplayName = "Totype"

    /// The main app's bundle ID, also in the keyboard and widgets (whose own
    /// bundle IDs add a suffix). Prefix of every queue label, log subsystem,
    /// Darwin notification and control kind; the keychain service name.
    static let appBundleID = value("TotypeAppBundleID", fallback: fallbackAppBundleID)
    static let appGroup = value("TotypeAppGroup", fallback: fallbackAppGroup)
    /// Scheme of the URLs the keyboard opens the app with (`<scheme>://record`).
    static let urlScheme = value("TotypeURLScheme", fallback: fallbackURLScheme)
    /// Home screen name; the keyboard's own Info.plist carries the same one.
    static let displayName = value("CFBundleDisplayName", fallback: fallbackDisplayName)

    /// `<appBundleID>.<suffix>`, for queue labels and log subsystems.
    static func label(_ suffix: String) -> String { "\(appBundleID).\(suffix)" }

    private static func value(_ key: String, fallback: String) -> String {
        if let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return text
        }
        // Inside an app bundle a missing key is a project.yml mistake: the
        // fallback would silently point at another App Group and keychain.
        assert(Bundle.main.bundleIdentifier == nil, "Info.plist is missing \(key)")
        return fallback
    }
}
