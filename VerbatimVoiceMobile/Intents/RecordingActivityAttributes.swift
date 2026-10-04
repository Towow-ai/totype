// ActivityKit is unavailable under Mac Catalyst, so this file is compiled
// out of the Catalyst typecheck. Unverified until an iOS SDK build.
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: SharedSessionPhase
        /// Nil until the first PCM buffer; the timer starts only then.
        var recordingStartedAt: Date?
        /// Engine armed: the keyboard can dictate without opening the app.
        var sessionActive: Bool
        /// Interrupted; resumes when the interruption ends or the app opens.
        var sessionPaused: Bool
        /// When an idle session ends by itself; nil while recording or when
        /// it only ends manually.
        var sessionEndsAt: Date?
        /// Idle timeout in minutes for the "空闲 N 分钟后自动结束" note;
        /// nil when unknown (older payloads) or manual.
        var idleMinutes: Int? = nil
    }

    var sessionID: UUID
}
#endif
