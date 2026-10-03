import Combine
import SwiftUI

/// Lightweight level channel for the overlay waveform.
///
/// Audio levels must never travel through `AppModel` as a high-frequency `@Published`
/// value (see the 9-23 fix in README). The overlay controller feeds this object directly;
/// only `WaveformBars` observes it, it publishes at the design's 15 Hz sample rate rather
/// than at the audio callback rate, and the controller stops feeding it when the panel
/// leaves the listening state.
@MainActor
final class OverlayLevelMeter: ObservableObject {
    @Published private(set) var bars: [CGFloat]

    private let count: Int
    private var envelope: Double = 0
    private var windowPeak: Double = 0
    private var lastIngest: TimeInterval?
    private var lastPush: TimeInterval = 0

    init(count: Int = VVMetric.waveformBarsMac) {
        self.count = count
        bars = Array(repeating: 0, count: count)
    }

    /// Feeds one raw RMS sample. Attack 30 ms / release 180 ms exponential smoothing, then
    /// one bar per 1/15 s carrying the window's peak so short syllables are not lost.
    func ingest(_ level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let target = Double(min(1, max(0, level)))
        let dt = lastIngest.map { max(0, now - $0) } ?? (1 / VVMetric.waveformSampleHz)
        lastIngest = now
        let tau = target > envelope ? VVMetric.waveformAttack : VVMetric.waveformRelease
        envelope += (target - envelope) * (1 - exp(-dt / tau))
        windowPeak = max(windowPeak, envelope)
        guard now - lastPush >= 1 / VVMetric.waveformSampleHz else { return }
        lastPush = now
        bars = Array(bars.dropFirst()) + [CGFloat(windowPeak)]
        windowPeak = envelope
    }

    /// Seeds the first visible frame from a level cached while the panel was hidden.
    func prime(_ level: Float) {
        envelope = Double(min(1, max(0, level)))
        windowPeak = envelope
        lastIngest = nil
        lastPush = 0
        var seeded = Array(repeating: CGFloat(0), count: count)
        seeded[count - 1] = CGFloat(envelope)
        if bars != seeded { bars = seeded }
    }

    /// Fixed bars for design snapshots (DesignPreview). Not used by the live path.
    func load(_ levels: [CGFloat]) {
        bars = Array(levels.prefix(count)) + Array(repeating: 0, count: max(0, count - levels.count))
    }

    func reset() {
        envelope = 0
        windowPeak = 0
        lastIngest = nil
        lastPush = 0
        let silent = Array(repeating: CGFloat(0), count: count)
        if bars != silent { bars = silent }
    }

    /// Bar height from DESIGN.md §7.3: max(2, h × level^0.55 × 1.4), capped at h.
    nonisolated static func barHeight(level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let shaped = pow(min(1, max(0, level)), 0.55) * 1.4
        return min(maxHeight, max(VVMetric.waveformMinHeight, (maxHeight * shaped).rounded()))
    }
}

/// Live waveform: 2pt bars on a 3pt pitch in `stateRecording` (fg/primary in light,
/// recording red in dark). Silence draws a row of 2pt dots,
/// which keeps "no sound" visible.
struct WaveformBars: View {
    @ObservedObject var meter: OverlayLevelMeter
    var height: CGFloat = VVMac.waveformHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StaticWaveform(levels: meter.bars, height: height, color: VVColor.stateRecording)
            .animation(reduceMotion ? nil : .linear(duration: 1 / VVMetric.waveformSampleHz), value: meter.bars)
    }
}

struct StaticWaveform: View {
    let levels: [CGFloat]
    var height: CGFloat = VVMac.waveformHeight
    var color: Color = VVColor.stateRecording

    var body: some View {
        HStack(alignment: .center, spacing: VVMetric.waveformBarPitch - VVMetric.waveformBarWidth) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: VVMetric.waveformBarWidth / 2, style: .continuous)
                    .fill(color)
                    .frame(
                        width: VVMetric.waveformBarWidth,
                        height: OverlayLevelMeter.barHeight(level: levels[index], maxHeight: height)
                    )
            }
        }
        .frame(width: Self.width(count: levels.count), height: height)
    }

    static func width(count: Int) -> CGFloat {
        CGFloat(count) * VVMetric.waveformBarPitch - (VVMetric.waveformBarPitch - VVMetric.waveformBarWidth)
    }
}

/// "识别中": the waveform collapses to a dotted line with one dark segment travelling along it
/// (900 ms per pass, linear). Reduce Motion leaves the segment still.
struct CollapsedWaveform: View {
    var count = VVMetric.waveformBarsMac
    var height: CGFloat = VVMac.waveformHeight
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated && !reduceMotion {
            TimelineView(.animation) { context in
                line(phase: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9)
            }
        } else {
            line(phase: nil)
        }
    }

    private func line(phase: Double?) -> some View {
        let width = StaticWaveform.width(count: count)
        let segment = (width * 0.22).rounded()
        let dot = VVMetric.waveformMinHeight
        return Canvas { context, size in
            let y = (size.height - dot) / 2
            for index in 0..<count {
                let rect = CGRect(x: CGFloat(index) * VVMetric.waveformBarPitch, y: y, width: VVMetric.waveformBarWidth, height: dot)
                context.fill(Path(roundedRect: rect, cornerRadius: dot / 2), with: .color(VVColor.lineStrong))
            }
            let x: CGFloat
            if let phase {
                x = -segment + CGFloat(phase) * (width + segment)
            } else {
                x = (width * 0.28).rounded()
            }
            var clipped = context
            clipped.clip(to: Path(CGRect(origin: .zero, size: size)))
            clipped.fill(
                Path(roundedRect: CGRect(x: x, y: y, width: segment, height: dot), cornerRadius: dot / 2),
                with: .color(VVColor.fgPrimary)
            )
        }
        .frame(width: width, height: height)
    }
}
