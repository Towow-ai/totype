import SwiftUI

/// What an import file would change, shown before anything is written.
struct ProfileImportPreview: Equatable {
    let fileName: String
    let changes: [PersonalProfile.Change]
}

/// "个人资料": everything that makes the recognizer yours (speaker background,
/// glossary, mishearing aliases, prompt) plus export and import of the whole set.
/// Plain data and closures in, so snapshots can render it without an AppModel.
struct ProfilePane: View {
    @ObservedObject var settings: AppSettings
    let terms: [PersonalTerm]
    let status: String
    let pendingImport: ProfileImportPreview?
    let starterGlossaryAvailable: Bool
    let onAddAliases: (_ canonical: String, _ aliases: [String]) -> Void
    let onRemoveAlias: (_ term: PersonalTerm, _ alias: String) -> Void
    let onExport: () -> Void
    let onChooseImport: () -> Void
    let onConfirmImport: () -> Void
    let onCancelImport: () -> Void

    @State private var draftCanonical = ""
    @State private var draftAliases = ""

    private static let backgroundExample = "示例：说话人是一名产品经理，常谈用户研究、季度规划和数据看板。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("个人资料")
                    .font(.system(size: 15, weight: .semibold))

                section("说话人背景") {
                    editor($settings.speakerBackground, minHeight: 90)
                    note(settings.speakerBackground.isEmpty
                        ? "发给 Soniox 作为背景，帮助它在听不清时偏向你常说的领域。只写身份、常谈话题和常用词，不写指令。\n" + Self.backgroundExample
                        : "发给 Soniox 作为背景，帮助它在听不清时偏向你常说的领域。")
                }

                section("术语表") {
                    editor($settings.glossaryText, minHeight: 130, monospaced: true)
                    note("每行一个词，每次录音都会发给云端识别；个人词库里的词排在前面。")
                    Toggle("加入开发者入门词包（GitHub、MCP 等通用技术词）", isOn: $settings.starterGlossaryEnabled)
                        .disabled(!starterGlossaryAvailable)
                    if !starterGlossaryAvailable {
                        note("当前构建没有包含入门词包。")
                    }
                    Stepper("阿里云热词权重：\(settings.hotwordWeight)", value: $settings.hotwordWeight, in: 1...5)
                }

                section("插入") {
                    Toggle("聊天应用里去掉句末句号", isOn: $settings.removeChatTerminalPeriod)
                    Toggle("英文结尾补空格", isOn: $settings.appendTrailingSpaceAfterEnglish)
                    note("两项默认关闭，只在文字插入输入框时处理。")
                }

                section("误听别名") {
                    note("别名是识别引擎常把某个词听错的写法。只在另一个引擎在同一位置听到原词时用来恢复，不会发给云端。")
                    aliasList
                    HStack(spacing: 8) {
                        TextField("词", text: $draftCanonical)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        TextField("常被听成（用逗号分隔）", text: $draftAliases)
                            .textFieldStyle(.roundedBorder)
                        Button("添加") { addDraft() }
                            .buttonStyle(VVButtonStyle())
                            .disabled(draftCanonical.trimmingCharacters(in: .whitespaces).isEmpty
                                || splitAliases(draftAliases).isEmpty)
                    }
                }

                section("转写提示词") {
                    editor($settings.transcriptionPrompt, minHeight: 80)
                    note("只作为识别上下文，不调用 LLM 改写或整理。")
                }

                section("导出与导入") {
                    note("配置文件包含：术语表、个人词库与别名、说话人背景、转写提示词、识别与插入偏好、录音保留设置。不包含 API Key、历史记录和录音。")
                    HStack(spacing: 8) {
                        Button("导出配置…") { onExport() }
                        Button("导入配置…") { onChooseImport() }
                    }
                    .buttonStyle(VVButtonStyle())
                    if let pendingImport {
                        importPreview(pendingImport)
                    }
                    if !status.isEmpty {
                        note(status)
                    }
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

    // MARK: Pieces

    private var termsWithAliases: [PersonalTerm] {
        terms.filter { $0.state == .confirmed && !$0.aliases.isEmpty }
            .sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
    }

    @ViewBuilder private var aliasList: some View {
        if termsWithAliases.isEmpty {
            note("还没有别名。")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(termsWithAliases.enumerated()), id: \.element.id) { index, term in
                    if index > 0 { Hairline() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(term.canonical)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 140, alignment: .leading)
                        FlowAliases(aliases: term.aliases) { alias in onRemoveAlias(term, alias) }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func importPreview(_ preview: ProfileImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导入“\(preview.fileName)”将改变：")
                .font(.system(size: 13, weight: .medium))
            if preview.changes.isEmpty {
                note("没有需要改变的内容。")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preview.changes.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(change.title).frame(width: 150, alignment: .leading)
                            Text(change.detail).foregroundStyle(VVColor.fgSecondary)
                        }
                    }
                }
                note("导入前会先把当前配置备份到该文件所在的文件夹。")
            }
            HStack(spacing: 8) {
                if !preview.changes.isEmpty {
                    Button("应用导入") { onConfirmImport() }
                }
                Button("取消") { onCancelImport() }
            }
            .buttonStyle(VVButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VVColor.bgSunken, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat, monospaced: Bool = false) -> some View {
        TextEditor(text: text)
            .font(monospaced ? .system(.body, design: .monospaced) : .system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(6)
            .background(VVColor.bgSunken, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(VVColor.fgSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func splitAliases(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func addDraft() {
        let canonical = draftCanonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = splitAliases(draftAliases)
        guard !canonical.isEmpty, !aliases.isEmpty else { return }
        onAddAliases(canonical, aliases)
        draftCanonical = ""
        draftAliases = ""
    }
}

/// Aliases as removable text chips, wrapping across lines.
private struct FlowAliases: View {
    let aliases: [String]
    let onRemove: (String) -> Void

    var body: some View {
        WrappingLayout(spacing: 6) {
            ForEach(aliases, id: \.self) { alias in
                HStack(spacing: 4) {
                    Text(alias)
                    Button { onRemove(alias) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VVColor.fgTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("删除这个别名")
                    .accessibilityLabel("删除别名 \(alias)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(VVColor.fillControl, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

private struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
