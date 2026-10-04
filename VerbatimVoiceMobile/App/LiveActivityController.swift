import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

/// Lock Screen / Dynamic Island status for one dictation: it starts when a
/// dictation starts and ends when the dictation is back to idle. The idle
/// session shows nothing there (no standby countdown);
/// its time left is only on the home session row. Recording through
/// AudioRecordingIntent requires a live activity, which this satisfies.
/// iOS refuses to start one while the app is in the background (a
/// keyboard-started dictation: `ActivityAuthorization` "visibility"). That
/// is expected, not worked around: the keyboard shows the recording state
/// itself. The refusal is logged once per process and kind, later ones are
/// only counted, and recording goes on.
/// Under Mac Catalyst this is a no-op (ActivityKit is unavailable there).
@MainActor
final class LiveActivityController {
    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var activity: Activity<RecordingActivityAttributes>?
    /// Last refusal logged, and how many identical ones were not.
    private var lastRefusal: String?
    private var unloggedRefusals = 0

    /// Starts an activity unless this process already has one.
    func ensureStarted() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endAll()
        let state = RecordingActivityAttributes.ContentState(
            phase: .starting,
            recordingStartedAt: nil,
            sessionActive: false,
            sessionPaused: false,
            sessionEndsAt: nil
        )
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(sessionID: UUID()),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            SessionDiagnostics.log("liveActivity.start", "appState=\(DictationController.appStateName())")
        } catch {
            let appState = DictationController.appStateName()
            let kind = "\(appState) \(AudioCapture.describe(error))"
            guard kind != lastRefusal else {
                unloggedRefusals += 1
                return
            }
            let repeats = unloggedRefusals
            lastRefusal = kind
            unloggedRefusals = 0
            // Expected for a dictation started from the keyboard while the
            // app is in the background; logged once, not per dictation.
            SessionDiagnostics.log(
                "liveActivity.unavailable",
                "appState=\(appState) error=\(AudioCapture.describe(error)) previousRepeats=\(repeats)\(appState == "background" ? " expected=backgroundStart" : "")"
            )
        }
    }

    func update(
        phase: SharedSessionPhase,
        recordingStartedAt: Date?,
        sessionActive: Bool,
        sessionPaused: Bool,
        sessionEndsAt: Date?
    ) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            phase: phase,
            recordingStartedAt: recordingStartedAt,
            sessionActive: sessionActive,
            sessionPaused: sessionPaused,
            sessionEndsAt: sessionEndsAt,
            idleMinutes: Self.idleMinutes
        )
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Detaches the activity at once, so a dictation started right after
    /// gets a fresh one instead of the one being ended.
    func end() {
        guard let activity else { return }
        self.activity = nil
        SessionDiagnostics.log("liveActivity.end")
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Read from the stored setting rather than passed in, so the dictation
    /// controller's calls stay as they are.
    private static var idleMinutes: Int? {
        let stored = UserDefaults.standard.object(forKey: SessionIdleTimeout.storageKey) as? Int
        let timeout = stored.flatMap(SessionIdleTimeout.init(rawValue:)) ?? .default
        return timeout.seconds.map { Int($0 / 60) }
    }

    func endAndWait() async {
        guard let activity else { return }
        self.activity = nil
        SessionDiagnostics.log("liveActivity.end")
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    /// Ends activities left over from a previous process (crash, kill).
    func endAll() {
        activity = nil
        for leftover in Activity<RecordingActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }
    #else
    func ensureStarted() {}
    func update(
        phase: SharedSessionPhase,
        recordingStartedAt: Date?,
        sessionActive: Bool,
        sessionPaused: Bool,
        sessionEndsAt: Date?
    ) {}
    func end() {}
    func endAndWait() async {}
    func endAll() {}
    #endif
}
