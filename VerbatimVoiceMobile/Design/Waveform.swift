import SwiftUI

/// Bar waveform (DESIGN.md §4.3 / §7.3 / §8). Bars are 2 wide on a 3 pitch,
/// never shorter than 2, so silence reads as a dotted line. Red only while
/// the microphone is capturing (`.live`).
struct Waveform: View {
    enum Mode: Equatable {
        /// Level history, oldest first, 0…1 (the app's 32-slot ring).
        /// Resampled to the bar count, smoothed per bar with a 30 ms attack
        /// and 180 ms release, drawn at 60 Hz.
        case live([Float])
        /// Fixed bar heights as fractions of the box height (previews and
        /// the Live Activity, which cannot receive 15 Hz levels).
        case fixed([CGFloat], color: FixedColor = .recording)
        /// Recognising: bars collapse to a line and a dark segment flows
        /// along it once every 900 ms. `phase` pins the segment (0…1).
        case line(phase: CGFloat? = nil)
        /// Playback: grey bars, the played fraction in the primary colour.
        case replay([CGFloat], played: CGFloat)
    }

    enum FixedColor: Equatable { case recording, strong, white }

    let mode: Mode
    var bars: Int = Int(VVMetric.waveformBarsKeyboard)
    var height: CGFloat = 48

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = BarSmoother()

    static let barWidth = VVMetric.waveformBarWidth     // 2
    static let pitch = VVMetric.waveformBarPitch        // 3
    static let minHeight = VVMetric.waveformMinHeight   // 2

    /// Before the first PCM buffer: grey dots, never red (the microphone is
    /// not capturing yet).
    static let waiting = Mode.fixed(Array(repeating: 0, count: 64), color: .strong)

    /// Segment at rest starts at 28% of the width (kit.js `line` mode).
    static let restPhase: CGFloat = 0.5 / 1.22

    static func width(bars: Int) -> CGFloat { CGFloat(bars) * pitch - (pitch - barWidth) }

    var body: some View {
        Group {
            switch mode {
            case .live(let levels):
                if reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled {
                    // 3 steps, drawn directly at the 15 Hz the levels arrive.
                    canvas(heights: Self.targets(levels, bars: bars, box: height).map(quantised), color: VVColor.stateRecording)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / VVMetric.waveformDrawHz)) { context in
                        let targets = Self.targets(levels, bars: bars, box: height)
                        let heights = smoother.step(to: targets, at: context.date)
                        canvas(heights: heights, color: VVColor.stateRecording)
                    }
                }
            case .fixed(let fractions, let color):
                canvas(heights: fractions.prefix(bars).map { max(Self.minHeight, ($0 * height).rounded()) },
                       color: color == .recording ? VVColor.stateRecording : color == .white ? .white : VVColor.lineStrong)
            case .line(let phase):
                if let phase {
                    lineCanvas(phase: phase)
                } else if reduceMotion {
                    lineCanvas(phase: Self.restPhase)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        lineCanvas(phase: CGFloat(t.truncatingRemainder(dividingBy: 0.9) / 0.9))
                    }
                }
            case .replay(let fractions, let played):
                replayCanvas(fractions, played: played)
            }
        }
        .frame(width: Self.width(bars: bars), height: height)
        .accessibilityHidden(true)
    }

    private func quantised(_ h: CGFloat) -> CGFloat {
        let steps: [CGFloat] = [Self.minHeight, height * 0.45, height * 0.9]
        return steps.min { abs($0 - h) < abs($1 - h) } ?? Self.minHeight
    }

    private func canvas(heights: [CGFloat], color: Color) -> some View {
        Canvas { context, size in
            for (i, h) in heights.enumerated() {
                let rect = CGRect(x: CGFloat(i) * Self.pitch, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }

    private func lineCanvas(phase: CGFloat) -> some View {
        Canvas { context, size in
            let y = (size.height - Self.minHeight) / 2
            for i in 0..<bars {
                let rect = CGRect(x: CGFloat(i) * Self.pitch, y: y, width: Self.barWidth, height: Self.minHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(VVColor.lineStrong))
            }
            // kit.js: a segment 22% of the width; at rest it starts at 28%.
            let w = size.width, seg = w * 0.22
            let x = -seg + (w + seg) * phase
            let clipped = CGRect(x: x, y: y, width: seg, height: Self.minHeight).intersection(CGRect(x: 0, y: y, width: w, height: Self.minHeight))
            if !clipped.isNull, clipped.width > 0 {
                context.fill(Path(roundedRect: clipped, cornerRadius: 1), with: .color(VVColor.fgPrimary))
            }
        }
    }

    private func replayCanvas(_ fractions: [CGFloat], played: CGFloat) -> some View {
        Canvas { context, size in
            for (i, f) in fractions.prefix(bars).enumerated() {
                let h = max(Self.minHeight, (f * size.height).rounded())
                let rect = CGRect(x: CGFloat(i) * Self.pitch, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                let isPlayed = CGFloat(i) / CGFloat(bars) < played
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(isPlayed ? VVColor.fgPrimary : VVColor.lineStrong))
            }
        }
    }

    /// Bar targets: the history right-aligned in its 32-slot ring (missing
    /// history is silence), resampled to `bars`, through the Mac curve
    /// `max(2, h × level^0.55 × 1.4)`.
    static func targets(_ levels: [Float], bars: Int, box: CGFloat) -> [CGFloat] {
        let capacity = 32
        let recent = levels.suffix(capacity)
        let ring = Array(repeating: Float(0), count: capacity - recent.count) + recent
        return (0..<bars).map { i in
            let t = CGFloat(i) / CGFloat(max(1, bars - 1)) * CGFloat(capacity - 1)
            let lo = Int(t.rounded(.down)), hi = min(capacity - 1, lo + 1)
            let f = t - CGFloat(lo)
            let level = CGFloat(ring[lo]) * (1 - f) + CGFloat(ring[hi]) * f
            let h = box * pow(max(0, min(1, level)), 0.55) * 1.4
            return max(minHeight, min(box, h))
        }
    }
}

/// Per-bar exponential smoothing: 30 ms attack, 180 ms release.
final class BarSmoother {
    private var current: [CGFloat] = []
    private var last: Date?

    func step(to targets: [CGFloat], at now: Date) -> [CGFloat] {
        let dt = min(0.1, max(0, now.timeIntervalSince(last ?? now)))
        last = now
        if current.count != targets.count { current = Array(repeating: Waveform.minHeight, count: targets.count) }
        let attack = 1 - exp(-dt / VVMotion.waveformAttack)
        let release = 1 - exp(-dt / VVMotion.waveformRelease)
        for i in targets.indices {
            let k = targets[i] > current[i] ? attack : release
            current[i] += (targets[i] - current[i]) * CGFloat(k)
        }
        return current
    }
}

/// Deterministic speech-like levels, a port of kit.js `levels(n, seed)`, for
/// previews and the Live Activity's static waveform.
enum VVSampleLevels {
    static func make(_ n: Int, seed: Int = 7) -> [CGFloat] {
        // JS numbers are doubles, so the LCG is evaluated in Double (with
        // the same precision loss) to reproduce the mockup bars exactly.
        var s = Double(seed) * 9301 + 49297
        func rnd() -> Double {
            s = (s * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
            return s / 2147483648
        }
        return (0..<n).map { i in
            let env = pow(max(0, sin(Double(i) / Double(n) * .pi * 2.3 + 0.4)), 0.7)
            let v = env * (0.35 + 0.65 * rnd())
            return CGFloat(min(1, v * 1.15))
        }
    }
}
