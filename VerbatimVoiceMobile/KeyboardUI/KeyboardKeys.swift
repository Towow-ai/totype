import SwiftUI
import UIKit

/// Text-editing callbacks shared by both keyboard layers. The extension wires
/// them to `KeyboardModel`; the app's design preview passes no-ops.
struct KeyboardKeyActions {
    var insert: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var deleteWordBackward: () -> Void = {}
    var moveCursor: (Int) -> Void = { _ in }
    var returnKey: () -> Void = {}
    var click: () -> Void = {}
}

/// How the globe key is provided.
enum GlobeKeySource {
    /// No globe (Face ID phones usually have it below the keyboard).
    case none
    /// The system's input-mode list through the controller.
    case system(UIInputViewController)
    /// Drawn only (design preview).
    case preview
}

/// Key face per DESIGN.md §4.3 / §2: radius 7 continuous, no shadow,
/// function keys the same fill as letters; only the pressed fill differs.
struct KeyFace<Label: View>: View {
    var pressed = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous)
                .fill(pressed ? VVColor.fillKeyPressed : VVColor.fillKey)
            label().foregroundStyle(VVColor.fgKeyLabel)
        }
    }
}

/// A key placed in keyboard coordinates. `hit` is the touch cell (the face
/// plus half the gaps around it, like system keys); `face` is drawn inside.
struct KeyCell<Label: View>: View {
    let hit: CGRect
    let face: CGRect
    /// Function keys shrink a little when pressed; letter keys pop a bubble instead.
    var scalesOnPress = true
    var onDown: () -> Void = {}
    var onUp: (_ inside: Bool) -> Void = { _ in }
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        KeyFace(pressed: pressed, label: label)
            .frame(width: face.width, height: face.height)
            .scaleEffect(pressed && scalesOnPress ? 0.96 : 1)
            .animation(VVMotion.press, value: pressed)
            .position(x: face.midX - hit.minX, y: face.midY - hit.minY)
            .frame(width: hit.width, height: hit.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onDown()
                    }
                    .onEnded { value in
                        pressed = false
                        let area = CGRect(origin: .zero, size: hit.size).insetBy(dx: -16, dy: -16)
                        onUp(area.contains(value.location))
                    }
            )
            .position(x: hit.midX, y: hit.midY)
    }
}

/// Hit cell around a face: half the gap on each side, edge keys reach the edge.
enum KeyCellGeometry {
    static func hit(for face: CGRect, grid: VVGrid, areaHeight: CGFloat) -> CGRect {
        let hx = VVGrid.gap / 2, hy = grid.rowGap / 2
        var minX = face.minX - hx, maxX = face.maxX + hx
        if face.minX <= VVGrid.marginX + 0.5 { minX = 0 }
        if face.maxX >= grid.width - VVGrid.marginX - 0.5 { maxX = grid.width }
        let minY = max(0, face.minY - hy)
        let maxY = min(areaHeight, face.maxY + hy)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Tap types a space; dragging sideways moves the cursor one character per
/// ~9 pt, like the system space bar's trackpad.
struct SpaceKey: View {
    let hit: CGRect
    let face: CGRect
    let actions: KeyboardKeyActions
    @State private var pressed = false
    @State private var dragging = false
    @State private var appliedSteps = 0
    private let stepWidth: CGFloat = 9

    var body: some View {
        KeyFace(pressed: pressed && !dragging) {
            Text("空格")
                .vvText(.keyLabelSmall)
                .opacity(dragging ? 0.4 : 1)
        }
        .frame(width: face.width, height: face.height)
        .position(x: face.midX - hit.minX, y: face.midY - hit.minY)
        .frame(width: hit.width, height: hit.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        actions.click()
                    }
                    if !dragging, abs(value.translation.width) > 12 {
                        dragging = true
                        appliedSteps = 0
                    }
                    guard dragging else { return }
                    let steps = Int(value.translation.width / stepWidth)
                    if steps != appliedSteps {
                        actions.moveCursor(steps - appliedSteps)
                        appliedSteps = steps
                    }
                }
                .onEnded { _ in
                    if !dragging { actions.insert(" ") }
                    pressed = false
                    dragging = false
                    appliedSteps = 0
                }
        )
        .position(x: hit.midX, y: hit.midY)
        .accessibilityLabel("空格")
    }
}

/// Deletes once on touch-down, repeats while held, speeds up, and after
/// about two seconds deletes a word at a time.
struct DeleteKey: View {
    let hit: CGRect
    let face: CGRect
    let actions: KeyboardKeyActions
    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        KeyFace(pressed: pressed) {
            Image(systemName: pressed ? "delete.left.fill" : "delete.left")
                .font(.system(size: 17, weight: .regular))
        }
        .frame(width: face.width, height: face.height)
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(VVMotion.press, value: pressed)
        .position(x: face.midX - hit.minX, y: face.midY - hit.minY)
        .frame(width: hit.width, height: hit.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in end() }
        )
        .onDisappear { end() }
        .position(x: hit.midX, y: hit.midY)
        .accessibilityLabel("删除")
    }

    private func begin() {
        guard !pressed else { return }
        pressed = true
        actions.click()
        actions.deleteBackward()
        let actions = actions
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            var count = 0
            var interval: UInt64 = 100_000_000
            while !Task.isCancelled {
                if count >= 20 {
                    actions.deleteWordBackward()
                    interval = 220_000_000
                } else {
                    actions.deleteBackward()
                    interval = max(45_000_000, interval * 9 / 10)
                }
                actions.click()
                count += 1
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func end() {
        pressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

/// Globe: the system list through UIKit when a controller is available,
/// otherwise a drawn key (preview).
struct GlobeKey: View {
    let source: GlobeKeySource
    let hit: CGRect
    let face: CGRect

    var body: some View {
        switch source {
        case .none:
            EmptyView()
        case .system(let controller):
            SystemGlobeButton(controller: controller)
                .frame(width: face.width, height: face.height)
                .position(x: face.midX, y: face.midY)
        case .preview:
            KeyCell(hit: hit, face: face) {
                Image(systemName: "globe").font(.system(size: 18.5, weight: .regular))
            }
        }
    }
}

/// UIKit button so the system handles tap (next keyboard) and long press
/// (input mode list) through `handleInputModeList(from:with:)`.
private struct SystemGlobeButton: UIViewRepresentable {
    let controller: UIInputViewController

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18.5, weight: .regular)
        configuration.baseForegroundColor = UIColor(VVColor.fgKeyLabel)
        configuration.background.backgroundColor = UIColor(VVColor.fillKey)
        configuration.background.cornerRadius = VVMetric.radiusKey
        let button = UIButton(configuration: configuration)
        button.layer.cornerCurve = .continuous
        button.addTarget(
            controller,
            action: #selector(UIInputViewController.handleInputModeList(from:with:)),
            for: .allTouchEvents
        )
        button.accessibilityLabel = "切换输入法"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

/// Bottom row shared by both layers (kit.js `bottomRow`): measured fixed
/// widths, the space bar takes the rest. Voice: [ABC][🌐][空格][return]
/// (delete moved to the top-right, columns 9–10 of row 1, DESIGN.md §13.4);
/// letters: [123][🌐][空格][🎤][return].
struct KeyboardBottomRow: View {
    enum Layer { case voice, letters }

    let layer: Layer
    let grid: VVGrid
    let areaHeight: CGFloat
    let globe: GlobeKeySource
    let returnTitle: String
    let actions: KeyboardKeyActions
    /// ABC (voice) or 123/ABC (letters) toggle.
    var toggleTitle: String
    var onToggle: () -> Void
    /// Letters layer: back to the voice layer.
    var onMic: () -> Void = {}

    var body: some View {
        let y = grid.rowY(3), h = grid.keyHeight, g = VVGrid.gap
        var x = VVGrid.marginX
        let toggleFace = CGRect(x: x, y: y, width: VVGrid.abcWidth, height: h)
        x += VVGrid.abcWidth + g
        var globeFace: CGRect?
        if case .none = globe {} else {
            globeFace = CGRect(x: x, y: y, width: VVGrid.globeWidth, height: h)
            x += VVGrid.globeWidth + g
        }
        let spaceFace: CGRect
        var fourthFace: CGRect?
        switch layer {
        case .voice:
            // Return ends on the right margin, flush with the delete key above.
            let spaceW = grid.width - VVGrid.marginX - x - (VVGrid.returnWidth + g)
            spaceFace = CGRect(x: x, y: y, width: spaceW, height: h)
            x += spaceW + g
        case .letters:
            let right = VVGrid.globeWidth + g + VVGrid.returnWidth + g
            let spaceW = grid.width - VVGrid.marginX - x - right + g
            spaceFace = CGRect(x: x, y: y, width: spaceW, height: h)
            x += spaceW + g
            fourthFace = CGRect(x: x, y: y, width: VVGrid.globeWidth, height: h)
            x += VVGrid.globeWidth + g
        }
        let returnFace = CGRect(x: x, y: y, width: VVGrid.returnWidth, height: h)
        let hit = { (face: CGRect) in KeyCellGeometry.hit(for: face, grid: grid, areaHeight: areaHeight) }

        return ZStack(alignment: .topLeading) {
            KeyCell(hit: hit(toggleFace), face: toggleFace, onUp: { inside in
                if inside { actions.click(); onToggle() }
            }) {
                Text(toggleTitle).vvText(.keyLabelSmall)
            }
            if let globeFace {
                GlobeKey(source: globe, hit: hit(globeFace), face: globeFace)
            }
            SpaceKey(hit: hit(spaceFace), face: spaceFace, actions: actions)
            if let fourthFace {
                KeyCell(hit: hit(fourthFace), face: fourthFace, onUp: { inside in
                    if inside { actions.click(); onMic() }
                }) {
                    Image(systemName: "mic.fill").font(.system(size: 19, weight: .regular))
                }
                .accessibilityLabel("语音")
            }
            KeyCell(hit: hit(returnFace), face: returnFace, onUp: { inside in
                if inside { actions.click(); actions.returnKey() }
            }) {
                Text(returnTitle)
                    .vvText(.keyLabelSmall)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}
