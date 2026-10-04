import Speech
import SwiftUI
import UIKit

/// Connection-test results shared by the settings list and the key pages.
@MainActor
final class ConnectionStatusStore: ObservableObject {
    static let shared = ConnectionStatusStore()
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var testing: Set<String> = []

    func test(_ providerID: String) {
        guard !testing.contains(providerID) else { return }
        testing.insert(providerID)
        results[providerID] = nil
        let started = Date()
        Task { @MainActor in
            let message = await ConnectionTester.test(providerID: providerID)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            results[providerID] = message == "连接正常" ? "连接正常 · 往返 \(ms) ms" : message
            testing.remove(providerID)
        }
    }
}

// MARK: - Display model

struct SettingsContent: Equatable {
    var sonioxSaved = false
    var aliyunSaved = false
    var sonioxStatus: String?
    var aliyunStatus: String?
    var region = ""
    var idleTimeout = ""
    var maximumLength = ""
    var mixWithOthers = true
    var autoReturn = true
    /// False in a build without the private return path: no switch.
    var autoReturnAvailable = HostReturnCoordinator.isAvailable
    var keyboardSeen = false
    var version = ""
    var device = ""
    /// On-device recognition: in use when neither key is saved.
    var localInUse = false
    var localStatus = ""
    var localReady = false
    var keyFooter = "两把 Key 都只存在本机钥匙串。都不填时用 iPhone 自带的本机识别：不联网，准确率不如云端，人名、术语和中英混说尤其明显。"
}

/// Pickers and actions the screen needs; menus are built from these.
struct SettingsActions {
    var back: () -> Void = {}
    var openSoniox: () -> Void = {}
    var openAliyun: () -> Void = {}
    var openLocal: () -> Void = {}
    var regions: [(String, () -> Void)] = []
    var idleTimeouts: [(String, () -> Void)] = []
    var maximumLengths: [(String, () -> Void)] = []
    var setMixWithOthers: (Bool) -> Void = { _ in }
    var setAutoReturn: (Bool) -> Void = { _ in }
    var openSystemSettings: () -> Void = {}
}

// MARK: - Screen

/// Settings (screens/app-settings): grouped cards on `bg/raised`, radius 14,
/// footnote headers and footers indented 32.
struct SettingsScreen: View {
    let content: SettingsContent
    let actions: SettingsActions

    var body: some View {
        VVPage(title: "设置", back: actions.back) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header("识别服务", first: true)
                    group {
                        Button(action: actions.openSoniox) {
                            VVCell(title: "Soniox", subtitle: "主引擎" + (content.sonioxStatus.map { " · " + $0 } ?? "")) {
                                VVCellValue(text: content.sonioxSaved ? "已保存" : "未设置", check: content.sonioxSaved)
                                VVChevron()
                            }
                        }
                        .buttonStyle(.plain)
                        divider
                        Button(action: actions.openAliyun) {
                            VVCell(title: "百炼", subtitle: "热备" + (content.aliyunStatus.map { " · " + $0 } ?? "")) {
                                VVCellValue(text: content.aliyunSaved ? "已保存" : "未设置", check: content.aliyunSaved)
                                VVChevron()
                            }
                        }
                        .buttonStyle(.plain)
                        divider
                        menuCell("百炼区域", value: content.region, options: actions.regions)
                        divider
                        Button(action: actions.openLocal) {
                            VVCell(title: "本机识别", subtitle: content.localInUse ? "正在使用 · 准确率不如云端" : "两把 Key 都没有时使用") {
                                VVCellValue(text: content.localStatus, check: content.localReady)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    footer(content.keyFooter)

                    header("会话与录音")
                    group {
                        menuCell("会话空闲后结束", value: content.idleTimeout, options: actions.idleTimeouts)
                        divider
                        menuCell("单次最长时长", value: content.maximumLength, options: actions.maximumLengths)
                        divider
                        VVCell(title: "录音时不打断其他音频") {
                            Toggle("", isOn: Binding(get: { content.mixWithOthers }, set: actions.setMixWithOthers))
                                .labelsHidden()
                                // The mockup's switch is 31 tall; keep the row at 51.
                                .frame(minHeight: 31)
                        }
                        if content.autoReturnAvailable {
                            divider
                            VVCell(title: "录音开始后自动返回原 App") {
                                Toggle("", isOn: Binding(get: { content.autoReturn }, set: actions.setAutoReturn))
                                    .labelsHidden()
                                    .frame(minHeight: 31)
                            }
                        }
                    }
                    footer(content.autoReturnAvailable
                        ? "会话期间麦克风在后台待命，键盘上点麦克风不用跳转；代价是系统的麦克风指示点常亮和额外耗电。从键盘跳来录音时，开始录音后自动回到刚才的 App；认不出是哪个 App 时，停在返回提示页。"
                        : "会话期间麦克风在后台待命，键盘上点麦克风不用跳转；代价是系统的麦克风指示点常亮和额外耗电。从键盘跳来录音时，开始录音后点左上角的 ◀ 回到刚才的 App。")

                    header("键盘")
                    group {
                        VVCell(title: "\(MobileIdentity.displayName) 键盘", subtitle: content.keyboardSeen ? "已添加 · 已允许完全访问" : "还没在输入框里用过") {
                            if content.keyboardSeen { VVCellValue(text: "", check: true) }
                        }
                        divider
                        Button(action: actions.openSystemSettings) {
                            VVCell(title: "打开系统设置") { VVChevron() }
                        }
                        .buttonStyle(.plain)
                    }
                    footer("完全访问只用于和主 App 交换待插入的文字与开始/结束指令。键盘本身不联网、不录音。")

                    header("关于")
                    group {
                        VVCell(title: "版本") { VVCellValue(text: content.version) }
                        divider
                        VVCell(title: "设备") { VVCellValue(text: content.device) }
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Zero-height divider drawn over the next cell's top edge (the
    /// mockup's `.cell + .cell:before` takes no layout space).
    private var divider: some View {
        Color.clear.frame(height: 0).overlay(alignment: .top) { HairlineDivider(leadingInset: 16) }
    }

    private func header(_ title: String, first: Bool = false) -> some View {
        Text(title)
            .vvText(.footnote)
            .foregroundStyle(VVColor.fgSecondary)
            .padding(.horizontal, 32)
            .padding(.top, first ? 14 : 24)
            .padding(.bottom, 7)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .vvText(.footnote)
            .foregroundStyle(VVColor.fgSecondary)
            .padding(.horizontal, 32)
            .padding(.top, 7)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: VVMetric.radiusCard, style: .continuous).fill(VVColor.bgRaised))
            .clipShape(RoundedRectangle(cornerRadius: VVMetric.radiusCard, style: .continuous))
            .padding(.horizontal, 16)
    }

    private func menuCell(_ title: String, value: String, options: [(String, () -> Void)]) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0, action: option.1)
            }
        } label: {
            VVCell(title: title) {
                VVCellValue(text: value)
                VVChevron()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Container

struct MobileSettingsView: View {
    @EnvironmentObject private var dictation: DictationController
    @ObservedObject private var settings = DictationController.shared.settings
    @ObservedObject private var connection = ConnectionStatusStore.shared
    let navigate: (AppRoute) -> Void
    let back: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var sonioxSaved = MobileEnvironment.keychain.contains(.soniox)
    @State private var aliyunSaved = MobileEnvironment.keychain.contains(.aliyun)
    @State private var keyboardSeen = KeyboardPresence.lastSeen(directory: MobileEnvironment.sharedDirectory) != nil
    @State private var speechAuthorization = OnDeviceSpeech.authorization
    @State private var analyzerReady = false

    private static let maximumLengths = [60, 180, 300, 600]

    var body: some View {
        SettingsScreen(content: content, actions: actions)
            .onAppear(perform: refresh)
            .task { analyzerReady = await OnDeviceSpeech.analyzerModelInstalled() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        sonioxSaved = MobileEnvironment.keychain.contains(.soniox)
        aliyunSaved = MobileEnvironment.keychain.contains(.aliyun)
        keyboardSeen = KeyboardPresence.lastSeen(directory: MobileEnvironment.sharedDirectory) != nil
        speechAuthorization = OnDeviceSpeech.authorization
    }

    /// Asks for the speech permission (the system settings page once it was
    /// refused) and fetches the iOS 26 model.
    private func openLocal() {
        Task { @MainActor in
            let status = await OnDeviceSpeech.requestAuthorization()
            speechAuthorization = status
            if status == .denied || status == .restricted,
               let url = URL(string: UIApplication.openSettingsURLString) {
                await UIApplication.shared.open(url)
            }
            analyzerReady = await OnDeviceSpeech.prepareAnalyzerModel()
        }
    }

    private var localStatus: (text: String, ready: Bool) {
        if analyzerReady { return ("可用", true) }
        switch speechAuthorization {
        case .authorized:
            return OnDeviceSpeech.recognizerSupportsOnDevice ? ("可用", true) : ("本机不支持", false)
        case .notDetermined: return ("点此允许", false)
        default: return ("未允许", false)
        }
    }

    private var content: SettingsContent {
        var c = SettingsContent()
        c.sonioxSaved = sonioxSaved
        c.aliyunSaved = aliyunSaved
        c.sonioxStatus = connection.testing.contains(MobileEnvironment.sonioxProviderID) ? "测试中…" : connection.results[MobileEnvironment.sonioxProviderID]
        c.aliyunStatus = connection.testing.contains(MobileEnvironment.aliyunProviderID) ? "测试中…" : connection.results[MobileEnvironment.aliyunProviderID]
        c.region = SettingsFormat.region(settings.aliyunRegion)
        c.idleTimeout = dictation.idleTimeout.title
        c.maximumLength = SettingsFormat.minutes(settings.maximumUtteranceSeconds)
        c.mixWithOthers = dictation.mixWithOthers
        c.autoReturn = dictation.autoReturnToHost
        c.localInUse = !sonioxSaved && !aliyunSaved
        (c.localStatus, c.localReady) = localStatus
        c.keyboardSeen = keyboardSeen
        c.version = "\(MobileEnvironment.appVersion ?? "—") (\(MobileEnvironment.buildNumber ?? "—"))"
        c.device = "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
        return c
    }

    private var actions: SettingsActions {
        SettingsActions(
            back: back,
            openSoniox: { navigate(.key(.soniox)) },
            openAliyun: { navigate(.key(.aliyun)) },
            openLocal: openLocal,
            regions: AliyunRegion.allCases.map { region in (region.displayName, { settings.aliyunRegion = region }) },
            idleTimeouts: SessionIdleTimeout.allCases.map { timeout in (timeout.title, { dictation.idleTimeout = timeout }) },
            maximumLengths: Self.maximumLengths.map { seconds in (SettingsFormat.minutes(seconds), { settings.maximumUtteranceSeconds = seconds }) },
            setMixWithOthers: { dictation.mixWithOthers = $0 },
            setAutoReturn: { dictation.autoReturnToHost = $0 },
            openSystemSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        )
    }
}

enum SettingsFormat {
    static func minutes(_ seconds: Int) -> String { seconds % 60 == 0 ? "\(seconds / 60) 分钟" : "\(seconds) 秒" }
    /// "华北2（北京）" reads as "北京" in the value column.
    static func region(_ region: AliyunRegion) -> String { region == .beijing ? "北京" : region.displayName }
}

// MARK: - Key page

/// One provider's key: paste, save, test. Keys stay in the keychain.
struct KeyEditView: View {
    let account: MobileKeychain.Account
    let back: () -> Void
    @ObservedObject private var connection = ConnectionStatusStore.shared
    @State private var draft = ""
    @State private var saved = false
    @State private var error: String?

    private var title: String { account == .soniox ? "Soniox" : "百炼" }
    private var providerID: String { account == .soniox ? MobileEnvironment.sonioxProviderID : MobileEnvironment.aliyunProviderID }

    var body: some View {
        VVPage(title: title, back: back) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    SecureField("", text: $draft, prompt: Text(saved ? "输入新 Key 以替换" : "粘贴 API Key").foregroundStyle(VVColor.fgTertiary))
                        .vvText(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存", action: save)
                        .buttonStyle(VVPillStyle(prominent: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: VVMetric.radiusTall, style: .continuous).fill(VVColor.bgSunken))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                Text(error ?? (saved ? "已保存在本机钥匙串。" : "还没有保存 Key。"))
                    .vvText(.footnote)
                    .foregroundStyle(VVColor.fgSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                VStack(spacing: 0) {
                    HairlineDivider(leadingInset: 16)
                    Button { connection.test(providerID) } label: {
                        VVCell(title: "连接测试", subtitle: connection.testing.contains(providerID) ? "测试中…" : connection.results[providerID]) {
                            VVChevron()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!saved || connection.testing.contains(providerID))
                    .opacity(saved ? 1 : 0.4)
                }
                .padding(.top, 24)
            }
        }
        .onAppear { saved = MobileEnvironment.keychain.contains(account) }
    }

    private func save() {
        do {
            try MobileEnvironment.keychain.set(draft, for: account)
            draft = ""
            error = nil
            saved = MobileEnvironment.keychain.contains(account)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
