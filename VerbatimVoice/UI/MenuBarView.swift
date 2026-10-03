import AppKit
import SwiftUI

/// Model-bound wrapper: maps AppModel state onto the menu panel's plain inputs.
struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MenuPanelContent(
            state: panelState,
            actions: MenuPanelActions(
                end: { model.endDictation() },
                cancel: { model.cancelDictation() },
                undoCancel: { model.undoCancel() },
                start: { model.toggleDictation() },
                showHistory: { model.showSettingsWindow() },
                checkAccessibility: { model.requestAccessibilityPermission() },
                checkInputMonitoring: { model.requestInputMonitoringPermission() },
                openDataFolder: { model.openDataFolder() },
                quit: { NSApplication.shared.terminate(nil) },
                retryProvider: { model.retryUnavailableProvider() },
                openInputMonitoringSettings: { model.openInputMonitoringSettings() },
                showOnboarding: { model.showOnboarding() }
            )
        )
    }

    private var panelState: MenuPanelState {
        MenuPanelState(
            phase: phase,
            title: stateTitle,
            detail: statusDetail,
            recordingStartedAt: model.recordingStartedAt,
            provisionalText: model.provisionalText,
            engine: model.settings.primaryProvider.shortName + (primaryReady ? "" : " · 未配置"),
            insertion: model.accessibilityTrusted ? "辅助功能 · 可用" : "辅助功能 · 需检查",
            microphone: model.microphoneReady ? "录音中" : "按需释放",
            error: model.lastError,
            outage: model.providerOutageStatus.map {
                MenuPanelState.Outage(
                    message: $0.message,
                    actionTitle: $0.actionTitle,
                    actionURL: $0.actionURL,
                    probing: $0.probing
                )
            },
            escapeCancelUnavailable: !model.escapeCancelAvailable
        )
    }

    private var phase: MenuPanelState.Phase {
        switch model.state {
        case .starting, .listening: return .capturing
        case .cancelPending: return .cancelPending
        case .finalizing, .inserting: return .busy
        default: return .idle
        }
    }

    private var stateTitle: String {
        switch model.state {
        case .starting: return "正在启动"
        case .listening: return "正在听"
        case .cancelPending: return "已取消"
        case .finalizing, .inserting: return "识别中"
        case .preview: return "待插入"
        case .failed: return "没插入"
        case .idle: return "待命"
        }
    }

    private var primaryReady: Bool {
        switch model.settings.primaryProvider {
        case .localSenseVoice: return model.localModelReady
        case .aliyun: return model.aliyunKeyConfigured
        case .soniox: return model.sonioxKeyConfigured
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .starting, .listening:
            return model.escapeCancelAvailable ? "再按一次右 Option 结束 · Esc 取消" : "再按一次右 Option 结束"
        case .cancelPending: return "5 秒内可以撤销；之后仍可从历史重新转写"
        case .finalizing, .inserting: return "正在选择结果并发送到输入框"
        case .preview, .failed: return model.statusMessage
        case .idle: return "右 Option 单击开始"
        }
    }
}

struct MenuPanelState {
    enum Phase { case idle, capturing, cancelPending, busy }
    var phase: Phase
    var title: String
    var detail: String
    var recordingStartedAt: Date?
    var provisionalText: String
    var engine: String
    var insertion: String
    var microphone: String
    var error: String?
    /// A cloud provider that cannot be used (balance, key).
    var outage: Outage? = nil
    /// The Escape self-check failed: Input Monitoring is missing or stale.
    var escapeCancelUnavailable = false

    struct Outage {
        var message: String
        var actionTitle: String
        var actionURL: URL
        var probing = false
    }
}

struct MenuPanelActions {
    var end: () -> Void
    var cancel: () -> Void
    var undoCancel: () -> Void
    var start: () -> Void
    var showHistory: () -> Void
    var checkAccessibility: () -> Void
    var checkInputMonitoring: () -> Void
    var openDataFolder: () -> Void
    var quit: () -> Void
    var retryProvider: () -> Void = {}
    var openInputMonitoringSettings: () -> Void = {}
    var showOnboarding: () -> Void = {}
}

/// Menu-bar panel (screens/mac-menu.png): 300pt wide, 13/18 text, one prominent button,
/// hairline-separated status row. The only hue is `stateRecording` on the header waveform
/// while capturing (dark appearance only; light draws it in fg/primary).
struct MenuPanelContent: View {
    let state: MenuPanelState
    let actions: MenuPanelActions
    /// Fixed clock for design snapshots; nil means live.
    var frozenNow: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let outage = state.outage {
                outageRow(outage)
                Hairline(color: VVMac.panelHairline)
            }

            if state.escapeCancelUnavailable {
                escapeCancelRow
                Hairline(color: VVMac.panelHairline)
            }

            header

            if !state.provisionalText.isEmpty {
                Text(state.provisionalText)
                    .font(.system(size: 13))
                    .lineHeight(19, fontSize: 13)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(VVMac.quoteFill, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
            }

            HStack(spacing: 8) {
                switch state.phase {
                case .capturing:
                    Button("结束并插入", action: actions.end)
                        .buttonStyle(VVButtonStyle(prominent: true))
                    Button("取消", action: actions.cancel)
                        .buttonStyle(VVButtonStyle())
                case .cancelPending:
                    Button("撤销取消", action: actions.undoCancel)
                        .buttonStyle(VVButtonStyle(prominent: true))
                    Text("音频会保留").foregroundStyle(VVColor.fgSecondary)
                case .busy:
                    Button("正在处理…") { }
                        .buttonStyle(VVButtonStyle())
                        .disabled(true)
                case .idle:
                    Button("开始录音", action: actions.start)
                        .buttonStyle(VVButtonStyle(prominent: true))
                }
                Spacer(minLength: 0)
            }

            Hairline(color: VVMac.panelHairline)

            HStack(alignment: .top, spacing: 18) {
                metaColumn("主引擎", value: state.engine)
                metaColumn("插入", value: state.insertion)
                metaColumn("麦克风", value: state.microphone)
            }

            if let error = state.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineLimit(2)
            }

            Hairline(color: VVMac.panelHairline)

            HStack {
                Button("打开历史…", action: actions.showHistory)
                    .buttonStyle(.plain)
                    .lineHeight(18, fontSize: 13)
                    .foregroundStyle(VVColor.fgSecondary)
                Spacer()
                Menu {
                    Button("检查辅助功能", action: actions.checkAccessibility)
                    Button("检查输入监控", action: actions.checkInputMonitoring)
                    Button("打开数据目录", action: actions.openDataFolder)
                    Button("打开入门引导…", action: actions.showOnboarding)
                    Divider()
                    Button("退出 \(AppIdentity.displayName)", action: actions.quit)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VVColor.fgSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("更多")
            }
        }
        .font(VVMac.menuFont)
        .tracking(VVMac.menuTracking)
        .foregroundStyle(VVColor.fgPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: VVMac.menuWidth)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // A static glyph, not the live meter: this window can stay alive while
            // hidden, and live levels must not flow through AppModel observers.
            if state.phase == .capturing {
                StaticWaveform(levels: Self.speechShape, height: VVMac.waveformHeight, color: VVColor.stateRecording)
            } else {
                CollapsedWaveform(count: Self.speechShape.count, animated: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(state.title).fontWeight(.semibold).lineHeight(18, fontSize: 13)
                    if state.phase == .capturing, let startedAt = state.recordingStartedAt {
                        if let frozenNow {
                            Text(Self.elapsed(from: startedAt, to: frozenNow)).font(VVMac.numberFont.monospacedDigit())
                        } else {
                            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                Text(Self.elapsed(from: startedAt, to: context.date)).font(VVMac.numberFont.monospacedDigit())
                            }
                        }
                    }
                }
                Text(state.detail)
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineLimit(2)
                    .lineHeight(18, fontSize: 13)
            }
            Spacer(minLength: 0)
        }
    }

    /// Fixed 12-bar profile for the header glyph: the mockup's bars (kit.js seed 9),
    /// pre-inverted through the waveform's level curve.
    static let speechShape: [CGFloat] = [0.0354, 0.4875, 0.4922, 0.3865, 0.1359, 0, 0, 0, 0, 0, 0.0372, 0.0984]

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "Soniox 余额不足，已改用阿里云" with the two actions that resolve it.
    /// Same type ramp and greys as the header; no new hue.
    private func outageRow(_ outage: MenuPanelState.Outage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(outage.message)
                .fontWeight(.semibold)
                .lineLimit(2)
                .lineHeight(18, fontSize: 13)
            HStack(spacing: 14) {
                // A plain button, not `Link`: Link would tint the text with the accent hue.
                Button(outage.actionTitle) { NSWorkspace.shared.open(outage.actionURL) }
                    .buttonStyle(.plain)
                Button(outage.probing ? "正在检查…" : "重试", action: actions.retryProvider)
                    .buttonStyle(.plain)
                    .disabled(outage.probing)
            }
            .foregroundStyle(VVColor.fgSecondary)
            .lineHeight(18, fontSize: 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Same type ramp as the outage row: what is broken, how to fix it, one action.
    private var escapeCancelRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Esc 取消不可用：需要重新授权输入监控")
                .fontWeight(.semibold)
                .lineLimit(2)
                .lineHeight(18, fontSize: 13)
            Text("在列表里删除 \(AppIdentity.displayName) 后重新添加")
                .foregroundStyle(VVColor.fgSecondary)
                .lineLimit(2)
                .lineHeight(18, fontSize: 13)
            Button("打开设置", action: actions.openInputMonitoringSettings)
                .buttonStyle(.plain)
                .foregroundStyle(VVColor.fgSecondary)
                .lineHeight(18, fontSize: 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaColumn(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(VVColor.fgSecondary)
                .lineHeight(16, fontSize: 11)
            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
                .lineHeight(16, fontSize: 12)
        }
        .fixedSize()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Tear the console down when closed. A hidden-but-retained hosting view
    /// kept observing AppModel and re-rendered on every published change for
    /// days, accumulating SwiftUI observation state and slowing the main thread.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.delegate = nil
        closing.contentViewController = nil
        window = nil
    }

    /// Window chrome for the console (also used by the design snapshot).
    static func makeConsoleWindow(contentViewController: NSViewController) -> NSWindow {
        let created = NSWindow(
            contentRect: CGRect(origin: .zero, size: VVMac.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = AppIdentity.displayName
        // Sidebar layout from screens/mac-history.png: the sidebar draws the title,
        // and an empty unified toolbar gives the 52pt title area that centres the
        // traffic lights on the title line.
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.titlebarSeparatorStyle = .none
        created.toolbar = NSToolbar(identifier: "\(AppIdentity.dataDirectoryName).HistoryToolbar")
        created.toolbarStyle = .unified
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.hidesOnDeactivate = false
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.contentViewController = contentViewController
        created.setContentSize(VVMac.windowSize)
        created.minSize = CGSize(width: 720, height: 480)
        return created
    }

    func show(model: AppModel) {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let created = Self.makeConsoleWindow(
                contentViewController: NSHostingController(rootView: SettingsView(model: model))
            )
            created.setFrameAutosaveName("\(AppIdentity.dataDirectoryName).SettingsWindow")
            created.delegate = self
            self.window = created
            window = created
        }

        if !window.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(CGPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
