import AppKit

/// The Verbatim quotation mark, ported 1:1 from the design icon source (see docs/DESIGN.md).
/// Each mark is a circle plus a tail made of two cubic curves that ends inside the circle,
/// so the filled union has no seam. Coordinates are SVG-style (y grows downward).
enum BrandMark {
    static func fillMark(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * r, y: cy + y * r) }
        NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
        let tail = NSBezierPath()
        tail.move(to: p(1, 0))
        tail.curve(to: p(-0.52, 2.36), controlPoint1: p(1, 1.28), controlPoint2: p(0.34, 2.02))
        tail.curve(to: p(0.54, 0.80), controlPoint1: p(0.30, 1.78), controlPoint2: p(0.54, 1.18))
        tail.close()
        // Filled separately from the circle: a single path could cancel out where the two
        // windings overlap.
        tail.fill()
    }

    static func fillPair(cx: CGFloat, cy: CGFloat, r: CGFloat, gap: CGFloat) {
        let dx = r + gap / 2
        fillMark(cx: cx - dx, cy: cy, r: r)
        fillMark(cx: cx + dx, cy: cy, r: r)
    }

    /// Menu-bar template image (16 pt grid from `VVIcon.menubar(16)`): idle = two marks;
    /// recording = the same marks plus a filled dot below. Template images are monochrome and
    /// the menu bar inverts them, so the recording state is a shape change, never red.
    static func menuBarImage(recording: Bool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: CGSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setFill()
            fillPair(cx: side / 2, cy: 6.5, r: 2.25, gap: 2)
            if recording {
                NSBezierPath(ovalIn: CGRect(x: side / 2 - 1.5, y: side - 3 - 1.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? String(localized: "\(AppIdentity.displayName) 正在录音") : AppIdentity.displayName
        return image
    }

    /// Built once: the menu-bar label is re-evaluated on every AppModel publish.
    static let menuBarIdle = menuBarImage(recording: false)
    static let menuBarRecording = menuBarImage(recording: true)
}
