import AppKit

/// Keep the console reachable when the menu bar item is hidden or out of space.
@MainActor
final class AppReopenDelegate: NSObject, NSApplicationDelegate {
    static let reopenRequested = Notification.Name("TotypeReopenRequested")

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // A minimized window also counts as visible here. Always let the existing
        // model reveal its console, without creating another dictation session.
        NotificationCenter.default.post(name: Self.reopenRequested, object: nil)
        return false
    }
}
