import SwiftUI

/// Letter layer on the system keyboard geometry (DESIGN.md §3.1, kit.js
/// `lettersLayer`): 10-column grid, second row indented half a pitch,
/// shift / delete 44 wide with a 14 inset, measured bottom-row widths.
/// No shadows; function keys share the letter fill.
struct LetterKeyboardView: View {
    let grid: VVGrid
    let globe: GlobeKeySource
    let returnTitle: String
    let actions: KeyboardKeyActions
    let switchToVoice: () -> Void

    private enum Layer { case letters, numbers, symbols }
    private enum ShiftState { case off, once, locked }

    private struct Bubble: Equatable {
        var text: String
        var face: CGRect
    }

    @State private var layer: Layer = .letters
    @State private var shift: ShiftState = .off
    @State private var lastShiftTap: Date = .distantPast
    @State private var bubble: Bubble?

    private static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let numberRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    private static let symbolRows = ["，。？！：；、…—·", "“”‘’（）《》【】", "[]{}#+="]

    private var areaHeight: CGFloat { grid.keyAreaHeight + grid.bottomInset }

    var body: some View {
        ZStack(alignment: .topLeading) {
            row(0)
            row(1)
            thirdRow
            KeyboardBottomRow(
                layer: .letters,
                grid: grid,
                areaHeight: areaHeight,
                globe: globe,
                returnTitle: returnTitle,
                actions: actions,
                toggleTitle: layer == .letters ? "123" : "ABC",
                onToggle: { layer = layer == .letters ? .numbers : .letters },
                onMic: switchToVoice
            )
            if let bubble { bubbleView(bubble) }
        }
        .frame(width: grid.width, height: areaHeight, alignment: .topLeading)
    }

    private var rows: [String] {
        switch layer {
        case .letters: return Self.letterRows
        case .numbers: return Self.numberRows
        case .symbols: return Self.symbolRows
        }
    }

    // MARK: Rows

    /// Rows 1–2: ten keys on the grid, or nine indented half a pitch.
    private func row(_ r: Int) -> some View {
        let items = rows[r].map(String.init)
        let indent = items.count < 10 ? CGFloat(10 - items.count) * grid.pitch / 2 : 0
        return ForEach(Array(items.enumerated()), id: \.offset) { i, s in
            charKey(s, face: CGRect(x: grid.colX(i) + indent, y: grid.rowY(r), width: grid.key, height: grid.keyHeight))
        }
    }

    /// Row 3: shift (or #+= / 123), the letters between the 14pt insets, delete.
    private var thirdRow: some View {
        let items = rows[2].map(String.init)
        let y = grid.rowY(2), h = grid.keyHeight
        let innerX = VVGrid.marginX + VVGrid.shiftWidth + VVGrid.shiftInset
        let innerW = grid.width - 2 * innerX
        let n = CGFloat(items.count)
        // Seven letters land exactly on the key width; numbers/symbols widen.
        let w = (innerW - (n - 1) * VVGrid.gap) / n
        let shiftFace = CGRect(x: VVGrid.marginX, y: y, width: VVGrid.shiftWidth, height: h)
        let deleteFace = CGRect(x: grid.width - VVGrid.marginX - VVGrid.shiftWidth, y: y, width: VVGrid.shiftWidth, height: h)
        return ZStack(alignment: .topLeading) {
            leftThirdKey(face: shiftFace)
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                charKey(s, face: CGRect(x: innerX + CGFloat(i) * (w + VVGrid.gap), y: y, width: w, height: h),
                        hitPad: i == 0 || i == items.count - 1 ? VVGrid.shiftInset / 2 : 0)
            }
            DeleteKey(hit: hit(deleteFace), face: deleteFace, actions: actions)
        }
    }

    @ViewBuilder
    private func leftThirdKey(face: CGRect) -> some View {
        switch layer {
        case .letters:
            KeyCell(hit: hit(face), face: face, onUp: { inside in
                if inside { actions.click(); tapShift() }
            }) {
                Image(systemName: shiftIcon).font(.system(size: 19, weight: .regular))
            }
            .accessibilityLabel("Shift")
        case .numbers:
            textKey("#+=", face: face) { layer = .symbols }
        case .symbols:
            textKey("123", face: face) { layer = .numbers }
        }
    }

    private var shiftIcon: String {
        switch shift {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    // MARK: Key builders

    private func hit(_ face: CGRect, pad: CGFloat = 0) -> CGRect {
        KeyCellGeometry.hit(for: face, grid: grid, areaHeight: areaHeight).insetBy(dx: -pad, dy: 0)
    }

    private func textKey(_ title: String, face: CGRect, action: @escaping () -> Void) -> some View {
        KeyCell(hit: hit(face), face: face, onUp: { inside in
            if inside { actions.click(); action() }
        }) {
            Text(title).vvText(.keyLabelSmall)
        }
    }

    private func charKey(_ s: String, face: CGRect, hitPad: CGFloat = 0) -> some View {
        let shown = (layer == .letters && shift != .off) ? s.uppercased() : s
        return KeyCell(
            hit: hit(face, pad: hitPad),
            face: face,
            scalesOnPress: false,
            onDown: {
                actions.click()
                bubble = Bubble(text: shown, face: face)
            },
            onUp: { inside in
                bubble = nil
                if inside { typeCharacter(shown) }
            }
        ) {
            Text(shown).vvText(.keyLabel)
        }
    }

    // MARK: Behaviour

    private func typeCharacter(_ text: String) {
        actions.insert(text)
        if layer == .letters && shift == .once { shift = .off }
    }

    private func tapShift() {
        let now = Date()
        let isDouble = now.timeIntervalSince(lastShiftTap) < 0.3
        lastShiftTap = now
        switch shift {
        case .off: shift = .once
        case .once: shift = isDouble ? .locked : .off
        case .locked: shift = .off
        }
    }

    // MARK: Bubble

    /// Key pop: the pressed letter enlarged above the key (radius 10, the
    /// only shadow on the keyboard, as in the design kit's `.bubble`).
    private func bubbleView(_ b: Bubble) -> some View {
        let w = b.face.width + 20
        let h = b.face.height + 10
        let x = min(max(b.face.midX, w / 2 + 2), grid.width - w / 2 - 2)
        // The top row has no room above; the pop overlaps the key instead.
        let y = max(h / 2, b.face.minY - h / 2 + 6)
        return Text(b.text)
            .font(.system(size: 36))
            .foregroundStyle(VVColor.fgKeyLabel)
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: VVMetric.radiusTall, style: .continuous)
                    .fill(VVColor.fillKey)
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
            )
            .position(x: x, y: y)
            .allowsHitTesting(false)
    }
}
