#if DEBUG
import AppKit
import SwiftUI

/// Design snapshots for comparing the implementation with the design screens (see docs/DESIGN.md).
///
/// Inert unless the process is started by hand with `VERBATIM_DESIGN_PREVIEW` set
/// (`all`, or a comma list of `overlay,desktop,type,menu,history,profile,onboarding,menubar`). `desktop` composites
/// the pill over wallpaper bands given in `VERBATIM_DESIGN_PREVIEW_DESKTOPS=light.png,dark.png`
/// (1100×420 @2x each); `type` renders the digit treatments next to Chinese text. In that case it renders the
/// real views with fixed fake data into PNGs (`VERBATIM_DESIGN_PREVIEW_OUT`, default
/// /private/tmp/verbatim-design-preview) and exits the process. It runs from `App.init`,
/// before `AppModel` exists, so no hotkey, event tap, microphone, history or TCC path is
/// touched. Rendering uses `cacheDisplay`, which needs no screen-recording permission.
@MainActor
enum DesignPreview {
    static func runAndExitIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["VERBATIM_DESIGN_PREVIEW"], !request.isEmpty else { return }
        let output = URL(fileURLWithPath: environment["VERBATIM_DESIGN_PREVIEW_OUT"] ?? "/private/tmp/verbatim-design-preview")
        let targets = Set(request.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let all = targets.contains("all")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var status: Int32 = 0
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if all || targets.contains("overlay") { try overlay(to: output); try overlayExtras(to: output) }
            if all || targets.contains("desktop") { try overlayOnDesktops(to: output) }
            if all || targets.contains("type") { try typeSpecimen(to: output) }
            if all || targets.contains("menu") { try menu(to: output) }
            if all || targets.contains("history") { try history(to: output) }
            if all || targets.contains("profile") { try profile(to: output) }
            if all || targets.contains("onboarding") { try onboarding(to: output) }
            if all || targets.contains("menubar") { try menuBarIcons(to: output) }
            if all || targets.contains("sizing") { sizingCheck() }
            print("design preview written to \(output.path)")
        } catch {
            FileHandle.standardError.write(Data("design preview failed: \(error)\n".utf8))
            status = 1
        }
        exit(status)
    }

    // MARK: - Overlay (screens/mac-overlay.html: 1100×420, light | dark)

    private static func overlay(to dir: URL) throws {
        let stage = HStack(spacing: 0) {
            overlayColumn(dark: false)
            overlayColumn(dark: true)
        }
        .frame(width: 1100, height: 420)
        // ImageRenderer, not cacheDisplay: the pill's shadow is a blur and its surface a
        // masked material, and the AppKit drawing path renders neither.
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mac-overlay.png"))
    }

    /// The pill over real wallpaper, through the preview backdrop path (a blurred copy of the
    /// band under each pill; the real app uses `.ultraThinMaterial`, which also lifts
    /// saturation slightly — this composite is the floor, not the ceiling, of translucency).
    private static func overlayOnDesktops(to dir: URL) throws {
        let env = ProcessInfo.processInfo.environment["VERBATIM_DESIGN_PREVIEW_DESKTOPS"] ?? ""
        let paths = env.split(separator: ",").map(String.init)
        guard paths.count == 2, let light = NSImage(contentsOfFile: paths[0]), let dark = NSImage(contentsOfFile: paths[1]) else {
            print("desktop preview skipped: set VERBATIM_DESIGN_PREVIEW_DESKTOPS=light.png,dark.png")
            return
        }
        let stage = HStack(spacing: 0) {
            desktopColumn(image: light, dark: false)
            desktopColumn(image: dark, dark: true)
        }
        .frame(width: 1100, height: 420)
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent("mac-overlay-desktop.png"))
    }

    private static func desktopColumn(image: NSImage, dark: Bool) -> some View {
        let size = CGSize(width: 550, height: 420)
        let backdrop = OverlayBackdropPreview(image: Image(nsImage: image), frame: CGRect(origin: .zero, size: size))
        return ZStack {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
            VStack(spacing: 22) {
                overlayPill(.listening)
                overlayPill(.finalizing)
                overlayPill(.success)
                overlayPill(.failure)
                Spacer(minLength: 0)
            }
            .padding(.top, 60)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: OverlayBackdropPreview.space)
        .environment(\.overlayBackdropPreview, backdrop)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    /// Digit treatments next to PingFang at the pill's 13pt, light and dark, for choosing by eye.
    private static func typeSpecimen(to dir: URL) throws {
        struct Row { let name: String; let font: Font; let tabular: Bool; let baseline: CGFloat }
        let rows: [Row] = [
            Row(name: "A 原状：13 Medium，tnum 全开", font: .system(size: 13, weight: .medium), tabular: true, baseline: 0),
            Row(name: "B 13 Regular，tnum 全开", font: .system(size: 13, weight: .regular), tabular: true, baseline: 0),
            Row(name: "C 13 Regular，只有计时 tnum，字数用比例数字", font: .system(size: 13, weight: .regular), tabular: false, baseline: 0),
            Row(name: "D 13 Regular，比例数字 + 基线 −0.5", font: .system(size: 13, weight: .regular), tabular: false, baseline: -0.5),
            Row(name: "E 13.5 Regular，比例数字", font: .system(size: 13.5, weight: .regular), tabular: false, baseline: 0),
            Row(name: "F SF Mono 12 Regular", font: .system(size: 12, weight: .regular, design: .monospaced), tabular: true, baseline: 0),
            Row(name: "G SF Rounded 13 Regular", font: .system(size: 13, weight: .regular, design: .rounded), tabular: false, baseline: 0),
        ]
        func sample(_ row: Row, dark: Bool) -> some View {
            let num = { (t: String) -> Text in
                let base = Text(t).font(row.tabular ? row.font.monospacedDigit() : row.font)
                return row.baseline == 0 ? base : base.baselineOffset(row.baseline)
            }
            let timer = Text("0:07").font(row.font.monospacedDigit())
            return VStack(alignment: .leading, spacing: 6) {
                Text(row.name).font(.system(size: 11)).foregroundStyle(VVColor.fgSecondary)
                HStack(spacing: 18) {
                    (Text("正在听 ") + timer)
                    (Text("已插入 ") + num("49") + Text(" 字"))
                    (Text("已取消 · ") + num("4") + Text(" 秒内可撤销"))
                    (Text("今天 ") + num("38") + Text(" 次 · P50 ") + num("0.55") + Text(" s"))
                    (Text("往返 ") + num("212") + Text(" ms"))
                }
                .font(row.font)
                .tracking(VVMac.pillTracking)
                .foregroundStyle(VVColor.fgPrimary)
            }
        }
        let stage = HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(rows.indices, id: \.self) { sample(rows[$0], dark: dark) }
                }
                .padding(24)
                .frame(width: 620, height: 420, alignment: .topLeading)
                .background(Color(nsColor: VVColor.hex(dark ? 0x1C1D1E : 0xF2F2F3)))
                .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent("mac-type-specimen.png"))
    }

    /// States the mockup does not draw: cancel-pending undo and the insertion preview card.
    private static func overlayExtras(to dir: URL) throws {
        let stage = HStack(alignment: .top, spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 18) {
                    overlayPill(.listening, escapeUnavailable: true)
                    overlayPill(.cancelPending)
                    overlayPill(.success, notice: "Soniox 余额不足，已改用阿里云")
                    overlayPill(.preview)
                }
                .padding(28)
                .frame(width: 600, height: 400, alignment: .topLeading)
                .background(Color(nsColor: VVColor.hex(dark ? 0x2A2B2E : 0xE9E9EB)))
                .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent("mac-overlay-extra.png"))
    }

    private static func overlayColumn(dark: Bool) -> some View {
        let label = { (text: String) in
            Text(text)
                .font(.system(size: 13))
                .tracking(-0.08)
                .foregroundStyle(Color(nsColor: VVColor.hex(dark ? 0x9D9EA0 : 0x5A5B5C)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
                .padding(.bottom, -14)
        }
        return VStack(spacing: 22) {
            label(dark ? "正在听 · 波形 + 计时（录音红只在波形上）" : "正在听 · 波形 + 计时（浅色不用红，波形为 fg/primary）")
            overlayPill(.listening)
            label("识别中 · 波形收成一条线并流动")
            overlayPill(.finalizing)
            label("已插入 · 实现：没有文字级撤销，只显示字数")
            overlayPill(.success)
            label("失败 · 原因（没有重试入口，录音在历史里可重新转写）")
            overlayPill(.failure)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .frame(width: 550, height: 420)
        .background(Color(nsColor: VVColor.hex(dark ? 0x2A2B2E : 0xE9E9EB)))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private static func overlayPill(_ mode: OverlayMode, notice: String? = nil, escapeUnavailable: Bool = false) -> some View {
        let model = OverlayViewModel(onCancel: {}, onUndoCancel: {}, onCopy: {}, onInsertCurrent: {}, onDismiss: {})
        model.escapeCancelUnavailable = escapeUnavailable
        let meter = OverlayLevelMeter()
        let now = Date()
        model.mode = mode
        model.animatesProgress = false
        switch mode {
        case .listening:
            model.recordingStartedAt = now.addingTimeInterval(-7.2)
            model.recordingEndedAt = now
            meter.load(mockLevels(count: 14, seed: 9).map(invertLevelCurve))
            model.message = "正在听"
        case .success:
            model.insertedCharacterCount = 49
            model.insertedNotice = notice
            model.message = "已插入 49 字"
        case .failure:
            model.message = "没插入 · 网络不通"
        case .cancelPending:
            model.cancelDeadline = now.addingTimeInterval(4.2)
            model.message = "已取消"
        case .preview:
            model.message = "没能确认插入位置，原话在这里"
            model.text = "我觉得这个方案可以，先不要改我的原话，然后那个会议记录都要保留。"
            return AnyView(OverlayContentView(viewModel: model, meter: meter).frame(width: 548, height: 188).padding(-VVMac.shadowInset))
        default:
            model.message = "识别中"
        }
        return AnyView(OverlayContentView(viewModel: model, meter: meter)
            .fixedSize()
            .padding(-VVMac.shadowInset))
    }

    /// The panel sizes itself from `fittingSize` right after mutating the view model;
    /// this prints whether that size follows the new state within the same turn.
    private static func sizingCheck() {
        let model = OverlayViewModel(onCancel: {}, onUndoCancel: {}, onCopy: {}, onInsertCurrent: {}, onDismiss: {})
        let hosting = NSHostingView(rootView: OverlayContentView(viewModel: model, meter: OverlayLevelMeter()))
        model.mode = .listening
        model.recordingStartedAt = Date()
        hosting.layoutSubtreeIfNeeded()
        print("sizing listening", hosting.fittingSize)
        model.recordingStartedAt = Date().addingTimeInterval(-899)
        hosting.layoutSubtreeIfNeeded()
        print("sizing listening 14:59 (panel is fixed at 144)", hosting.fittingSize)
        model.mode = .success
        model.insertedCharacterCount = 1234
        hosting.layoutSubtreeIfNeeded()
        print("sizing success", hosting.fittingSize)
        model.insertedNotice = "Soniox 余额不足，已改用阿里云"
        hosting.layoutSubtreeIfNeeded()
        print("sizing success + provider notice", hosting.fittingSize)
        model.insertedNotice = nil
        model.mode = .failure
        model.message = "没插入 · 这是一条比较长的失败原因，用来检查宽度上限和截断是否生效，不会无限变宽"
        hosting.layoutSubtreeIfNeeded()
        print("sizing failure", hosting.fittingSize)
        model.mode = .finalizing
        hosting.layoutSubtreeIfNeeded()
        print("sizing finalizing", hosting.fittingSize)
    }

    // MARK: - Menu (screens/mac-menu.html: 420×420)

    private static func menu(to dir: URL) throws {
        for (dark, variant) in [(false, ""), (true, ""), (false, "outage"), (true, "outage"), (false, "esc"), (true, "esc")] {
            let outage = variant == "outage"
            let now = Date()
            var state = MenuPanelState(
                phase: .capturing,
                title: "正在听",
                detail: "再按一次右 Option 结束 · Esc 取消",
                recordingStartedAt: now.addingTimeInterval(-7.2),
                provisionalText: "我觉得这个方案可以，先不要改我的原话，然后那个会议记录都要保留…",
                engine: "Soniox",
                insertion: "辅助功能 · 可用",
                microphone: "录音中",
                error: nil
            )
            if outage {
                state.phase = .idle
                state.title = "待命"
                state.detail = "右 Option 单击开始"
                state.provisionalText = ""
                state.microphone = "按需释放"
                state.outage = .init(
                    message: "Soniox 余额不足，已改用阿里云",
                    actionTitle: "去充值",
                    actionURL: URL(string: "https://console.soniox.com")!
                )
            }
            if variant == "esc" {
                state.detail = "再按一次右 Option 结束"
                state.escapeCancelUnavailable = true
            }
            let actions = MenuPanelActions(end: {}, cancel: {}, undoCancel: {}, start: {}, showHistory: {},
                                           checkAccessibility: {}, checkInputMonitoring: {}, openDataFolder: {}, quit: {})
            let barFill = dark ? VVColor.hex(0x1E1E20, alpha: 0.72) : VVColor.hex(0xFFFFFF, alpha: 0.72)
            let ink = dark ? Color.white : Color.black
            let stage = ZStack(alignment: .topLeading) {
                Color(nsColor: VVColor.hex(dark ? 0x2A2B2E : 0xE9E9EB))
                HStack(spacing: 14) {
                    Image(nsImage: BrandMark.menuBarRecording)
                        .renderingMode(.template)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(ink)
                    Text("10月1日 周三 15:24").font(.system(size: 13)).foregroundStyle(ink)
                }
                .padding(.horizontal, 12)
                .frame(width: 420, height: 24, alignment: .trailing)
                .background(Color(nsColor: barFill))
                // Stand-in for the system MenuBarExtra window chrome.
                MenuPanelContent(state: state, actions: actions, frozenNow: now)
                    .background(
                        Color(nsColor: dark ? VVColor.hex(0x1E1E20, alpha: 0.94) : VVColor.hex(0xFFFFFF, alpha: 0.92)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.opacity(0.18), lineWidth: 0.5))
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
                    .offset(x: 62, y: 28)
            }
            .frame(width: 420, height: 420)
            .environment(\.colorScheme, dark ? .dark : .light)
            try snapshot(stage, size: CGSize(width: 420, height: 420), dark: dark,
                         to: dir.appendingPathComponent("mac-menu\(variant.isEmpty ? "" : "-" + variant)\(dark ? "-dark" : "").png"))
        }
    }

    // MARK: - History (screens/mac-history.html: 780×560, real window chrome)

    private static func history(to dir: URL) throws {
        let records = sampleRecords()
        for dark in [false, true] {
            let content = HistoryWindowContent(
                records: records,
                destination: .constant(.history),
                selectedRecordID: .constant(records.first?.id),
                searchText: .constant(""),
                expandedHistoryIDs: [],
                retranscribingIDs: [],
                operationStatus: "",
                overview: HistoryOverviewState(title: "待命", hint: "", actionTitle: "开始录音", actionEnabled: true, error: nil),
                copyLabel: { _ in "复制" },
                providerSelection: { _ in .constant(.automatic) },
                onActivate: { _ in }, onCopy: { _ in }, onToggleDetails: { _ in },
                onPlay: { _ in }, onRetranscribe: { _ in }, onPrimaryAction: {},
                settingsPane: { EmptyView() }
            )
            let window = SettingsWindowController.makeConsoleWindow(
                contentViewController: NSHostingController(rootView: content)
            )
            window.level = .normal
            try snapshotWindow(window, dark: dark, to: dir.appendingPathComponent(dark ? "mac-history-dark.png" : "mac-history.png"))
            // On macOS 26 the detail ScrollView sits under the toolbar's scroll-edge
            // pocket (a backdrop/portal layer) that cacheDisplay does not capture, so
            // the same view is also rendered without a window for the detail column.
            try snapshot(content.frame(width: 780, height: 560), size: VVMac.windowSize, dark: dark,
                         to: dir.appendingPathComponent(dark ? "mac-history-plain-dark.png" : "mac-history-plain.png"))
        }
    }

    // MARK: - Profile pane (fictional data)

    private static func profile(to dir: URL) throws {
        let defaults = UserDefaults(suiteName: "verbatim-design-preview")!
        defaults.removePersistentDomain(forName: "verbatim-design-preview")
        let settings = AppSettings(defaults: defaults)
        settings.speakerBackground = "说话人是一名产品经理，常谈用户研究、季度规划和数据看板，偶尔提到 Figma、Notion 和 OKR。"
        settings.glossaryText = "Figma\nNotion\nOKR\nNPS\nRoadmap"
        let terms = [
            PersonalTerm(canonical: "Figma", aliases: ["菲格玛", "Figure"]),
            PersonalTerm(canonical: "OKR", aliases: ["欧克阿", "O K R"]),
            PersonalTerm(canonical: "季度规划", aliases: ["计度规划"]),
        ]
        for dark in [false, true] {
            let preview = ProfileImportPreview(fileName: "verbatim-profile.json", changes: [
                .init(title: "术语表", detail: "新增 3 个，移除 0 个"),
                .init(title: "误听别名", detail: "新增 1 个词，补充 2 个词的别名"),
                .init(title: "说话人背景", detail: "86 字，替换现有内容"),
                .init(title: "主引擎", detail: "localSenseVoice → soniox"),
            ])
            let pane = ProfilePane(
                settings: settings,
                terms: terms,
                status: "已导出到 verbatim-profile.json。文件不含 API Key、历史和录音。",
                pendingImport: preview,
                starterGlossaryAvailable: true,
                onAddAliases: { _, _ in }, onRemoveAlias: { _, _ in },
                onExport: {}, onChooseImport: {}, onConfirmImport: {}, onCancelImport: {}
            )
            let content = pane
                .frame(width: 480, height: 1_080, alignment: .topLeading)
                .background(VVColor.bgCanvas)
            try snapshot(content, size: CGSize(width: 480, height: 1_080), dark: dark,
                         to: dir.appendingPathComponent(dark ? "mac-profile-dark.png" : "mac-profile.png"))
        }
    }

    // MARK: - First-run window (fake permission states)

    private static func onboarding(to dir: URL) throws {
        let variants: [(String, OnboardingState)] = [
            ("start", OnboardingState(microphone: .notDetermined, accessibility: false, inputMonitoring: false,
                                      inputMonitoringNeedsRestart: false, model: .notInstalled,
                                      cloudKeyConfigured: false, triedText: "")),
            ("progress", OnboardingState(microphone: .granted, accessibility: true, inputMonitoring: true,
                                         inputMonitoringNeedsRestart: true,
                                         model: .downloading(.init(receivedBytes: 108_000_000, totalBytes: 262_000_000)),
                                         cloudKeyConfigured: false, triedText: "")),
            ("failed", OnboardingState(microphone: .denied, accessibility: true, inputMonitoring: true,
                                       inputMonitoringNeedsRestart: false,
                                       model: .failed(kind: .checksum, message: "识别模型校验失败，已删除下载的文件"),
                                       cloudKeyConfigured: false, triedText: "")),
            ("done", OnboardingState(microphone: .granted, accessibility: true, inputMonitoring: true,
                                     inputMonitoringNeedsRestart: false, model: .installed,
                                     cloudKeyConfigured: false, triedText: "我觉得这个方案可以，先不要改我的原话。")),
        ]
        for (name, state) in variants {
            for dark in [false, true] {
                let host = OnboardingPreviewHost(state: state)
                let size = NSHostingView(rootView: host).fittingSize
                try snapshot(host, size: size, dark: dark,
                             to: dir.appendingPathComponent("onboarding-\(name)\(dark ? "-dark" : "").png"))
            }
        }
    }

    private struct OnboardingPreviewHost: View {
        let state: OnboardingState
        @State private var text: String

        init(state: OnboardingState) {
            self.state = state
            _text = State(initialValue: state.triedText)
        }

        var body: some View {
            OnboardingContent(state: state, triedText: $text)
        }
    }

    private static func sampleRecords() -> [HistoryRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today) ?? today
        }
        let items: [(String, Date, String, Double)] = [
            ("我觉得这个方案可以，先不要改我的原话，然后那个会议记录都要保留。呃，还有一个，就是 iPhone 那边的键盘，录音中要能看到音波和时长，不然我不知道它到底在不在听。", at(0, 15, 24), "Claude Code", 9.2),
            ("那个 PR 我晚点再看，先把 Soniox 的 context 结构化那块跑一下评测，呃，跑完把 P50 发我。", at(0, 15, 2), "微信", 11.1),
            ("明天下午三点开会，记得带上季度报表。", at(0, 14, 37), "ChatGPT", 7.0),
            ("上个月的转化率是 4.2%，先别下结论，等完整数据出来再说。", at(0, 11, 15), "Terminal", 12.0),
            ("这个 skill 的触发词再收一收，现在太宽了。", at(0, 10, 48), "Cursor", 5.0),
            ("把退款流程的三个状态写成表，别加解释。", at(-1, 22, 40), "ChatGPT", 6.0),
        ]
        return items.map { text, start, app, seconds in
            let stopNanos = Int64(seconds * 1_000_000_000)
            let timeline = SessionTimelineSnapshot(
                metricSpecVersion: 1,
                wallClockStartedAt: start.addingTimeInterval(7.12),
                marks: [
                    SessionTimelineMark(event: .trigger, offsetNanoseconds: 0),
                    SessionTimelineMark(event: .stopRequested, offsetNanoseconds: stopNanos),
                    SessionTimelineMark(event: .unicodeDispatched, offsetNanoseconds: stopNanos + 550_000_000),
                ]
            )
            return HistoryRecord(
                id: UUID(),
                startedAt: start,
                finishedAt: start.addingTimeInterval(seconds + 0.6),
                targetBundleIdentifier: nil,
                targetApplicationName: app,
                primary: ProviderSummary(providerID: "soniox", model: "Soniox", text: text,
                                         firstPartialLatencyMilliseconds: 180, finalizeLatencyMilliseconds: 550,
                                         error: nil, transportMetrics: nil),
                appleBaseline: nil,
                comparisons: [ProviderSummary(providerID: "aliyun-qwen-audio-asr", model: "百炼", text: text,
                                              firstPartialLatencyMilliseconds: nil, finalizeLatencyMilliseconds: nil,
                                              error: nil, transportMetrics: nil)],
                insertedText: text,
                insertionStatus: .inserted,
                insertionTransport: .accessibilityDirect,
                insertionAttempts: nil,
                audioRelativePath: "audio/sample.flac",
                preRollMilliseconds: 300,
                notes: [],
                timeline: timeline,
                audioState: .available
            )
        }
    }

    // MARK: - Menu-bar template (icons/menubar-16@2x.png)

    private static func menuBarIcons(to dir: URL) throws {
        for (name, image) in [("menubar-16@2x.png", BrandMark.menuBarIdle), ("menubar-16-rec@2x.png", BrandMark.menuBarRecording)] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = CGSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Rendering

    private static func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        settle()
        try write(view: hosting, to: url)
        window.orderOut(nil)
    }

    private static func snapshotWindow(_ window: NSWindow, dark: Bool, to url: URL) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        settle()
        guard let frameView = window.contentView?.superview else { return }
        try write(view: frameView, to: url)
        window.orderOut(nil)
    }

    private static func settle() {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
    }

    private static func write(view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        let tagged = rep.retagging(with: .sRGB) ?? rep
        guard let data = tagged.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    // MARK: - Mock data (ports of design-v2/shared/kit.js)

    /// `VV.levels(n, seed)` from kit.js, bit-for-bit in IEEE doubles.
    static func mockLevels(count: Int, seed: Int) -> [CGFloat] {
        var state = Double(seed * 9301 + 49297)
        return (0..<count).map { index in
            let envelope = pow(max(0, sin(Double(index) / Double(count) * .pi * 2.3 + 0.4)), 0.7)
            state = (state * 1_103_515_245 + 12_345).truncatingRemainder(dividingBy: 2_147_483_648)
            let value = envelope * (0.35 + 0.65 * state / 2_147_483_648)
            return CGFloat(min(1, value * 1.15))
        }
    }

    /// kit.js draws bar height = level × h; the app draws h × level^0.55 × 1.4. Invert so
    /// the snapshot shows the same bars as the mockup.
    static func invertLevelCurve(_ level: CGFloat) -> CGFloat {
        pow(level / 1.4, 1 / 0.55)
    }
}
#endif
