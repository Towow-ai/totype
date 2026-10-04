import Foundation

/// Darwin notifications carry no data: they only say "look again". The
/// mailbox and session-state files stay the source of truth, and a receiver
/// must also re-read them when it becomes visible, because a suspended
/// process misses notifications.
enum DarwinNotification: String, CaseIterable, Sendable {
    case mailboxChanged = "mailbox-changed"
    case sessionChanged = "session-changed"
    /// The keyboard wrote `keyboard-request.json` (start/stop/cancel while a
    /// session is alive).
    case keyboardRequest = "keyboard-request"

    /// System-wide name: `<app bundle ID>.<raw value>`.
    var name: String { MobileIdentity.label(rawValue) }

    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }
}

enum DarwinNotifier {
    static func post(_ notification: DarwinNotification) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification.name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Observes Darwin notifications for as long as the instance is alive.
/// The handler is always invoked on the main queue.
final class DarwinObserver {
    private let handler: (DarwinNotification) -> Void

    init(_ notifications: [DarwinNotification], handler: @escaping (DarwinNotification) -> Void) {
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let raw = name?.rawValue as String?,
                          let notification = DarwinNotification(name: raw) else { return }
                    let instance = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                    instance.deliver(notification)
                },
                notification.name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func deliver(_ notification: DarwinNotification) {
        if Thread.isMainThread {
            handler(notification)
        } else {
            DispatchQueue.main.async { [handler] in handler(notification) }
        }
    }
}
