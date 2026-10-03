import Carbon
import Foundation

struct SecureInputMonitor {
    static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
