import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Plain values a Live Activity face needs (mirrors
/// `RecordingActivityAttributes.ContentState`, which is ActivityKit-only).
struct VVActivityState: Equatable {
    var phase: SharedSessionPhase
    var recordingStartedAt: Date?
    var sessionActive: Bool
    var sessionPaused: Bool
    var sessionEndsAt: Date?
    var idleMinutes: Int?
    /// Preview only: fixed timer text.
    var fixedTimer: String?

    var recording: Bool { phase == .recording }
}

/// Status and buttons for the Lock Screen and the Dynamic Island
/// (DESIGN.md §7.5, §13). Status only, never transcript text. An activity
/// exists only while a dictation is starting, listening or recognising; the
/// idle session never shows here (no standby countdown). The waveform is a
/// fixed shape: an activity cannot receive 15 Hz levels, so it marks
/// "capturing", not the live level.
enum VVActivity {
    static func title(_ s: VVActivityState) -> String {
        switch s.phase {
        case .recording: return "正在听"
        case .starting: return "启动中"
        case .finalizing: return "识别中"
        case .idle: return "已结束"
        }
    }

    static let waveLevels = VVSampleLevels.make(56, seed: 11)

    /// Lock Screen card background (dark: #1C1D1E as in the mockup).
    static var cardBackground: Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 28 / 255, green: 29 / 255, blue: 30 / 255, alpha: 1)
            : UIColor.white })
        #else
        VVColor.bgCanvas
        #endif
    }
}

/// Red dot while recording, the mic outline otherwise.
struct ActivityGlyph: View {
    let state: VVActivityState
    var micSize: CGFloat = 13
    var color: Color = .white

    var body: some View {
        if state.recording {
            Circle().fill(VVColor.stateRecording).frame(width: 10, height: 10)
        } else {
            Image(systemName: "mic")
                .font(.system(size: micSize, weight: .semibold))
                .foregroundStyle(color)
                .opacity(state.phase == .idle && !state.sessionActive && !state.sessionPaused ? 0.5 : 1)
        }
    }
}

/// System-driven timer text (`Text(timerInterval:)`, no per-second pushes).
struct ActivityTimer: View {
    let state: VVActivityState

    var body: some View {
        if let fixed = state.fixedTimer {
            Text(fixed).monospacedDigit()
        } else if state.recording, let start = state.recordingStartedAt {
            Text(timerInterval: start...Date.distantFuture, countsDown: false).monospacedDigit()
        } else if state.phase == .finalizing {
            Text("…")
        } else {
            Text(" ")
        }
    }
}

/// Button face used inside intent buttons: 15 Semibold, full width, words
/// only. Here the capsule is not a target (tapping the activity opens the
/// app), so "完成" needs its own button; it is the filled one (filled =
/// commit, DESIGN.md §13).
struct ActivityButtonFace: View {
    enum Kind { case cancel, finish }
    let kind: Kind
    /// Island buttons are 38 high on black; Lock Screen buttons 34.
    var island = false

    var body: some View {
        Text(kind == .finish ? "完成" : "取消")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: island ? 38 : 34)
        .background(Capsule().fill(background))
    }

    private var main: Bool { kind == .finish }
    private var foreground: Color {
        if island { return main ? .black : .white }
        return main ? VVColor.fgInverse : VVColor.fgPrimary
    }
    private var background: Color {
        if island { return main ? .white : .white.opacity(0.14) }
        return main ? VVColor.fillKeyProminent : VVColor.fgPrimary.opacity(0.14)
    }
}

/// Lock Screen face: 14 margins; icon + name + state, timer + waveform (or
/// the session note), buttons.
struct LockScreenActivityFace<Buttons: View>: View {
    let state: VVActivityState
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                VVQuoteMark()
                    .fill(VVColor.bgCanvas)
                    .frame(width: 18, height: 18)
                    .offset(y: 2)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(VVColor.fgPrimary))
                Text(MobileIdentity.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    ActivityGlyph(state: state, micSize: 13, color: VVColor.fgPrimary)
                    Text(VVActivity.title(state))
                }
                .font(.system(size: 15, weight: .medium))
            }
            HStack(alignment: .center, spacing: 12) {
                ActivityTimer(state: state)
                    .font(.system(size: 34, weight: .medium))
                    .lineLimit(1)
                    .frame(height: 34)
                Spacer(minLength: 0)
                if state.recording {
                    Waveform(mode: .fixed(Array(VVActivity.waveLevels.prefix(52))), bars: 52, height: 28)
                } else {
                    Waveform(mode: .line(), bars: 52, height: 28)
                }
            }
            HStack(spacing: 8) { buttons() }
        }
        .foregroundStyle(VVColor.fgPrimary)
        .padding(14)
    }
}

/// Expanded island, top line: state on the left, a 22pt timer on the right.
struct IslandExpandedTitle: View {
    let state: VVActivityState

    var body: some View {
        HStack(spacing: 8) {
            ActivityGlyph(state: state, micSize: 15)
            Text(VVActivity.title(state)).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(.white)
        // The island is always black: resolve state/recording as dark (red).
        .environment(\.colorScheme, .dark)
    }
}

struct IslandExpandedTimer: View {
    let state: VVActivityState

    var body: some View {
        ActivityTimer(state: state)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white)
    }
}

/// Expanded island, body: waveform (a flat line while starting or
/// recognising), then buttons.
struct IslandExpandedBody<Buttons: View>: View {
    let state: VVActivityState
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 12) {
            if state.recording {
                Waveform(mode: .fixed(VVActivity.waveLevels), bars: 56, height: 24)
            } else {
                Waveform(mode: .line(), bars: 56, height: 24)
            }
            HStack(spacing: 8) { buttons() }
        }
        .environment(\.colorScheme, .dark)
    }
}
