import SwiftUI

struct LexiconTermRow: Identifiable, Equatable {
    let id: String
    let canonical: String
    let aliases: [String]
}

/// Lexicon (DESIGN.md screens/app-lexicon): an add field, one footnote,
/// the count, then one row per term. Swipe left to delete.
struct LexiconScreen: View {
    let terms: [LexiconTermRow]
    @Binding var draft: String
    var status: String?
    var back: () -> Void = {}
    var add: () -> Void = {}
    var delete: (String) -> Void = { _ in }

    var body: some View {
        VVPage(title: "词库", back: back) {
            List {
                Group {
                    field
                    Text(status ?? "术语原样交给识别引擎当上下文，帮它认出专名；不会改写你说的话。")
                        .vvText(.footnote)
                        .foregroundStyle(VVColor.fgSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VVSectionHeader(title: "\(terms.count) 个术语", detail: "按添加时间")
                    ForEach(Array(terms.enumerated()), id: \.element.id) { index, term in
                        VStack(spacing: 0) {
                            VVCell(
                                title: term.canonical,
                                subtitle: term.aliases.isEmpty ? nil : "常被听成：" + term.aliases.joined(separator: "、"),
                                subtitleSpacing: 3
                            )
                        }
                        .overlay(alignment: .top) { if index > 0 { HairlineDivider(leadingInset: 16) } }
                        .swipeActions {
                            Button("删除", role: .destructive) { delete(term.id) }
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(VVColor.bgCanvas)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("添加术语，例如 Claude Code").foregroundStyle(VVColor.fgTertiary))
                .vvText(.body)
                .foregroundStyle(VVColor.fgPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
            Button("添加", action: add)
                .buttonStyle(VVPillStyle(prominent: true))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: VVMetric.radiusTall, style: .continuous).fill(VVColor.bgSunken))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct LexiconView: View {
    @EnvironmentObject private var lexicon: LexiconModel
    let back: () -> Void
    @State private var draft = ""

    var body: some View {
        LexiconScreen(
            terms: lexicon.terms.map { LexiconTermRow(id: $0.id.uuidString, canonical: $0.canonical, aliases: $0.aliases) },
            draft: $draft,
            status: lexicon.status,
            back: back,
            add: add,
            delete: { id in
                guard let term = lexicon.terms.first(where: { $0.id.uuidString == id }) else { return }
                Task { await lexicon.delete(term) }
            }
        )
    }

    private func add() {
        let value = draft
        draft = ""
        Task { await lexicon.add(value) }
    }
}
