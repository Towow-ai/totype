import CoreGraphics

/// Keyboard column grid, ported once from design-v2 `shared/kit.js` so every
/// surface (keyboard, app mic bar, return page) computes positions from the
/// same formulas and the screen width. Nothing here hard-codes a 393pt value.
struct VVGrid: Equatable {
    /// Container width (the keyboard or screen width).
    let width: CGFloat
    /// Landscape keyboards use shorter rows (DESIGN.md §6: 36 / 7 / 34).
    var compact = false

    static let marginX = VVMetric.keyboardMarginX          // 6
    static let gap = VVMetric.keyboardKeyGap                // 6

    /// kit.js `key(W)`: (W − 12 − 54) / 10 → 32.7 at 393.
    var key: CGFloat { (width - 2 * Self.marginX - 9 * Self.gap) / 10 }
    /// kit.js `pitch(W)`: key + gap → 38.7 at 393.
    var pitch: CGFloat { key + Self.gap }
    /// kit.js `colX(W, i)`.
    func colX(_ i: Int) -> CGFloat { Self.marginX + CGFloat(i) * pitch }
    /// Horizontal span of `n` columns starting at column `c0` (kit.js `span`).
    func span(_ c0: Int, _ n: Int) -> (x: CGFloat, w: CGFloat) {
        (colX(c0), CGFloat(n) * key + CGFloat(n - 1) * Self.gap)
    }
    func spanMidX(_ c0: Int, _ n: Int) -> CGFloat {
        let s = span(c0, n)
        return s.x + s.w / 2
    }

    var keyHeight: CGFloat { compact ? 36 : VVMetric.keyboardKeyHeight }      // 43
    var rowGap: CGFloat { compact ? 7 : VVMetric.keyboardRowGap }              // 11
    var statusHeight: CGFloat { compact ? 34 : VVMetric.keyboardStatusRowHeight } // 44
    var bottomInset: CGFloat { compact ? 4 : VVMetric.keyboardBottomInset }    // 8
    /// Row `r` top inside the key area (below the status row).
    func rowY(_ r: Int) -> CGFloat { CGFloat(r) * (keyHeight + rowGap) }
    /// Rows 1–3 as one tall band: 151 in portrait.
    var bandHeight: CGFloat { 3 * keyHeight + 2 * rowGap }
    /// Four key rows: 205 in portrait.
    var keyAreaHeight: CGFloat { 4 * keyHeight + 3 * rowGap }
    /// Status row + key area + bottom inset (the extension's own height): 257.
    var contentHeight: CGFloat { statusHeight + keyAreaHeight + bottomInset }

    // Measured iOS 27 fixed widths (kit.js bottomRow / lettersLayer).
    static let abcWidth: CGFloat = 41.3
    static let globeWidth: CGFloat = 41.7
    static let returnWidth: CGFloat = 89.7
    static let shiftWidth: CGFloat = 44
    static let shiftInset: CGFloat = 14
}

/// Mic shape sizes at the two scales (DESIGN.md §13).
struct VVMicScale: Equatable {
    let diameter: CGFloat
    let sideDiameter: CGFloat
    let capsuleHeight: CGFloat
    let glyph: CGFloat

    static let keyboard = VVMicScale(
        diameter: VVMetric.micDiameterKeyboard,          // 112
        sideDiameter: VVMetric.micSideDiameterKeyboard,  // 72
        capsuleHeight: VVMetric.micCapsuleHeightKeyboard, // 112
        glyph: VVMetric.micGlyph                          // 30
    )
    static let bar = VVMicScale(
        diameter: VVMetric.micDiameterBar,               // 56
        sideDiameter: VVMetric.micSideDiameterBar,       // 56
        capsuleHeight: VVMetric.micCapsuleHeightBar,     // 56
        glyph: 26
    )
    /// Landscape keyboard: the band is 122 tall, so the shapes shrink to fit
    /// with the same 19.5-ish margin ratio.
    static let keyboardCompact = VVMicScale(diameter: 88, sideDiameter: 60, capsuleHeight: 88, glyph: 26)
}
