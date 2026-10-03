import Foundation

/// Names that differ between builds of the same source: set by scripts/build.sh
/// (or the Xcode project through config/*.xcconfig) and read from the bundle at
/// run time. Nothing else in the app spells out a bundle ID, data folder or
/// product name.
enum AppIdentity {
    /// Outside an app bundle (tests, probes) the same variables scripts/lib/env.sh
    /// exports (VERBATIM_BUNDLE_ID, VERBATIM_DATA_DIR_NAME) stand in for the
    /// Info.plist, so a probe built from a local config sees the app's identity.
    static let fallbackBundleID = "ai.towow.totype"
    static let fallbackDataDirectoryName = "VerbatimVoice"
    static let fallbackDisplayName = "Totype"

    static let bundleID: String = nonEmpty(Bundle.main.bundleIdentifier)
        ?? nonEmpty(environment["VERBATIM_BUNDLE_ID"])
        ?? fallbackBundleID

    /// Folder under ~/Library/Application Support that holds history, audio,
    /// lexicon, models and the handshake files. Info.plist key `VVDataDirectoryName`.
    static let dataDirectoryName: String = {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "VVDataDirectoryName") as? String)
            ?? (Bundle.main.bundleIdentifier == nil ? nonEmpty(environment["VERBATIM_DATA_DIR_NAME"]) : nil)
            ?? fallbackDataDirectoryName
    }()

    /// Name shown to the user (localized when the bundle ships InfoPlist.strings).
    static let displayName: String = {
        let info = Bundle.main
        let display = info.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let name = info.object(forInfoDictionaryKey: "CFBundleName") as? String
        return nonEmpty(display) ?? nonEmpty(name) ?? fallbackDisplayName
    }()

    static let version: String = {
        nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }()

    /// ASCII-only, so it is safe in an HTTP header whatever the display name is.
    static var userAgent: String { "\(dataDirectoryName)/\(version)" }

    /// Starting value of "observe manual edits after insertion" for a user who has
    /// never touched the setting. Info.plist key `VVLearnFromEditsDefault` ("1"/"0");
    /// without the key (iOS, probes) the setting starts on, as it always did.
    static let learnFromEditsDefault: Bool = {
        switch Bundle.main.object(forInfoDictionaryKey: "VVLearnFromEditsDefault") {
        case let flag as Bool: return flag
        case let text as String:
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if ["0", "no", "false"].contains(value) { return false }
            return true
        default: return true
        }
    }()

    /// ~/Library/Application Support/<dataDirectoryName>
    static func dataDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
