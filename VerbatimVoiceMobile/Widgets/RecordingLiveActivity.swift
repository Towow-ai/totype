// ActivityKit is unavailable under Mac Catalyst: this file is compiled out
// of scripts/typecheck.sh.
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island (DESIGN.md §7.5). Status only, never
/// transcript text. Faces live in `Design/LiveActivityFaces.swift` so the
/// app's design preview renders the same views.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            let state = Self.state(context.state)
            LockScreenActivityFace(state: state) { ActivityButtons(state: state, island: false) }
                .activityBackgroundTint(VVActivity.cardBackground)
                .activitySystemActionForegroundColor(VVColor.fgPrimary)
        } dynamicIsland: { context in
            let state = Self.state(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedTitle(state: state)
                        .frame(height: 28)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTimer(state: state)
                        .frame(height: 28)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBody(state: state) { ActivityButtons(state: state, island: true) }
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                ActivityGlyph(state: state, micSize: 13)
                    .padding(.leading, 2)
                    .environment(\.colorScheme, .dark)
            } compactTrailing: {
                ActivityTimer(state: state)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(state.recording ? 1 : 0.92))
                    .frame(maxWidth: 48)
            } minimal: {
                ActivityGlyph(state: state, micSize: 13)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    static func state(_ s: RecordingActivityAttributes.ContentState) -> VVActivityState {
        VVActivityState(
            phase: s.phase,
            recordingStartedAt: s.recordingStartedAt,
            sessionActive: s.sessionActive,
            sessionPaused: s.sessionPaused,
            sessionEndsAt: s.sessionEndsAt,
            idleMinutes: s.idleMinutes
        )
    }
}

/// Starting / listening: 取消 + 完成. Recognising: none (nothing to do).
/// No idle-session face: the activity ends with the dictation.
private struct ActivityButtons: View {
    let state: VVActivityState
    let island: Bool

    var body: some View {
        switch state.phase {
        case .recording, .starting:
            Button(intent: CancelRecordingIntent()) { ActivityButtonFace(kind: .cancel, island: island) }
                .buttonStyle(.plain)
            Button(intent: StopRecordingIntent()) { ActivityButtonFace(kind: .finish, island: island) }
                .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }
}
#endif
