import SwiftUI
import UIKit

// MARK: - Display model

/// One line under the title: the session, in one sentence.
enum HomeSessionLine: Equatable {
    case ready(endsAt: Date?)
    case paused
    case off
    case starting
    case listening
    case finalizing
}

struct HomeRow: Identifiable, Equatable {
    let id: UUID
    let text: String
    let meta: String
}

struct HomeSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let summary: String
    let rows: [HomeRow]
}

struct HomeContent: Equatable {
    var session: HomeSessionLine = .off
    var sessionEndable = false
    var sections: [HomeSection] = []
    var liveText: String?
    var notice: String?
    /// Primary engine unusable (balance, key): one line under the session row.
    var outage: HomeOutage?
    var mic: MicControl.Phase = .ready
    var wave: Waveform.Mode = .line()
    /// Preview only: a fixed countdown.
    var fixedRemaining: TimeInterval?
}

struct HomeOutage: Equatable {
    /// e.g. "Soniox 余额不足，已改用阿里云".
    let message: String
    let actionTitle: String
    let actionURL: URL
    var probing = false
}

struct HomeActions {
    var copy: (UUID) -> Void = { _ in }
    var open: (UUID) -> Void = { _ in }
    var endSession: () -> Void = {}
    var start: () -> Void = {}
    var cancel: () -> Void = {}
    var finish: () -> Void = {}
    var lexicon: () -> Void = {}
    var settings: () -> Void = {}
    var retryProvider: () -> Void = {}
}

// MARK: - Screen

/// Home = the transcript list (DESIGN.md §7.4): large title, one session
/// row, a hairline, day groups, and the bottom mic bar. No tab bar.
struct HomeScreen: View {
    let content: HomeContent
    var copiedID: UUID?
    let actions: HomeActions

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                VVNavBar(title: nil, back: nil) {
                    VVNavIcon(systemName: "book.closed", label: "词库", size: 19, action: actions.lexicon)
                    VVNavIcon(systemName: "gearshape", label: "设置", size: 20, action: actions.settings)
                }
                Text(MobileIdentity.displayName)
                    .vvText(.largeTitle)
                    .foregroundStyle(VVColor.fgPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52, alignment: .top)
                sessionRow
                if let outage = content.outage {
                    outageRow(outage)
                }
                HairlineDivider(leadingInset: 16)
                list
                MicBar(
                    phase: content.mic,
                    wave: content.wave,
                    onStart: actions.start,
                    onCancel: actions.cancel,
                    onFinish: actions.finish
                )
            }
            .padding(.top, VVLayout.top(proxy.safeAreaInsets.top))
            .ignoresSafeArea(edges: .top)
        }
        .background(VVColor.bgCanvas.ignoresSafeArea())
    }

    // MARK: Session row (52)

    private var sessionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(VVColor.fgPrimary)
                .frame(width: 18, height: 18)
            sessionText
                .vvText(.subhead)
                .foregroundStyle(VVColor.fgSecondary)
                .lineLimit(1...3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if content.sessionEndable {
                Button("结束", action: actions.endSession)
                    .buttonStyle(VVPillStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
    }

    /// Same sentence as the Mac menu panel, with the two actions that fix it.
    /// Existing type and pills only; no new hue.
    private func outageRow(_ outage: HomeOutage) -> some View {
        HStack(spacing: 8) {
            Text(outage.message)
                .vvText(.footnote)
                .foregroundStyle(VVColor.fgSecondary)
                .lineLimit(1...2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Link(destination: outage.actionURL) {
                Text(outage.actionTitle)
            }
            .buttonStyle(VVPillStyle())
            Button(outage.probing ? "检查中" : "重试", action: actions.retryProvider)
                .buttonStyle(VVPillStyle())
                .disabled(outage.probing)
        }
        .padding(.leading, 44)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    private var sessionText: Text {
        let t: Text
        switch content.session {
        case .ready(let endsAt):
            if let remaining = content.fixedRemaining {
                t = bold("会话待命") + Text(" · 还剩 ") + Text(VVClock.format(remaining)).monospacedDigit() + Text(" · 键盘上直接说")
            } else if let endsAt {
                t = bold("会话待命") + Text(" · 还剩 ")
                    + Text(timerInterval: Date()...max(Date(), endsAt), countsDown: true).monospacedDigit()
                    + Text(" · 键盘上直接说")
            } else {
                t = bold("会话待命") + Text(" · 直到手动结束 · 键盘上直接说")
            }
        case .paused:
            t = bold("会话已暂停") + Text(" · 回到前台会自动恢复")
        case .off:
            t = bold("会话未开启") + Text(" · 在键盘上点麦克风开始")
        case .starting:
            t = bold("正在启动麦克风") + Text("…")
        case .listening:
            t = bold("正在听") + Text(" · 说完点一下波形")
        case .finalizing:
            t = bold("识别中") + Text("…")
        }
        // Concatenated runs do not pick up the view-level language; set it here.
        return t.typesettingLanguage(Locale.Language(identifier: "en"))
    }

    private func bold(_ s: String) -> Text {
        Text(s).fontWeight(.medium).foregroundStyle(VVColor.fgPrimary)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let notice = content.notice {
                    Text(notice)
                        .vvText(.footnote)
                        .foregroundStyle(VVColor.fgSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                if let live = content.liveText, !live.isEmpty {
                    TranscriptRowView(text: live, meta: "正在听…", copied: false, pending: true)
                }
                if content.sections.isEmpty && (content.liveText ?? "").isEmpty {
                    Text("还没有记录。在键盘上点麦克风说一句，原话会出现在这里。")
                        .vvText(.subhead)
                        .foregroundStyle(VVColor.fgTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                }
                ForEach(Array(content.sections.enumerated()), id: \.element.id) { index, section in
                    VVSectionHeader(title: section.title, detail: section.summary, first: index == 0)
                    VVRows(data: section.rows) { row in
                        TranscriptRowView(text: row.text, meta: row.meta, copied: copiedID == row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { actions.copy(row.id) }
                            .contextMenu {
                                Button { actions.open(row.id) } label: { Label("查看详情", systemImage: "doc.text") }
                                Button { actions.copy(row.id) } label: { Label("复制", systemImage: "doc.on.doc") }
                            }
                            .accessibilityAction(named: "查看详情") { actions.open(row.id) }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}

/// A transcript row (`.row`): 12/16 padding, transcript 17/26 up to three
/// lines, 4, meta 13/18. Tapping copies; the meta line turns into the
/// confirmation in place.
struct TranscriptRowView: View {
    let text: String
    let meta: String
    let copied: Bool
    var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(VVCJK.tracked(text.isEmpty ? "（没有转写结果）" : text))
                .vvText(.transcript)
                .foregroundStyle(text.isEmpty || pending ? VVColor.fgTertiary : VVColor.fgPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                Text(meta).monospacedDigit().opacity(copied ? 0 : 1)
                HStack(spacing: 4) {
                    VVCheckGlyph(size: 12, stroke: 2.6)
                    Text("已复制")
                }
                .foregroundStyle(VVColor.fgPrimary)
                .opacity(copied ? 1 : 0)
            }
            .vvText(.footnote)
            .foregroundStyle(VVColor.fgSecondary)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Container

struct HomeView: View {
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var history: HistoryModel
    let navigate: (AppRoute) -> Void
    @State private var copiedID: UUID?
    /// Grouped once per history change, not on every 15 Hz level update
    /// that re-renders this view while recording.
    @State private var sections: [HomeSection] = []

    var body: some View {
        HomeScreen(content: content, copiedID: copiedID, actions: actions)
            .onReceive(history.$records) { records in sections = HomeGrouping.sections(records) }
    }

    private var content: HomeContent {
        var c = HomeContent()
        switch dictation.phase {
        case .starting:
            c.session = .starting
            c.mic = .listening
            c.wave = Waveform.waiting
        case .recording:
            c.session = .listening
            c.mic = .listening
            c.wave = .live(dictation.levelHistory)
        case .finalizing:
            c.session = .finalizing
            c.mic = .finalizing
        case .idle:
            if dictation.sessionPaused {
                c.session = .paused
            } else if dictation.sessionActive {
                c.session = .ready(endsAt: dictation.sessionEndsAt)
            } else {
                c.session = .off
            }
        }
        c.sessionEndable = dictation.sessionActive || dictation.sessionPaused
        c.liveText = dictation.phase == .idle ? nil : dictation.liveText
        c.notice = dictation.notice
        c.outage = dictation.providerOutage
        c.sections = sections
        return c
    }

    private var actions: HomeActions {
        HomeActions(
            copy: copy,
            open: { navigate(.detail($0)) },
            endSession: { Task { await dictation.endSession(reason: .user) } },
            start: { Task { await dictation.toggle(trigger: .app) } },
            cancel: { Task { await dictation.cancel() } },
            finish: { Task { await dictation.stop(reason: .user) } },
            lexicon: { navigate(.lexicon) },
            settings: { navigate(.settings) },
            retryProvider: { dictation.retryUnavailableProvider() }
        )
    }

    private func copy(_ id: UUID) {
        guard let record = history.records.first(where: { $0.id == id }) else { return }
        let text = HistoryModel.displayText(record)
        guard !text.isEmpty else {
            navigate(.detail(id))
            return
        }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedID == id { copiedID = nil }
        }
    }
}

/// Day groups with character and segment counts (今天 / 昨天 / M月d日).
@MainActor
enum HomeGrouping {
    static func sections(_ records: [HistoryRecord], now: Date = Date()) -> [HomeSection] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryRecord]] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.startedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(record)
        }
        return order.map { day in
            let items = byDay[day] ?? []
            let title = dayTitle(day, now: now)
            let chars = items.reduce(0) { $0 + HistoryModel.displayText($1).count }
            let rows = items.map { record in
                HomeRow(
                    id: record.id,
                    text: HistoryModel.displayText(record),
                    meta: meta(record, dayTitle: calendar.isDate(day, inSameDayAs: now) ? nil : title)
                )
            }
            return HomeSection(title: title, summary: "\(VVNumber.grouped(chars)) 字 · \(items.count) 段", rows: rows)
        }
    }

    static let timeFormatter = formatter("HH:mm")
    private static let dayFormatter = formatter("M月d日")
    private static let yearDayFormatter = formatter("yyyy年M月d日")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "昨天"
        }
        let f = calendar.isDate(day, equalTo: now, toGranularity: .year) ? dayFormatter : yearDayFormatter
        return f.string(from: day)
    }

    /// "15:24 · 微信 · 0:09"; older days lead with the day ("昨天 22:40 · …").
    static func meta(_ record: HistoryRecord, dayTitle: String?) -> String {
        var parts = [(dayTitle.map { $0 + " " } ?? "") + timeFormatter.string(from: record.startedAt)]
        if let app = record.targetApplicationName, !app.isEmpty { parts.append(app) }
        parts.append(VVClock.format(record.finishedAt.timeIntervalSince(record.startedAt)))
        if HistoryModel.displayText(record).isEmpty { parts.append("没有结果，可重新转写") }
        return parts.joined(separator: " · ")
    }
}
