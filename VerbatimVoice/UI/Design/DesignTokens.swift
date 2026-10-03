import AppKit
import SwiftUI

// Mac subset of the design tokens; see docs/DESIGN.md.
// Values are copied verbatim; only the dynamic-colour plumbing is AppKit-specific. Mac-only
// surfaces (overlay pill, menu panel, history window) take their numbers from the
// screens/mac-*.html mockups and are grouped under `VVMac`.

enum VVColor {
    /// Resolves light/dark from the drawing appearance, so the same token works in the
    /// non-activating overlay panel, the menu-bar window and the console window.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let bgCanvas = dynamic(hex(0xFFFFFF), hex(0x08090A))
    static let bgRaised = dynamic(hex(0xF6F7F9), hex(0x131415))
    static let bgSunken = dynamic(hex(0xEDEEF0), hex(0x1C1D1E))
    static let fgPrimary = dynamic(hex(0x111213), hex(0xF4F5F7))
    static let fgSecondary = dynamic(hex(0x5A5B5C), hex(0x9D9EA0))
    static let fgTertiary = dynamic(hex(0x737476), hex(0x7F8082))
    static let fgInverse = dynamic(hex(0xFFFFFF), hex(0x08090A))
    static let lineHairline = dynamic(hex(0xE3E4E6), hex(0x262628))
    static let lineStrong = dynamic(hex(0xBDBEC0), hex(0x474849))
    static let fillProminent = dynamic(hex(0x111213), hex(0xF4F5F7))
    static let fillControl = dynamic(hex(0xEDEEF0), hex(0x262628))
    /// state/recording — the microphone is capturing (waveform, recording marks only).
    /// Mac light = fg/primary (no red on a light Mac surface);
    /// dark = system recording red. Follows the drawing appearance like every token.
    static let stateRecording = dynamic(hex(0x8A8D93), hex(0xE8766D))  // softened 2026-10-01
}

enum VVMetric {
    static let radiusKey: CGFloat = 7
    static let radiusTall: CGFloat = 10
    static let radiusCard: CGFloat = 14
    static let radiusSheet: CGFloat = 20
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16

    static let waveformBarWidth: CGFloat = 2
    static let waveformBarPitch: CGFloat = 3
    static let waveformMinHeight: CGFloat = 2
    static let waveformBarsMac = 14
    static let waveformAttack: Double = 0.030
    static let waveformRelease: Double = 0.180
    static let waveformSampleHz: Double = 15

    /// 1 physical pixel: 0.5pt on @2x, 1pt on @1x.
    static func hairline(_ scale: CGFloat) -> CGFloat { 1 / max(scale, 1) }
}

enum VVMotion {
    static let settle = Animation.spring(duration: 0.28, bounce: 0.05)
    static let reduced = Animation.easeOut(duration: 0.15)
    /// Mac overlay in/out: opacity + 4pt rise, ≤ 200ms ease-out (DESIGN.md §8).
    static let overlay = Animation.easeOut(duration: 0.18)
}

/// Mac surfaces. Mac text is 13pt by default (HIG macOS body), so these do not reuse the
/// iOS 17pt ramp.
enum VVMac {
    // Overlay pill. Revised 2026-10-01 (DESIGN.md §13.3): the pill read as "浓" because the
    // surface was `.thinMaterial` (already ~80% opaque with a saturation boost) plus a white
    // tint on top, under a 6pt/18pt drop shadow. Now: the lightest material grade, a 10% tint
    // that only guards text contrast, a 1pt contact shadow and a rim you cannot see on a flat
    // backdrop. The pill is also 2pt shorter and its text is Regular, not Medium.
    static let pillHeight: CGFloat = 28
    static let pillLeading: CGFloat = 11
    static let pillTrailing: CGFloat = 10
    static let pillGap: CGFloat = 8
    static let pillFont = Font.system(size: 13, weight: .regular)
    static let pillTracking: CGFloat = -0.08
    /// Digits in the pill and the menu panel: same size and weight as the Chinese text,
    /// `.monospacedDigit()` only on values that tick (timer, countdown), never on static counts.
    static let numberFont = Font.system(size: 13, weight: .regular)
    /// With `.ultraThinMaterial` (≈50% base) this lands the pill near 65% opacity: fg/primary
    /// stays ≥ 7:1 even over a black desktop region, and the desktop still shows through.
    static let pillTint = VVColor.dynamic(VVColor.hex(0xFFFFFF, alpha: 0.30), VVColor.hex(0x000000, alpha: 0.26))
    /// Secondary text inside the translucent pill: one step darker than fg/secondary so it
    /// survives a dark desktop region under a light pill (≥ 4.5:1 at 65% white over black).
    static let pillSecondary = VVColor.dynamic(VVColor.hex(0x414244), VVColor.hex(0xDDDEE0))
    static let pillStroke = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.06), VVColor.hex(0xFFFFFF, alpha: 0.07))
    static let pillSeparator = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.12), VVColor.hex(0xFFFFFF, alpha: 0.14))
    static let kbdFill = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.06), VVColor.hex(0xFFFFFF, alpha: 0.10))
    /// Contact shadow: 1pt down, 2.5pt blur. No ambient shadow — on a light desktop the old
    /// 6pt/18pt halo was most of the "frame".
    static let shadowColor = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.10), VVColor.hex(0x000000, alpha: 0.28))
    static let shadowOffset: CGFloat = 1
    static let shadowBlur: CGFloat = 2.5
    /// Room around the pill inside the panel; kept at 14 so the panel's fitting size is unchanged.
    static let shadowInset: CGFloat = 14
    static let waveformHeight: CGFloat = 14

    // Menu panel (screens/mac-menu.html)
    static let menuWidth: CGFloat = 300
    static let menuFont = Font.system(size: 13)
    static let menuTracking: CGFloat = -0.08
    static let quoteFill = VVColor.dynamic(VVColor.hex(0xF2F2F3), VVColor.hex(0xFFFFFF, alpha: 0.07))
    static let buttonStroke = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.2), VVColor.hex(0xFFFFFF, alpha: 0.18))
    static let buttonFill = VVColor.dynamic(VVColor.hex(0xFFFFFF), VVColor.hex(0xFFFFFF, alpha: 0.1))
    static let panelHairline = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.1), VVColor.hex(0xFFFFFF, alpha: 0.12))

    // History window (screens/mac-history.html)
    static let windowSize = CGSize(width: 780, height: 560)
    static let sidebarWidth: CGFloat = 300
    static let titlebarHeight: CGFloat = 52
    /// Detail column content starts 64pt below the window top; the column itself
    /// begins under the 52pt title area.
    static let detailTopInset: CGFloat = 12
    static let searchFill = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.06), VVColor.hex(0xFFFFFF, alpha: 0.08))
    static let selectedRowFill = VVColor.dynamic(VVColor.hex(0xFFFFFF), VVColor.hex(0x262628))
    static let selectedRowStroke = VVColor.dynamic(VVColor.hex(0x000000, alpha: 0.08), VVColor.hex(0xFFFFFF, alpha: 0.08))
    static let transcriptFont = Font.system(size: 15)
    static let transcriptTracking: CGFloat = -0.23
}

/// A 1-physical-pixel rule in the given colour.
struct Hairline: View {
    var color: Color = VVColor.lineHairline
    var vertical = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let width = VVMetric.hairline(displayScale)
        Rectangle()
            .fill(color)
            .frame(width: vertical ? width : nil, height: vertical ? nil : width)
    }
}

/// Mac push button from the mockups: 24pt tall, 6pt corner, hairline ring. `prominent` is the
/// single filled button per surface (fill/key-prominent).
struct VVButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .tracking(VVMac.menuTracking)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(prominent ? VVColor.fgInverse : VVColor.fgPrimary)
            .background {
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                if prominent {
                    shape.fill(VVColor.fillProminent)
                } else {
                    shape.fill(VVMac.buttonFill)
                        .overlay(shape.strokeBorder(VVMac.buttonStroke, lineWidth: VVMetric.hairline(displayScale)))
                        .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension View {
    /// CSS-style line height for system text of `fontSize`: the gap between the font's
    /// natural line height and `lineHeight` becomes line spacing plus half-leading above
    /// and below, so stacked single lines land on the mockup's rhythm too.
    func lineHeight(_ lineHeight: CGFloat, fontSize: CGFloat) -> some View {
        let font = NSFont.systemFont(ofSize: fontSize)
        let natural = font.ascender - font.descender + font.leading
        let extra = max(0, lineHeight - natural)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}
