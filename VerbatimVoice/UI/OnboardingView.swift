import AppKit
import AVFoundation
import Combine
import SwiftUI

enum MicrophonePermission: Equatable {
    case notDetermined
    case granted
    case denied

    static var current: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

/// What the first-run window shows. Plain values, so design snapshots can fake them.
struct OnboardingState: Equatable {
    var microphone: MicrophonePermission
    var accessibility: Bool
    var inputMonitoring: Bool
    /// Input Monitoring was granted while this window was open; the hotkey tap only
    /// sees it after a restart.
    var inputMonitoringNeedsRestart: Bool
    var model: LocalModelStore.Status
    /// A cloud key is saved, so the local model is optional.
    var cloudKeyConfigured: Bool
    var triedText: String
    var triggerKeyName = TriggerKey.rightOption.displayName

    var modelReady: Bool {
        switch model {
        case .bundled, .installed: return true
        default: return false
        }
    }
    var permissionsComplete: Bool { microphone == .granted && accessibility && inputMonitoring }
    /// The first step that still needs the user; only its button is filled.
    var currentStep: Int? {
        if microphone != .granted { return 0 }
        if !accessibility { return 1 }
        if !inputMonitoring || inputMonitoringNeedsRestart { return 2 }
        if !modelReady && !cloudKeyConfigured { return 3 }
        if triedText.isEmpty { return 4 }
        return nil
    }
    var allDone: Bool { permissionsComplete && (modelReady || cloudKeyConfigured) && !triedText.isEmpty }
}

struct OnboardingActions {
    var requestMicrophone: () -> Void = {}
    var openMicrophoneSettings: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var requestInputMonitoring: () -> Void = {}
    var restart: () -> Void = {}
    var downloadModel: () -> Void = {}
    var cancelModelDownload: () -> Void = {}
    var finish: () -> Void = {}
}

/// Model-bound wrapper: polls the three permissions once a second while the window is open.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var localModels: LocalModelStore
    @State private var triedText = ""
    @State private var inputMonitoringMissingAtOpen: Bool
    @State private var baselineRecordID: UUID?
    let finish: () -> Void
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: AppModel, finish: @escaping () -> Void) {
        self.model = model
        localModels = model.localModels
        self.finish = finish
        _inputMonitoringMissingAtOpen = State(initialValue: !HotkeyMonitor.hasInputMonitoringAccess)
        _baselineRecordID = State(initialValue: model.recentHistory.first?.id)
    }

    var body: some View {
        OnboardingContent(
            state: OnboardingState(
                microphone: model.microphonePermission,
                accessibility: model.accessibilityTrusted,
                inputMonitoring: model.inputMonitoringTrusted,
                inputMonitoringNeedsRestart: inputMonitoringMissingAtOpen && model.inputMonitoringTrusted,
                model: localModels.status,
                cloudKeyConfigured: model.sonioxKeyConfigured || model.aliyunKeyConfigured,
                triedText: triedText,
                triggerKeyName: model.settings.triggerKey.displayName
            ),
            triedText: $triedText,
            actions: OnboardingActions(
                requestMicrophone: { model.requestMicrophonePermission() },
                openMicrophoneSettings: { model.openPrivacySettings(pane: "Privacy_Microphone") },
                requestAccessibility: { model.requestAccessibilityForOnboarding() },
                requestInputMonitoring: { model.requestInputMonitoringForOnboarding() },
                restart: { model.relaunch() },
                downloadModel: { localModels.startDownload() },
                cancelModelDownload: { localModels.cancelDownload() },
                finish: finish
            )
        )
        .onReceive(poll) { _ in model.refreshPermissions() }
        // A finished dictation puts its text in the box even when the app decided to
        // preview or copy instead of typing into its own window.
        .onChange(of: model.recentHistory.first?.id) { _, newID in
            guard newID != baselineRecordID, triedText.isEmpty,
                  let text = model.recentHistory.first?.insertedText, !text.isEmpty else { return }
            triedText = text
        }
    }
}

/// First-run window: microphone, Accessibility, Input Monitoring, local model, a test sentence.
/// 480pt wide, gray tokens only (docs/DESIGN.md §1.3), 13/18 text, one prominent button.
struct OnboardingContent: View {
    let state: OnboardingState
    @Binding var triedText: String
    var actions = OnboardingActions()
    @FocusState private var testFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("开始之前")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(AppIdentity.displayName) 需要五步准备。每一步都在这台 Mac 上完成，之后可以从菜单重新打开这个窗口。")
                    .font(.system(size: 13))
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineHeight(18, fontSize: 13)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)

            Hairline()
            step(
                done: state.microphone == .granted,
                title: String(localized: "麦克风"),
                detail: state.microphone == .denied
                    ? String(localized: "已被拒绝。到系统设置 → 隐私与安全性 → 麦克风里打开 \(AppIdentity.displayName)。")
                    : String(localized: "只在你按下\(state.triggerKeyName)后录音，结束后立即释放。")
            ) {
                switch state.microphone {
                case .notDetermined: Button("允许", action: actions.requestMicrophone).buttonStyle(VVButtonStyle(prominent: state.currentStep == 0))
                case .denied: Button("打开系统设置", action: actions.openMicrophoneSettings).buttonStyle(VVButtonStyle(prominent: state.currentStep == 0))
                case .granted: EmptyView()
                }
            }
            Hairline()
            step(
                done: state.accessibility,
                title: String(localized: "辅助功能"),
                detail: String(localized: "用来把识别出的文字插入当前输入框。在列表里打开 \(AppIdentity.displayName)，授权后这里会自动打勾。")
            ) {
                if !state.accessibility {
                    Button("打开系统设置", action: actions.requestAccessibility).buttonStyle(VVButtonStyle(prominent: state.currentStep == 1))
                }
            }
            Hairline()
            step(
                done: state.inputMonitoring,
                title: String(localized: "输入监控"),
                detail: state.inputMonitoringNeedsRestart
                    ? String(localized: "已授权。重启 \(AppIdentity.displayName) 后\(state.triggerKeyName)才会生效。")
                    : String(localized: "用来监听\(state.triggerKeyName)与 Esc。授权后可能需要重启一次。")
            ) {
                if state.inputMonitoringNeedsRestart {
                    Button("立即重启", action: actions.restart).buttonStyle(VVButtonStyle(prominent: state.currentStep == 2))
                } else if !state.inputMonitoring {
                    Button("打开系统设置", action: actions.requestInputMonitoring).buttonStyle(VVButtonStyle(prominent: state.currentStep == 2))
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                step(
                    done: state.modelReady || state.cloudKeyConfigured,
                    title: String(localized: "本地模型"),
                    detail: state.cloudKeyConfigured && !state.modelReady
                        ? String(localized: "已配置云端密钥，本地模型可以之后再装。")
                        : String(localized: "语音识别在这台 Mac 上完成，声音不会上传。")
                ) { EmptyView() }
                if !state.modelReady {
                    LocalModelStatusRow(
                        status: state.model,
                        showsTitle: false,
                        prominent: state.currentStep == 3,
                        onDownload: actions.downloadModel,
                        onCancel: actions.cancelModelDownload
                    )
                    .padding(.leading, 28)
                    .padding(.top, -6)
                    .padding(.bottom, 12)
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                step(
                    done: !state.triedText.isEmpty,
                    title: String(localized: "试说一句"),
                    detail: String(localized: "点进下面的框，按\(state.triggerKeyName)说话，再按一次结束，看到文字就完成了。")
                ) { EmptyView() }
                TextField("在这里说话", text: $triedText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...3)
                    .focused($testFieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(VVMac.quoteFill, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
                    .padding(.leading, 28)
                    .padding(.top, -6)
                    .padding(.bottom, 12)
            }
            Hairline()

            HStack {
                Text(footnote)
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
                Spacer(minLength: 12)
                Button(action: actions.finish) { Text(state.allDone ? String(localized: "完成") : String(localized: "稍后再说")) }
                    .buttonStyle(VVButtonStyle(prominent: state.allDone))
            }
            .padding(.top, 14)
        }
        .font(.system(size: 13))
        .tracking(VVMac.menuTracking)
        .foregroundStyle(VVColor.fgPrimary)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 480, alignment: .topLeading)
        .background(VVColor.bgCanvas)
    }

    private var footnote: String {
        state.allDone ? String(localized: "都准备好了") : String(localized: "可以跳过，之后从菜单栏图标 → ⋯ → 打开入门引导")
    }

    private func step<Trailing: View>(
        done: Bool,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StepMark(done: done)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).lineHeight(18, fontSize: 13)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineHeight(17, fontSize: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 12)
    }
}

/// Open ring while pending, filled disc with a check when done. Shape, not colour,
/// carries the state (docs/DESIGN.md §1.5).
private struct StepMark: View {
    let done: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if done {
                Circle().fill(VVColor.fillProminent)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(VVColor.fgInverse)
            } else {
                Circle().strokeBorder(VVColor.lineStrong, lineWidth: VVMetric.hairline(displayScale) * 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(done ? String(localized: "已完成") : String(localized: "未完成"))
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    /// `onClose` runs once when the window goes away by any route (button or close box).
    func show(model: AppModel, onClose: @escaping () -> Void) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onClose = onClose
        // Fixed size: letting the hosting view size the window made AppKit loop on
        // constraint updates when the rows changed height. The scroll view covers a
        // long error message.
        let content = ScrollView {
            OnboardingView(model: model, finish: { [weak self] in self?.window?.close() })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 480, height: 660)
        .background(VVColor.bgCanvas)
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let created = NSWindow(contentViewController: hosting)
        created.styleMask = [.titled, .closable, .fullSizeContentView]
        created.setContentSize(CGSize(width: 480, height: 660))
        created.title = AppIdentity.displayName
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        created.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? VVColor.hex(0x08090A) : VVColor.hex(0xFFFFFF)
        }
        created.delegate = self
        created.center()
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.delegate = nil
        closing.contentViewController = nil
        window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
