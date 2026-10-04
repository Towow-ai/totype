import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One physical pixel line (DESIGN.md §6): 1/3 pt on @3x, 1/2 pt on @2x.
struct HairlineDivider: View {
    var leadingInset: CGFloat = 0
    var color: Color = VVColor.lineHairline
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: VVMetric.hairline(displayScale))
            .padding(.leading, leadingInset)
    }
}

extension Shape where Self == RoundedRectangle {
    /// Continuous-curvature rounded rectangle; radii come from {7, 10, 14, 20, 44}.
    static func vvRounded(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// The small drawn check used next to 15pt Medium text (DESIGN.md §6:
/// 14pt box, 2.6 stroke in the 24-unit grid). Path from kit.js `check`.
struct VVCheckGlyph: View {
    var size: CGFloat = 14
    var stroke: CGFloat = 2.6

    var body: some View {
        Canvas { context, canvas in
            let u = canvas.width / 24
            var path = Path()
            path.move(to: CGPoint(x: 5 * u, y: 12.6 * u))
            path.addLine(to: CGPoint(x: 9.6 * u, y: 17.2 * u))
            path.addLine(to: CGPoint(x: 19 * u, y: 7.4 * u))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: stroke * u, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Brand mark: two closing quotation marks, each a circle plus a two-curve
/// tail that ends inside the circle (design-v2 `icons/icon.js` `mark`/`pair`).
struct VVQuoteMark: Shape {
    /// Circle radius and edge gap as fractions of the box width
    /// (1024 icon: r 118, gap 96, centre line at 41.5%).
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let u = s / 1024
        let r = 118 * u, g = 96 * u
        let cy = rect.minY + s * 0.415, cx = rect.midX
        let dx = r + g / 2
        var path = Path()
        for x in [cx - dx, cx + dx] {
            path.addEllipse(in: CGRect(x: x - r, y: cy - r, width: 2 * r, height: 2 * r))
            func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px * r, y: cy + py * r) }
            path.move(to: p(1, 0))
            path.addCurve(to: p(-0.52, 2.36), control1: p(1, 1.28), control2: p(0.34, 2.02))
            path.addCurve(to: p(0.54, 0.80), control1: p(0.30, 1.78), control2: p(0.54, 1.18))
            path.closeSubpath()
        }
        return path
    }
}

/// Haptic mapping from DESIGN.md §8.
enum VVHaptics {
    #if canImport(UIKit)
    static func start() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func finish() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func cancel() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func undo() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func inserted() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    #else
    static func start() {}
    static func finish() {}
    static func cancel() {}
    static func undo() {}
    static func inserted() {}
    static func error() {}
    #endif
}

/// Animation choice that honours Reduce Motion (every spring → 150 ms fade).
extension Animation {
    static func vv(_ spring: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? VVMotion.reduced : spring
    }
    /// Collapse back to the circle (DESIGN.md §8).
    static let vvCollapse = Animation.spring(duration: 0.32, bounce: 0)
    /// Side circles growing in, 40 ms after the capsule starts.
    static let vvSides = Animation.spring(duration: 0.32, bounce: 0.2).delay(0.04)
}

/// Capsule pill (28 high, radius 14, 12 side padding, 15 Medium); hit area
/// grows to 44 high.
struct VVPillStyle: ButtonStyle {
    var prominent = false
    /// Keyboard pills sit on the keyboard background and use the key fill;
    /// app pills use `fill/control`.
    var onKeyboard = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = prominent
            ? VVColor.fillKeyProminent
            : (onKeyboard ? (configuration.isPressed ? VVColor.fillKeyPressed : VVColor.fillKey)
                          : (configuration.isPressed ? VVColor.fillControlPressed : VVColor.fillControl))
        return configuration.label
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? VVColor.fgInverse : VVColor.fgPrimary)
            .padding(.horizontal, VVMetric.pillPaddingX)
            .frame(height: VVMetric.pillHeight)
            .background(Capsule().fill(fill))
            .opacity(prominent && configuration.isPressed ? 0.8 : 1)
            // 44pt hit area without changing the 28pt layout height.
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -8)
    }
}
