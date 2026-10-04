import SwiftUI
import UniformTypeIdentifiers

enum SettingsDestination: String, CaseIterable, Identifiable {
    case history = "历史" // l10n:ignore
    case settings = "设置" // l10n:ignore
    case profile = "个人资料" // l10n:ignore

    var id: String { rawValue }
}

/// Only the custom console has a transparent titlebar that the content can draw into.
enum SettingsWindowLayout {
    case standard
    case console
}

/// Console window (screens/mac-history.png): 300pt sidebar of transcripts grouped by day,
/// detail column on the right. Settings replace the detail column behind the gear button.
/// With nothing selected, the detail column shows the recording state and its controls.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    private let windowLayout: SettingsWindowLayout

    @State private var destination: SettingsDestination
    @State private var selectedRecordID: UUID?
    @State private var searchText = ""
    @State private var sonioxAPIKey = ""
    @State private var sonioxKeyMessage = ""
    @State private var aliyunAPIKey = ""
    @State private var aliyunKeyMessage = ""
    @State private var aliyunTesting = false
    @State private var expandedHistoryIDs: Set<UUID> = []
    @State private var historyProviders: [UUID: HistoryRetranscriptionProvider] = [:]
    @State private var advancedExpanded = false
    @State private var copiedRecordID: UUID?
    @State private var languageRevision = 0

    init(
        model: AppModel,
        initialDestination: SettingsDestination = .history,
        windowLayout: SettingsWindowLayout = .console
    ) {
        self.model = model
        settings = model.settings
        self.windowLayout = windowLayout
        _destination = State(initialValue: initialDestination)
    }

    @ViewBuilder private var permissionButtons: some View {
        Button("检查辅助功能") { model.requestAccessibilityPermission() }
        Button("检查输入监控") { model.requestInputMonitoringPermission() }
        Button("打开数据目录") { model.openDataFolder() }
    }

    var body: some View {
        HistoryWindowContent(
            windowLayout: windowLayout,
            records: model.recentHistory,
            destination: $destination,
            selectedRecordID: $selectedRecordID,
            searchText: $searchText,
            expandedHistoryIDs: expandedHistoryIDs,
            retranscribingIDs: model.retranscribingHistoryIDs,
            operationStatus: model.historyOperationStatus,
            overview: overviewState,
            copyLabel: { historyActionLabel($0) },
            providerSelection: { historyProviderBinding($0) },
            onActivate: { record in activateHistoryRecord(record, revealDetailsForEmpty: true) },
            onCopy: { record in activateHistoryRecord(record, revealDetailsForEmpty: false) },
            onToggleDetails: { toggleHistoryDetails($0) },
            onPlay: { model.playHistoryAudio($0) },
            onRetranscribe: { record in
                model.retranscribeHistory(record, using: historyProviders[record.id] ?? .automatic)
            },
            onPrimaryAction: {
                if model.state == .cancelPending { model.undoCancel() }
                else { model.toggleDictation() }
            },
            settingsPane: {
                if destination == .profile { profile } else { configuration }
            }
        )
        .onReceive(model.$requestedSettingsDestination.compactMap { $0 }) { requested in
            destination = requested
            model.requestedSettingsDestination = nil
        }
        .onAppear {
            // Open on the newest record (as in mac-history.png) without copying it;
            // the title returns to the recording controls.
            if selectedRecordID == nil { selectedRecordID = model.recentHistory.first?.id }
            sonioxAPIKey = model.currentSonioxAPIKey()
            aliyunAPIKey = model.currentAliyunAPIKey()
        }
    }

    private var overviewState: HistoryOverviewState {
        HistoryOverviewState(
            title: overviewStatus ?? String(localized: "待命"),
            hint: model.escapeCancelAvailable
                ? String(localized: "\(settings.triggerKey.displayName) 开始 · 再按一次结束 · Esc 取消")
                : String(localized: "\(settings.triggerKey.displayName) 开始 · 再按一次结束 · Esc 取消不可用，需要重新授权输入监控"),
            actionTitle: model.state == .idle ? String(localized: "开始录音") : actionLabel,
            actionEnabled: !(model.state == .finalizing || model.state == .inserting),
            error: model.state == .failed ? model.lastError : nil
        )
    }

    // MARK: - Profile pane

    private var profile: some View {
        ProfilePane(
            settings: settings,
            terms: model.personalTerms,
            status: model.profileStatus,
            pendingImport: model.profileImportPreview,
            starterGlossaryAvailable: !AppSettings.starterGlossaryTerms.isEmpty,
            onAddAliases: { model.addPersonalAliases(canonical: $0, aliases: $1) },
            onRemoveAlias: { model.removePersonalAlias($1, from: $0) },
            onExport: { chooseExportDestination() },
            onChooseImport: { chooseImportSource() },
            onConfirmImport: { model.confirmProfileImport() },
            onCancelImport: { model.cancelProfileImport() }
        )
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出配置")
        panel.message = String(localized: "导出的文件包含术语表、个人词库、说话人背景等，不包含 API Key、历史和录音。")
        panel.nameFieldStringValue = "\(AppIdentity.dataDirectoryName.lowercased())-profile.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportProfile(to: url)
    }

    private func chooseImportSource() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "导入配置")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.prepareProfileImport(from: url)
    }

    // MARK: - Settings pane (content unchanged; tokens only)

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))

                settingsSection("识别") {
                    Picker("主模型", selection: $settings.primaryProvider) {
                        ForEach(PrimaryTranscriptionProvider.allCases) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.primaryProvider) { _, _ in model.applyRuntimeSettings() }
                    Toggle("云端异常时自动使用本地模型", isOn: $settings.automaticLocalFallback)
                    Toggle("保留录音与历史", isOn: $settings.saveAudio)
                    LocalModelStatusView(store: model.localModels)
                }

                settingsSection("界面语言") {
                    Picker("界面语言", selection: Binding(
                        get: { settings.interfaceLanguage },
                        set: { settings.interfaceLanguage = $0; languageRevision += 1 }
                    )) {
                        Text("跟随系统").tag(InterfaceLanguage.system)
                        Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese) // l10n:ignore
                        Text(verbatim: "English").tag(InterfaceLanguage.english)
                    }
                    .id(languageRevision)
                    if settings.interfaceLanguage != AppSettings.launchInterfaceLanguage {
                        HStack(spacing: 8) {
                            Text("重启后使用新的界面语言。")
                                .font(.system(size: 12))
                                .foregroundStyle(VVColor.fgSecondary)
                            Button("立即重启") { model.relaunch() }.buttonStyle(VVButtonStyle())
                        }
                    }
                }

                settingsSection("触发键") {
                    Picker("单击开始，再按一次结束", selection: $settings.triggerKey) {
                        ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0) }
                    }
                    if settings.triggerKey.modifierKeySpec.triggerOn == .release {
                        Text("这个键常用于快捷键，松开时才开始，与其他键一起按不会触发。")
                            .font(.system(size: 12))
                            .foregroundStyle(VVColor.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = settings.triggerKey.systemConflictNote {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(VVColor.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsSection("云端密钥") {
                    keyRow(title: "Soniox", configured: model.sonioxKeyConfigured, key: $sonioxAPIKey, message: sonioxKeyMessage) {
                        do {
                            try model.saveSonioxAPIKey(sonioxAPIKey)
                            sonioxKeyMessage = sonioxAPIKey.isEmpty ? String(localized: "已删除") : String(localized: "已保存")
                        } catch { sonioxKeyMessage = error.localizedDescription }
                    }
                    Hairline()
                    Picker("阿里云区域", selection: $settings.aliyunRegion) {
                        ForEach(AliyunRegion.allCases) { Text($0.displayName).tag($0) }
                    }
                    keyRow(title: "阿里云百炼", configured: model.aliyunKeyConfigured, key: $aliyunAPIKey, message: aliyunKeyMessage) {
                        do {
                            try model.saveAliyunAPIKey(aliyunAPIKey)
                            aliyunKeyMessage = aliyunAPIKey.isEmpty ? String(localized: "已删除") : String(localized: "已保存")
                        } catch { aliyunKeyMessage = error.localizedDescription }
                    }
                    HStack(spacing: 8) {
                        Button(aliyunTesting ? "测试中…" : "测试阿里云连接") {
                            aliyunTesting = true
                            Task {
                                aliyunKeyMessage = await model.testAliyunConnection()
                                aliyunTesting = false
                            }
                        }
                        .buttonStyle(VVButtonStyle())
                        .disabled(aliyunTesting || !model.aliyunKeyConfigured)
                        Button("获取 Key") { model.openAliyunAPIKeyGuide() }
                            .buttonStyle(VVButtonStyle())
                    }
                }

                DisclosureGroup("高级与诊断", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("启动缓冲：\(settings.preRollMilliseconds) ms", value: $settings.preRollMilliseconds, in: 0...1_000, step: 50)
                        Stepper("尾音：\(settings.postRollMilliseconds) ms", value: $settings.postRollMilliseconds, in: 0...800, step: 20)
                        Stepper("单次上限：\(settings.maximumUtteranceSeconds) 秒", value: $settings.maximumUtteranceSeconds, in: 10...1800, step: 30)
                        Stepper("音频保留：\(settings.audioRetentionDays) 天", value: $settings.audioRetentionDays, in: 1...365)
                        Stepper("音频上限：\(settings.audioQuotaMegabytes) MB", value: $settings.audioQuotaMegabytes, in: 64...16_384, step: 64)
                        Toggle("观察插入后的人工修改", isOn: $settings.correctionCaptureEnabled)
                        Toggle("保留 Apple 对照", isOn: $settings.appleBaselineEnabled)
                            .onChange(of: settings.appleBaselineEnabled) { _, _ in model.applyRuntimeSettings() }
                        Toggle("登录后自动启动", isOn: Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) }))
                        // English labels are longer; stack them when the row does not fit.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { permissionButtons }
                            VStack(alignment: .leading, spacing: 8) { permissionButtons }
                        }
                        .buttonStyle(VVButtonStyle())
                    }
                    .padding(.top, 12)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(VVColor.fgPrimary)
            .padding(.top, VVMac.detailTopInset)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func keyRow(title: LocalizedStringKey, configured: Bool, key: Binding<String>, message: String, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(configured ? "已配置" : "未配置")
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
            }
            HStack(spacing: 8) {
                SecureField("API Key", text: key).textFieldStyle(.roundedBorder)
                Button("保存") { save() }
                    .buttonStyle(VVButtonStyle())
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(VVColor.fgSecondary)
            }
        }
    }

    // MARK: - State text

    private var overviewStatus: String? {
        switch model.state {
        case .starting: return String(localized: "正在启动麦克风")
        case .listening: return String(localized: "正在录音")
        case .cancelPending: return String(localized: "已取消，5 秒内可以撤销")
        case .finalizing, .inserting: return String(localized: "正在转写")
        case .failed: return String(localized: "这次没有完成")
        case .idle, .preview: return nil
        }
    }

    private var actionLabel: String {
        switch model.state {
        case .starting, .listening: return String(localized: "结束并转写")
        case .cancelPending: return String(localized: "撤销取消")
        case .finalizing, .inserting: return String(localized: "正在处理")
        default: return String(localized: "开始录音")
        }
    }

    // MARK: - History actions

    private func toggleHistoryDetails(_ id: UUID) {
        if expandedHistoryIDs.contains(id) { expandedHistoryIDs.remove(id) }
        else { expandedHistoryIDs.insert(id) }
    }

    /// One click on a record copies its full text (the established history contract)
    /// and shows it in the detail column.
    private func activateHistoryRecord(_ record: HistoryRecord, revealDetailsForEmpty: Bool) {
        destination = .history
        selectedRecordID = record.id
        guard !record.insertedText.isEmpty else {
            if revealDetailsForEmpty {
                expandedHistoryIDs.insert(record.id)
            }
            return
        }
        model.copyHistoryRecord(record)
        withAnimation(.easeOut(duration: 0.16)) {
            copiedRecordID = record.id
        }
        let copiedID = record.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard copiedRecordID == copiedID else { return }
            withAnimation(.easeOut(duration: 0.16)) { copiedRecordID = nil }
        }
    }

    private func historyActionLabel(_ record: HistoryRecord) -> String {
        func label() -> LocalizedStringResource {
            if record.insertedText.isEmpty { return "打开" }
            return copiedRecordID == record.id ? "已复制" : "复制"
        }
        return String(localized: label())
    }

    private func historyProviderBinding(_ id: UUID) -> Binding<HistoryRetranscriptionProvider> {
        Binding(get: { historyProviders[id] ?? .automatic }, set: { historyProviders[id] = $0 })
    }
}

struct HistoryOverviewState {
    var title: String
    var hint: String
    var actionTitle: String
    var actionEnabled: Bool
    var error: String?
}

// MARK: - Layout (data in, closures out; no AppModel)

struct HistoryWindowContent<SettingsPane: View>: View {
    var windowLayout: SettingsWindowLayout = .console
    let records: [HistoryRecord]
    @Binding var destination: SettingsDestination
    @Binding var selectedRecordID: UUID?
    @Binding var searchText: String
    let expandedHistoryIDs: Set<UUID>
    let retranscribingIDs: Set<UUID>
    let operationStatus: String
    let overview: HistoryOverviewState
    let copyLabel: (HistoryRecord) -> String
    let providerSelection: (UUID) -> Binding<HistoryRetranscriptionProvider>
    let onActivate: (HistoryRecord) -> Void
    let onCopy: (HistoryRecord) -> Void
    let onToggleDetails: (UUID) -> Void
    let onPlay: (HistoryRecord) -> Void
    let onRetranscribe: (HistoryRecord) -> Void
    let onPrimaryAction: () -> Void
    @ViewBuilder let settingsPane: () -> SettingsPane

    var body: some View {
        HStack(spacing: 0) {
            // The console draws its header in the transparent titlebar; the standard
            // Settings scene keeps that header below the system titlebar instead.
            // Both align the detail column below the sidebar's 52pt header.
            sidebar
                .frame(width: VVMac.sidebarWidth)
            Hairline(vertical: true)
            detail
                .padding(.top, VVMac.titlebarHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(VVColor.bgCanvas)
        }
        .font(.system(size: 13))
        .tracking(VVMac.menuTracking)
        .foregroundStyle(VVColor.fgPrimary)
        .ignoresSafeArea(.container, edges: windowLayout == .console ? .top : [])
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    destination = .history
                    selectedRecordID = nil
                } label: {
                    Text(AppIdentity.displayName).font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("回到录音状态")
                Spacer(minLength: 0)
                Button {
                    destination = destination == .profile ? .history : .profile
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(destination == .profile ? VVColor.fgPrimary : VVColor.fgSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            destination == .profile ? VVColor.fillControl : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("个人资料")
                .accessibilityLabel("个人资料")
                Button {
                    destination = destination == .settings ? .history : .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(destination == .settings ? VVColor.fgPrimary : VVColor.fgSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            destination == .settings ? VVColor.fillControl : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
                .accessibilityLabel("设置")
            }
            .padding(.leading, windowLayout == .console ? 92 : 12)
            .padding(.trailing, 12)
            .frame(height: VVMac.titlebarHeight)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            history
        }
        .background(VVColor.bgRaised)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VVColor.fgTertiary)
            TextField("搜索原话", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(VVMac.searchFill, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
    }

    private var history: some View {
        ScrollView {
            // Eager stacks: the data source is capped at 20 records, and a lazy stack
            // with variable-height rows has hit a macOS 26 layout loop.
            VStack(alignment: .leading, spacing: 12) {
                if filteredRecords.isEmpty {
                    Text(records.isEmpty ? "还没有记录" : "没有匹配的原话")
                        .foregroundStyle(VVColor.fgSecondary)
                        .padding(.horizontal, 16)
                }
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.title)
                            .font(.system(size: 11))
                            .lineHeight(16, fontSize: 11)
                            .foregroundStyle(VVColor.fgSecondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 4)
                        ForEach(section.records, id: \.id) { record in
                            historyRow(record)
                        }
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        let selected = destination == .history && selectedRecordID == record.id
        return Button {
            onActivate(record)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.insertedText.isEmpty ? String(localized: "已保留音频，尚无文字") : record.insertedText)
                    .foregroundStyle(record.insertedText.isEmpty ? VVColor.fgSecondary : VVColor.fgPrimary)
                    .lineLimit(2)
                    .lineHeight(17, fontSize: 13)
                    .multilineTextAlignment(.leading)
                Text(HistoryFormat.rowMeta(record))
                    .font(.system(size: 11))
                    .lineHeight(16, fontSize: 11)
                    .monospacedDigit()
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous)
                        .fill(VVMac.selectedRowFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous)
                                .strokeBorder(VVMac.selectedRowStroke, lineWidth: 0.5)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .help("单击复制全文")
    }

    private var filteredRecords: [HistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.insertedText.localizedCaseInsensitiveContains(query)
                || ($0.targetApplicationName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var sections: [(title: String, records: [HistoryRecord])] {
        var result: [(title: String, records: [HistoryRecord])] = []
        for record in filteredRecords {
            let title = HistoryFormat.dayTitle(record.startedAt)
            if let last = result.indices.last, result[last].title == title {
                result[last].records.append(record)
            } else {
                result.append((title, [record]))
            }
        }
        return result
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if destination == .settings || destination == .profile {
            settingsPane()
        } else if let record = records.first(where: { $0.id == selectedRecordID }) {
            recordDetail(record)
        } else {
            overviewPane
        }
    }

    private var overviewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(overview.hint)
                    .foregroundStyle(VVColor.fgSecondary)
            }
            Button(overview.actionTitle, action: onPrimaryAction)
                .buttonStyle(VVButtonStyle(prominent: true))
                .disabled(!overview.actionEnabled)
            if let error = overview.error, !error.isEmpty {
                Text(error)
                    .foregroundStyle(VVColor.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !records.isEmpty {
                Text("单击左侧任一条即复制全文，并在这里显示详情。")
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgTertiary)
                    .padding(.top, 6)
            }
        }
        .padding(.top, VVMac.detailTopInset)
        .padding(.horizontal, 32)
    }

    private func recordDetail(_ record: HistoryRecord) -> some View {
        ScrollView {
            HistoryRecordDetail(
                record: record,
                expandedHistoryIDs: expandedHistoryIDs,
                retranscribing: retranscribingIDs.contains(record.id),
                operationStatus: operationStatus,
                copyLabel: copyLabel(record),
                provider: providerSelection(record.id),
                onCopy: { onCopy(record) },
                onToggleDetails: onToggleDetails,
                onPlay: { onPlay(record) },
                onRetranscribe: { onRetranscribe(record) }
            )
            .padding(.top, VVMac.detailTopInset)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HistoryRecordDetail: View {
    let record: HistoryRecord
    let expandedHistoryIDs: Set<UUID>
    let retranscribing: Bool
    let operationStatus: String
    let copyLabel: String
    let provider: Binding<HistoryRetranscriptionProvider>
    let onCopy: () -> Void
    let onToggleDetails: (UUID) -> Void
    let onPlay: () -> Void
    let onRetranscribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.insertedText.isEmpty ? String(localized: "（没有转写文字）") : record.insertedText)
                .font(VVMac.transcriptFont)
                .tracking(VVMac.transcriptTracking)
                .lineHeight(23, fontSize: 15)
                .foregroundStyle(record.insertedText.isEmpty ? VVColor.fgSecondary : VVColor.fgPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)

            Text(HistoryFormat.detailMeta(record))
                .monospacedDigit()
                .lineHeight(16, fontSize: 13)
                .foregroundStyle(VVColor.fgSecondary)

            audioRow
                .padding(.top, 4)

            HStack(spacing: 8) {
                Button(action: onCopy) {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                        Text(copyLabel)
                    }
                }
                .disabled(record.insertedText.isEmpty)
                Button(retranscribing ? "转写中…" : "重新转写", action: onRetranscribe)
                    .disabled(record.audioRelativePath == nil || retranscribing)
                Button(expandedHistoryIDs.contains(record.id) ? "收起" : "详情") {
                    onToggleDetails(record.id)
                }
            }
            .buttonStyle(VVButtonStyle())
            .padding(.top, 4)

            if !operationStatus.isEmpty {
                Text(operationStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
            }

            diagnosticsTable
                .padding(.top, 10)

            if expandedHistoryIDs.contains(record.id) {
                expandedSection
            }
        }
    }

    private var audioRow: some View {
        let playable = record.audioState != .unavailable && record.audioRelativePath != nil
        return HStack(spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(VVColor.fgPrimary)
                    .frame(width: 28, height: 28)
                    .background(VVMac.quoteFill, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playable)
            .opacity(playable ? 1 : 0.4)
            .accessibilityLabel("播放录音")
            Text(playable ? String(localized: "播放录音 · \(HistoryFormat.duration(record))") : String(localized: "没有保留音频"))
                .monospacedDigit()
                .foregroundStyle(VVColor.fgSecondary)
        }
    }

    private var diagnosticsTable: some View {
        let rows = HistoryFormat.diagnostics(record)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Hairline() }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(row.label)
                        .foregroundStyle(VVColor.fgSecondary)
                        .frame(width: 84, alignment: .leading)
                    Text(row.value)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .lineHeight(16, fontSize: 12)
                .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("重新转写使用", selection: provider) {
                ForEach(HistoryRetranscriptionProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .frame(width: 220)
            .controlSize(.small)

            if let revisions = record.transcriptRevisions, !revisions.isEmpty {
                Text("版本").font(.system(size: 12, weight: .semibold))
                ForEach(Array(revisions.enumerated()), id: \.offset) { _, revision in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text((revision.source == .original ? String(localized: "原始") : String(localized: "重转写")) + " · " + revision.model)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(revision.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(VVColor.fgTertiary)
                        }
                        Text(revision.error ?? (revision.text.isEmpty ? String(localized: "（空结果）") : revision.text))
                            .font(.system(size: 12))
                            .foregroundStyle(VVColor.fgSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: - Formatting (presentation only; reads existing record fields)

enum HistoryFormat {
    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "今天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(.dateTime.locale(dayLocale).year(sameYear ? .omitted : .defaultDigits).month(.defaultDigits).day())
    }

    private static var isChinese: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
    }

    /// Dates follow the language the app UI resolved to, not the region. Chinese keeps the
    /// original zh_CN formats; English uses US month/day and a 24-hour clock, like the Chinese one.
    private static var dayLocale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_US") } // l10n:ignore
    private static var clockLocale: Locale { Locale(identifier: isChinese ? "zh_CN" : "en_GB") } // l10n:ignore

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.locale(clockLocale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func rowMeta(_ record: HistoryRecord) -> String {
        var parts = [clock(record.startedAt), record.targetApplicationName ?? String(localized: "未知应用"), duration(record)]
        // Routine outcomes stay out of the row; decided on the record, not on label text.
        if !isRoutineOutcome(record), let state = outcomeLabel(record) { parts.append(state) }
        return parts.joined(separator: " · ")
    }

    static func detailMeta(_ record: HistoryRecord) -> String {
        var parts = ["\(dayTitle(record.startedAt)) \(clock(record.startedAt))"]
        parts.append(record.targetApplicationName ?? String(localized: "未知应用"))
        parts.append(duration(record))
        if !record.insertedText.isEmpty {
            let count = record.insertedText.filter { !$0.isWhitespace }.count
            parts.append(count == 1 ? String(localized: "1 字") : String(localized: "\(count, format: .number.grouping(.never)) 字"))
        }
        if let outcome = outcomeLabel(record) { parts.append(outcome) }
        return parts.joined(separator: " · ")
    }

    /// Recording length: trigger → stop when the timeline has it, otherwise the
    /// session's wall-clock span.
    static func duration(_ record: HistoryRecord) -> String {
        let milliseconds = record.timeline?.milliseconds(from: .trigger, to: .stopRequested)
            ?? record.timeline?.milliseconds(from: .trigger, to: .cancelRequested)
            ?? Int(record.finishedAt.timeIntervalSince(record.startedAt) * 1_000)
        let seconds = max(0, Int((Double(milliseconds) / 1_000).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Inserted or sent normally: the history row omits these outcomes.
    static func isRoutineOutcome(_ record: HistoryRecord) -> Bool {
        guard record.disposition != .retainedDraft else { return false }
        return record.insertionStatus == .inserted || record.insertionStatus == .dispatched
    }

    static func outcomeLabel(_ record: HistoryRecord) -> String? {
        if record.disposition == .retainedDraft { return String(localized: "取消后保留") }
        switch record.insertionStatus {
        case .inserted: return String(localized: "已插入")
        case .dispatched: return String(localized: "已发送")
        case .previewOnly: return String(localized: "仅预览")
        case .copied: return String(localized: "已复制")
        case .canceled: return String(localized: "已取消")
        case .failed: return String(localized: "失败")
        case .unconfirmed: return String(localized: "未确认")
        }
    }

    /// 24-hour wall clock with milliseconds, e.g. 15:24:07.120.
    static let preciseClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.2f s", Double(milliseconds) / 1_000)
    }

    static func diagnostics(_ record: HistoryRecord) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let primary = record.primary {
            var value = [primary.model]
            if let first = primary.firstPartialLatencyMilliseconds { value.append(String(localized: "首帧 \(seconds(first))")) }
            if let finalize = primary.finalizeLatencyMilliseconds { value.append(String(localized: "定稿 \(seconds(finalize))")) }
            if let error = primary.error, !error.isEmpty { value.append(error) }
            rows.append((String(localized: "主引擎"), value.joined(separator: " · ")))
        }
        if let comparisons = record.comparisons, !comparisons.isEmpty {
            let value = comparisons.map { summary -> String in
                if let error = summary.error, !error.isEmpty { return String(localized: "\(summary.model) · 未完成") }
                let same = summary.text == record.insertedText
                return same ? String(localized: "\(summary.model) · 一致") : String(localized: "\(summary.model) · 不同")
            }.joined(separator: String(localized: "；"))
            rows.append((String(localized: "热备"), value))
        }
        if record.usedOfflineFallback == true {
            rows.append((String(localized: "兜底"), String(localized: "本地 SenseVoice")))
        }
        var insertion: [String] = []
        if let transport = record.insertionTransport { insertion.append(transportLabel(transport)) }
        if let app = record.targetApplicationName { insertion.append(String(localized: "目标 \(app)")) }
        if let outcome = outcomeLabel(record) { insertion.append(outcome) }
        if !insertion.isEmpty { rows.append((String(localized: "插入方式"), insertion.joined(separator: " · "))) }
        if let timeline = record.timeline {
            var steps = [String(localized: "按下 \(preciseClock.string(from: timeline.wallClockStartedAt))")]
            if let stop = timeline.milliseconds(from: .trigger, to: .stopRequested) {
                steps.append(String(localized: "停止 +\(seconds(stop))"))
                if let dispatched = timeline.milliseconds(from: .stopRequested, to: .unicodeDispatched) {
                    steps.append(String(localized: "插入 +\(seconds(dispatched))"))
                }
            }
            rows.append((String(localized: "时间线"), steps.joined(separator: " → ")))
        }
        return rows
    }

    static func transportLabel(_ transport: InsertionTransport) -> String {
        switch transport {
        case .accessibilityDirect: return String(localized: "辅助功能写入")
        case .unicodeKeyboard: return String(localized: "Unicode 键入")
        case .clipboardPaste: return String(localized: "粘贴")
        case .clipboardCopy: return String(localized: "复制到剪贴板")
        case .none: return String(localized: "未插入")
        }
    }
}
