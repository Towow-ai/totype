import AppKit
import Combine
import SwiftUI

@MainActor
enum OverlayMode {
    case listening
    case cancelPending
    case finalizing
    case preview
    case success
    case failure
}

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var mode: OverlayMode = .listening
    @Published var message = ""
    @Published var text = ""
    @Published var recordingStartedAt: Date?
    @Published var recordingEndedAt: Date?
    @Published var providerBadge: String?
    @Published var cancelDeadline: Date?
    @Published var insertedCharacterCount: Int?
    /// One line after 已插入 when the primary was unusable, e.g.
    /// "Soniox 余额不足，已改用阿里云".
    @Published var insertedNotice: String?
    /// The travelling segment of the "识别中" line. Only design snapshots turn it off.
    @Published var animatesProgress = true
    /// Escape self-check failed: the listening pill says Esc will not cancel.
    @Published var escapeCancelUnavailable = false

    let onCancel: () -> Void
    let onUndoCancel: () -> Void
    let onCopy: () -> Void
    let onInsertCurrent: () -> Void
    let onDismiss: () -> Void

    init(
        onCancel: @escaping () -> Void,
        onUndoCancel: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onInsertCurrent: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onCancel = onCancel
        self.onUndoCancel = onUndoCancel
        self.onCopy = onCopy
        self.onInsertCurrent = onInsertCurrent
        self.onDismiss = onDismiss
    }
}

@MainActor
final class OverlayPanelController {
    private let viewModel: OverlayViewModel
    /// Waveform levels travel on their own channel, observed only by the waveform view.
    private let levelMeter = OverlayLevelMeter()
    private var panel: NSPanel?
    private var hostingView: OverlayHostingView?
    /// Mouse monitors that exist only while an interactive state is shown.
    private var pointerMonitors: [Any] = []
    private var dismissTask: Task<Void, Never>?
    private var currentAnchor: CGRect?
    private var cachedLevel: Float = 0
    private var activeSessionID: UUID?
    /// Bumped on every show/hide so a deferred fade or swap never acts on a newer state.
    private var presentationGeneration = 0

    /// How long the 已插入 pill stays after the Unicode events were dispatched.
    static let insertedVisibleSeconds: TimeInterval = 1.5
    /// Long enough to read the provider notice; the pill never takes clicks.
    static let insertedWithNoticeVisibleSeconds: TimeInterval = 4

    init(
        onCancel: @escaping () -> Void,
        onUndoCancel: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onInsertCurrent: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        viewModel = OverlayViewModel(
            onCancel: onCancel,
            onUndoCancel: onUndoCancel,
            onCopy: onCopy,
            onInsertCurrent: onInsertCurrent,
            onDismiss: onDismiss
        )
    }

    /// Builds the SwiftUI/AppKit surface while the app is idle so the first
    /// physical Option press only has to reveal an existing panel.
    func prepare() {
        let panel = ensurePanel()
        panel.setContentSize(preferredSize(for: .listening))
        position(panel, mode: .listening, anchor: nil)
        panel.orderOut(nil)
    }

    func present(
        sessionID: UUID? = nil,
        mode: OverlayMode,
        message: String,
        text: String,
        level: Float,
        anchor: CGRect?,
        recordingStartedAt: Date? = nil
    ) {
        if let sessionID {
            if let activeSessionID, activeSessionID != sessionID,
               mode != .listening { return }
            activeSessionID = sessionID
        }
        dismissTask?.cancel()
        dismissTask = nil
        let previousMode = viewModel.mode
        if mode == .listening {
            currentAnchor = anchor
            viewModel.providerBadge = nil
            viewModel.recordingStartedAt = recordingStartedAt ?? Date()
            viewModel.recordingEndedAt = nil
            viewModel.cancelDeadline = nil
            levelMeter.prime(level > 0 ? level : cachedLevel)
        } else if (mode == .finalizing || mode == .cancelPending), previousMode == .listening,
                  viewModel.recordingStartedAt != nil {
            // Freeze the displayed duration when recording stops.  Cloud or
            // local finalization time is latency, not part of the recording.
            viewModel.recordingEndedAt = Date()
        } else if mode == .preview || mode == .failure {
            currentAnchor = anchor
            viewModel.recordingStartedAt = nil
            viewModel.recordingEndedAt = nil
        }
        if mode != .success {
            viewModel.insertedCharacterCount = nil
            viewModel.insertedNotice = nil
        }
        viewModel.mode = mode
        viewModel.message = message
        viewModel.text = text

        let panel = ensurePanel()
        let interactive = mode == .preview || mode == .failure || mode == .cancelPending
        if panel.isKeyWindow {
            panel.resignKey()
        }
        let size = preferredSize(for: mode)
        panel.setContentSize(size)
        if let anchor {
            currentAnchor = anchor
        }
        position(panel, mode: mode, anchor: currentAnchor)
        reveal(panel)
        setPointerPassThrough(interactive: interactive)
    }

    func presentCancelPending(sessionID: UUID, deadline: Date) {
        viewModel.cancelDeadline = deadline
        present(
            sessionID: sessionID,
            mode: .cancelPending,
            message: String(localized: "已取消"),
            text: "",
            level: 0,
            anchor: nil
        )
    }

    /// Keeps the listening pill's "Esc 不可用" note in step with the self-check. The
    /// note is set before a recording starts (cached result) and corrected here if
    /// the recording's own Escape tap disagrees.
    func setEscapeCancelUnavailable(_ unavailable: Bool) {
        guard viewModel.escapeCancelUnavailable != unavailable else { return }
        viewModel.escapeCancelUnavailable = unavailable
        guard viewModel.mode == .listening, let panel, panel.isVisible else { return }
        panel.setContentSize(preferredSize(for: .listening))
        position(panel, mode: .listening, anchor: currentAnchor)
    }

    /// Separator + "Esc 不可用" in the pill font, measured once.
    private static let escapeNoteWidth: CGFloat = {
        let text = NSAttributedString(
            string: OverlayContentView.escapeUnavailableNote,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        return ceil(text.size().width) + 1 + VVMac.pillGap * 2
    }()

    /// Finalizing pill: leading + collapsed waveform + gap + label + trailing, label measured
    /// once in the pill font (+2pt for tracking and rounding). 116 for Chinese is the floor.
    private static let finalizingPillWidth: CGFloat = {
        let text = NSAttributedString(
            string: OverlayContentView.finalizingNote,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular)]
        )
        return VVMac.pillLeading + StaticWaveform.width(count: VVMetric.waveformBarsMac)
            + VVMac.pillGap + ceil(text.size().width) + 2 + VVMac.pillTrailing
    }()

    func updateLevel(_ level: Float, sessionID: UUID? = nil) {
        guard accepts(sessionID) else { return }
        cachedLevel = level
        // Feed the waveform only while it is on screen; a hidden or finished
        // overlay must not keep publishing level frames.
        guard viewModel.mode == .listening, panel?.isVisible == true else { return }
        levelMeter.ingest(level)
    }

    /// Retains the current session's latest level without publishing hidden
    /// SwiftUI updates. It becomes the next visible waveform frame.
    func cacheLevel(_ level: Float) {
        cachedLevel = level
    }

    func updateMessage(_ message: String, sessionID: UUID? = nil) {
        guard accepts(sessionID) else { return }
        viewModel.message = message
    }

    /// The design removes the visible provider badge (DESIGN.md §12); the fallback
    /// provider stays available to VoiceOver and in history.
    func showProviderBadge(_ label: String, sessionID: UUID? = nil) {
        guard accepts(sessionID) else { return }
        viewModel.providerBadge = label
    }

    /// 已插入 N 字. Called from the dispatch callback after the Unicode events have
    /// been posted; the swap happens on the next main-loop turn so the callback
    /// returns as quickly as the previous immediate `orderOut` did.
    func showInserted(characterCount: Int, notice: String? = nil, sessionID: UUID) {
        guard accepts(sessionID) else { return }
        dismissTask?.cancel()
        dismissTask = nil
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.accepts(sessionID),
                      self.presentationGeneration == generation else { return }
                self.viewModel.insertedCharacterCount = characterCount
                self.viewModel.insertedNotice = notice
                self.present(
                    sessionID: sessionID,
                    mode: .success,
                    message: [String(localized: "已插入 \(characterCount, format: .number.grouping(.never)) 字"), notice].compactMap { $0 }.joined(separator: String(localized: "，")),
                    text: "",
                    level: 0,
                    anchor: nil
                )
                self.dismiss(
                    after: notice == nil ? Self.insertedVisibleSeconds : Self.insertedWithNoticeVisibleSeconds,
                    sessionID: sessionID
                )
            }
        }
    }

    func dismiss(sessionID: UUID? = nil) {
        guard accepts(sessionID) else { return }
        dismissTask?.cancel()
        dismissTask = nil
        presentationGeneration += 1
        setPointerPassThrough(interactive: false)
        if let panel {
            panel.orderOut(nil)
            Self.settle(panel, alpha: 1, origin: panel.frame.origin)
        }
        levelMeter.reset()
        if sessionID == nil || activeSessionID == sessionID { activeSessionID = nil }
    }

    func dismiss(after seconds: TimeInterval, sessionID: UUID? = nil) {
        guard accepts(sessionID) else { return }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard let self, self.accepts(sessionID) else { return }
            self.fadeOut(sessionID: sessionID)
        }
    }

    private func accepts(_ sessionID: UUID?) -> Bool {
        guard let sessionID else { return true }
        return activeSessionID == sessionID
    }

    // MARK: - Show / hide motion (DESIGN.md §8: opacity + 4pt rise, ≤ 200ms ease-out)

    private func reveal(_ panel: NSPanel) {
        presentationGeneration += 1
        let target = panel.frame.origin
        guard !panel.isVisible else {
            Self.settle(panel, alpha: 1, origin: target)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Self.settle(panel, alpha: 0, origin: reduceMotion ? target : CGPoint(x: target.x, y: target.y - 4))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrameOrigin(target) }
        }
    }

    /// Jumps to a final alpha/origin, superseding any fade or rise still in flight.
    private static func settle(_ panel: NSPanel, alpha: CGFloat, origin: CGPoint) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.animator().alphaValue = alpha
            panel.animator().setFrameOrigin(origin)
        }
    }

    private func fadeOut(sessionID: UUID?) {
        guard let panel, panel.isVisible else {
            dismiss(sessionID: sessionID)
            return
        }
        presentationGeneration += 1
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss(sessionID: sessionID)
            }
        })
    }

    // MARK: - Pointer pass-through

    /// The panel is the visible surface plus a 14pt transparent shadow margin.
    /// Only the surface may take clicks: everywhere else the click must reach
    /// the app underneath. AppKit cannot make part of a window click-through,
    /// so the whole panel ignores the mouse except while the pointer is over
    /// the surface of an interactive state (已取消可撤销 / 失败 / 预览).
    /// The panel never becomes key, so following the pointer cannot take
    /// keyboard focus from the target app.
    private func setPointerPassThrough(interactive: Bool) {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        guard let panel else { return }
        guard interactive else {
            panel.ignoresMouseEvents = true
            return
        }
        updatePointerPassThrough()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerPassThrough() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerPassThrough() }
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    private func updatePointerPassThrough() {
        guard let panel else { return }
        let overSurface = panel.isVisible
            && Self.surfaceRect(panelFrame: panel.frame).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == overSurface {
            panel.ignoresMouseEvents = !overSurface
        }
    }

    /// The visible capsule/card in screen coordinates.
    static func surfaceRect(panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: VVMac.shadowInset, dy: VVMac.shadowInset)
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NonActivatingOverlayPanel(
            contentRect: CGRect(origin: .zero, size: preferredSize(for: .listening)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        // AppKit's utility window animation made this status linger after
        // insertion had already completed, so the system animation stays off;
        // the short fade in `reveal`/`fadeOut` is ours and interruptible.
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let hosting = OverlayHostingView(rootView: OverlayContentView(viewModel: viewModel, meter: levelMeter))
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        return panel
    }

    /// Panel size = visual surface + the transparent shadow margin on every side.
    private func preferredSize(for mode: OverlayMode) -> CGSize {
        let inset = VVMac.shadowInset * 2
        switch mode {
        case .preview:
            return CGSize(width: 520 + inset, height: 160 + inset)
        case .listening, .finalizing:
            // Constant on the recording-start path: no SwiftUI layout pass between the
            // hotkey and the panel appearing. Wide enough for a "00:00" timer; the pill
            // draws at its own width, centred, so the extra is transparent margin.
            let note = mode == .listening && viewModel.escapeCancelUnavailable ? Self.escapeNoteWidth : 0
            // "识别中" fits inside 116 (pill ≈ 109pt); the English label is wider, so the
            // finalizing width never drops below the pill's own measured width.
            let width = mode == .finalizing ? max(116, Self.finalizingPillWidth) : 116 + note
            return CGSize(width: width + inset, height: VVMac.pillHeight + inset)
        case .success, .failure, .cancelPending:
            guard let hostingView else {
                return CGSize(width: 96 + inset, height: VVMac.pillHeight + inset)
            }
            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            return CGSize(
                width: ceil(max(fitting.width, VVMac.pillHeight + inset)),
                height: VVMac.pillHeight + inset
            )
        }
    }

    /// Places the visible surface where the previous overlay sat (bottom centre, or
    /// beside the caret), then offsets the panel by the shadow margin.
    private func position(_ panel: NSPanel, mode: OverlayMode, anchor: CGRect?) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let inset = VVMac.shadowInset
        let panelSize = panel.frame.size
        let size = CGSize(width: panelSize.width - inset * 2, height: panelSize.height - inset * 2)
        func place(_ origin: CGPoint) {
            Self.settle(panel, alpha: panel.alphaValue, origin: CGPoint(x: origin.x - inset, y: origin.y - inset))
        }
        if let anchor, let converted = convertAXRectToAppKit(anchor) {
            let center = CGPoint(x: converted.midX, y: converted.midY)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                var x = converted.midX - size.width / 2
                var y: CGFloat
                if converted.height > visible.height * 0.5 {
                    // Some terminal accessibility trees expose their entire
                    // full-screen pane instead of a caret rectangle. Keep all
                    // overlay modes beside the prompt area at the bottom.
                    y = visible.minY + 18
                } else if mode == .preview || mode == .failure {
                    y = converted.minY - size.height - 12
                    if y < visible.minY + 8 {
                        y = converted.maxY + 12
                    }
                } else {
                    y = converted.minY - size.height - 8
                    if y < visible.minY + 8 {
                        y = converted.maxY + 8
                    }
                }
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
                y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
                place(CGPoint(x: x, y: y))
                return
            }
        }

        let fallbackScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let visible = fallbackScreen?.visibleFrame ?? visibleFrames[0]
        place(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 18
        ))
    }

    private func convertAXRectToAppKit(_ rect: CGRect) -> CGRect? {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        // AX uses Quartz coordinates (origin at the top-left of the primary
        // display); AppKit uses a bottom-left origin. Using the desktop's
        // highest screen edge breaks displays arranged above the primary.
        let primaryTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY
            ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryTop - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Never key, never main: clicking 撤销 or a preview button must not move
/// keyboard focus away from the app the text is going into.
private final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that only hit-tests the visible surface and handles the first
/// click itself, since the panel never becomes key.
final class OverlayHostingView: NSHostingView<OverlayContentView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.insetBy(dx: VVMac.shadowInset, dy: VVMac.shadowInset).contains(local) else {
            return nil
        }
        return super.hitTest(point)
    }
}
