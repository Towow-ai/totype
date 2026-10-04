import SwiftUI

/// The one object that changes shape (DESIGN.md §0, §8, §13):
/// circle = ready, capsule = listening; tapping the capsule commits.
///
/// One value (`phase`) drives everything. The capsule is the circle with a
/// wider frame, so the centre never moves and a reversed spring retargets
/// from the current width. While listening there are two shapes: the ✕
/// circle on the left (columns 0–1) and the centred capsule (columns 2–7);
/// the right two columns stay empty (2026-10-01: the ✓ circle repeated the
/// capsule). Hit areas are invisible column rectangles, the full band tall:
/// ready 4 columns; ✕ 2 columns; finish = everything right of ✕ (columns
/// 2–9), so a tap where the ✓ used to be still finishes. On the keyboard the
/// delete key owns the top of columns 8–9 (`finishTopRightReserve`), so
/// finish there starts below it (DESIGN.md §13.4). Reduce Motion: no
/// shape change, the two arrangements crossfade in 150 ms.
struct MicControl: View {
    enum Phase: Equatable {
        case ready
        case listening
        case finalizing
    }

    enum Style: Equatable {
        /// Keyboard: white keys; the timer sits under the bars.
        case keyboard
        /// App bottom bar / return page: the ready circle is filled, the
        /// listening shapes use `fill/control`.
        case bar
    }

    /// What the ready circle does when tapped.
    enum ReadyAction {
        case perform(() -> Void)
        /// Opens a URL through `Link` (the keyboard's device-proven path to
        /// the app when no session answers).
        case link(URL, onTap: () -> Void)
    }

    enum Elapsed: Equatable {
        case none
        case running(since: Date)
        case frozen(TimeInterval)
    }

    let phase: Phase
    let style: Style
    let grid: VVGrid
    var scale: VVMicScale = .keyboard
    /// Band height the shapes are centred in (151 on the keyboard, 56 in the bar).
    var bandHeight: CGFloat = 151
    var wave: Waveform.Mode = .line()
    var elapsed: Elapsed = .none
    /// Dims the glyph only; the tap still goes through so the caller can explain.
    var readyEnabled = true
    var readyBusy = false
    var ready: ReadyAction = .perform({})
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}
    /// Height at the top of columns 8–9 that belongs to another key (the
    /// keyboard's delete cell); finish covers only the rest of those columns.
    /// Zero (the app bar and return page) keeps the full 8-column finish.
    var finishTopRightReserve: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed: Part?

    fileprivate enum Part: Hashable { case ready, cancel, capsule }

    private var expanded: Bool { phase != .ready }
    private var finalizing: Bool { phase == .finalizing }

    private var capsuleSpan: (x: CGFloat, w: CGFloat) { grid.span(2, 6) }
    private var centerX: CGFloat { grid.spanMidX(2, 6) }
    private var centerY: CGFloat { bandHeight / 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if reduceMotion {
                circleLayer.opacity(expanded ? 0 : 1)
                expandedLayer(width: capsuleSpan.w).opacity(expanded ? 1 : 0)
            } else {
                morphingLayer
            }
            hitLayer
        }
        .frame(width: grid.width, height: bandHeight, alignment: .topLeading)
        .animation(reduceMotion ? VVMotion.reduced : nil, value: expanded)
    }

    // MARK: Visuals

    private var readyFill: Color {
        if style == .bar { return VVColor.fillKeyProminent }
        return pressed == .ready ? VVColor.fillKeyPressed : VVColor.fillKey
    }

    private var plainFill: Color { style == .keyboard ? VVColor.fillKey : VVColor.fillControl }
    private var plainPressed: Color { style == .keyboard ? VVColor.fillKeyPressed : VVColor.fillControlPressed }

    /// Default motion: one capsule whose width springs between the circle
    /// and the 6-column capsule; the ✕ circle scales in 40 ms later.
    private var morphingLayer: some View {
        let width = expanded ? capsuleSpan.w : scale.diameter
        let fill = expanded ? (pressed == .capsule ? plainPressed : plainFill) : readyFill
        return ZStack(alignment: .topLeading) {
            cancelCircle
                .scaleEffect(expanded ? 1 : 0.001)
                .opacity(finalizing ? 0.35 : 1)
                .animation(expanded ? .vvSides : .vvCollapse, value: expanded)
                .animation(.easeOut(duration: 0.18), value: finalizing)
            ZStack {
                micGlyph.opacity(expanded ? 0 : 1)
                capsuleContent
                    .fixedSize()
                    .opacity(expanded ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: expanded)
            }
            .frame(width: width, height: scale.capsuleHeight)
            .background(Capsule(style: .circular).fill(fill))
            .clipShape(Capsule(style: .circular))
            .scaleEffect(pressed == .ready || pressed == .capsule ? 0.96 : 1)
            .position(x: centerX, y: centerY)
            .animation(expanded ? VVMotion.morph : .vvCollapse, value: expanded)
            .animation(VVMotion.press, value: pressed)
        }
    }

    /// Reduce Motion: the ready circle on its own.
    private var circleLayer: some View {
        ZStack {
            Circle().fill(readyFill)
            micGlyph
        }
        .frame(width: scale.diameter, height: scale.diameter)
        .position(x: centerX, y: centerY)
    }

    /// Reduce Motion: the two listening shapes on their own.
    private func expandedLayer(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            cancelCircle.opacity(finalizing ? 0.35 : 1)
            capsuleContent
                .fixedSize()
                .frame(width: width, height: scale.capsuleHeight)
                .background(Capsule(style: .circular).fill(pressed == .capsule ? plainPressed : plainFill))
            .position(x: centerX, y: centerY)
        }
    }

    /// ✕ circle, centred on columns 0–1.
    private var cancelCircle: some View {
        ZStack {
            Circle().fill(pressed == .cancel ? plainPressed : plainFill)
            Image(systemName: "xmark")
                .font(.system(size: style == .keyboard ? 17 : 16, weight: .semibold))
                .foregroundStyle(VVColor.fgKeyLabel)
        }
        .frame(width: scale.sideDiameter, height: scale.sideDiameter)
        .scaleEffect(pressed == .cancel ? 0.96 : 1)
        .animation(VVMotion.press, value: pressed)
        .position(x: grid.spanMidX(0, 2), y: centerY)
    }

    private var micGlyph: some View {
        Group {
            if readyBusy {
                ProgressView().tint(style == .bar ? VVColor.fgInverse : VVColor.fgKeyLabel)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: scale.glyph * 0.77, weight: .medium))
                    .foregroundStyle(style == .bar ? VVColor.fgInverse : VVColor.fgKeyLabel)
                    // Optical centre: the stand pulls the mass down (DESIGN.md §6).
                    .offset(y: -0.7)
            }
        }
        .opacity(readyEnabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var capsuleContent: some View {
        switch style {
        case .keyboard:
            VStack(spacing: 10) {
                Waveform(mode: wave, bars: Int(VVMetric.waveformBarsKeyboard), height: 48)
                ElapsedText(elapsed: elapsed)
                    .font(VVTextStyle.timer.font)
                    .foregroundStyle(finalizing ? VVColor.fgSecondary : VVColor.fgPrimary)
                    .frame(height: 22)
            }
        case .bar:
            Waveform(mode: wave, bars: 56, height: 32)
        }
    }

    // MARK: Hit areas

    private var hitLayer: some View {
        ZStack(alignment: .topLeading) {
            if expanded {
                hit(.cancel, span: grid.span(0, 2), label: "取消") { VVHaptics.cancel(); onCancel() }
                    .disabled(finalizing)
                if finishTopRightReserve > 0 {
                    // The capsule, plus the empty right columns below the delete cell.
                    hit(.capsule, span: grid.span(2, 6), label: "完成") { VVHaptics.finish(); onFinish() }
                        .disabled(finalizing)
                    hit(.capsule, span: grid.span(8, 2), top: finishTopRightReserve, label: "完成") { VVHaptics.finish(); onFinish() }
                        .disabled(finalizing)
                        .accessibilityHidden(true)
                } else {
                    // The capsule plus the empty right columns.
                    hit(.capsule, span: grid.span(2, 8), label: "完成") { VVHaptics.finish(); onFinish() }
                        .disabled(finalizing)
                }
            } else {
                readyHit
            }
        }
    }

    @ViewBuilder
    private var readyHit: some View {
        let span = grid.span(3, 4)
        let label = Color.clear
            .frame(width: span.w + VVGrid.gap, height: bandHeight)
            .contentShape(Rectangle())
        switch ready {
        case .link(let url, let onTap):
            Link(destination: url) { label }
                .buttonStyle(HitStyle(part: .ready, pressed: $pressed))
                .simultaneousGesture(TapGesture().onEnded { VVHaptics.start(); onTap() })
                .accessibilityLabel("开始语音输入")
                .offset(x: span.x - VVGrid.gap / 2)
        case .perform(let action):
            Button { VVHaptics.start(); action() } label: { label }
                .buttonStyle(HitStyle(part: .ready, pressed: $pressed))
                .accessibilityLabel("开始语音输入")
                .offset(x: span.x - VVGrid.gap / 2)
                .disabled(readyBusy)
        }
    }

    private func hit(_ part: Part, span: (x: CGFloat, w: CGFloat), top: CGFloat = 0, label: String, action: @escaping () -> Void) -> some View {
        // Each rectangle owns half the gap on either side, so the columns
        // tile the band without dead strips. `top` leaves the band's upper
        // part to another key.
        Button(action: action) {
            Color.clear
                .frame(width: span.w + VVGrid.gap, height: bandHeight - top)
                .contentShape(Rectangle())
        }
        .buttonStyle(HitStyle(part: part, pressed: $pressed))
        .accessibilityLabel(label)
        .offset(x: span.x - VVGrid.gap / 2, y: top)
    }

    private struct HitStyle: ButtonStyle {
        let part: Part
        @Binding var pressed: Part?

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, isPressed in
                    if isPressed { pressed = part } else if pressed == part { pressed = nil }
                }
        }
    }
}

/// `m:ss` that ticks while running and holds when frozen.
struct ElapsedText: View {
    let elapsed: MicControl.Elapsed

    var body: some View {
        switch elapsed {
        case .none:
            Text("0:00").monospacedDigit()
        case .frozen(let seconds):
            Text(VVClock.format(seconds)).monospacedDigit()
        case .running(let since):
            TimelineView(.periodic(from: since, by: 0.25)) { context in
                Text(VVClock.format(context.date.timeIntervalSince(since))).monospacedDigit()
            }
        }
    }
}
