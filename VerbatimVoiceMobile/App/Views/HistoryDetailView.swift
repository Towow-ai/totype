import AVFoundation
import SwiftUI
import UIKit

// MARK: - Display model

struct DetailContent: Equatable {
    var title = ""
    var text = ""
    var meta = ""
    var duration: TimeInterval = 0
    var playing = false
    var playedSeconds: TimeInterval = 0
    var bars: [CGFloat] = []
    var hasAudio = true
    var retranscribing = false
    var engineSummary = ""
    var revisionsSummary: String?
    var status: String?
    var copied = false
    var sent = false
}

struct DetailActions {
    var back: () -> Void = {}
    var play: () -> Void = {}
    var copy: () -> Void = {}
    var sendToKeyboard: () -> Void = {}
    var retranscribe: () -> Void = {}
    var engine: () -> Void = {}
    var revisions: () -> Void = {}
}

// MARK: - Screen

/// History detail (DESIGN.md §7.4): the transcript, meta, a playback row,
/// three pills, two drill-in rows.
struct DetailScreen: View {
    let content: DetailContent
    let actions: DetailActions

    var body: some View {
        VVPage(title: content.title, back: actions.back) {
            Menu {
                ShareLink(item: content.text) { Label("分享原话", systemImage: "square.and.arrow.up") }
                Button(action: actions.copy) { Label("复制", systemImage: "doc.on.doc") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(VVColor.fgPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(VVCJK.tracked(content.text.isEmpty ? "（没有转写结果）" : content.text))
                        .vvText(.transcript)
                        .foregroundStyle(content.text.isEmpty ? VVColor.fgTertiary : VVColor.fgPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(content.meta)
                        .vvText(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(VVColor.fgSecondary)
                        .padding(.top, 12)
                    audioRow.padding(.top, 24)
                    pills.padding(.top, 20)
                    if let status = content.status {
                        Text(status)
                            .vvText(.footnote)
                            .foregroundStyle(VVColor.fgSecondary)
                            .padding(.top, 10)
                    }
                    VStack(spacing: 0) {
                        Button(action: actions.engine) {
                            VVCell(title: "引擎与时间线", subtitle: content.engineSummary) { VVChevron() }
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) { HairlineDivider(leadingInset: 16) }
                        if let revisions = content.revisionsSummary {
                            Button(action: actions.revisions) {
                                VVCell(title: "重新转写的版本", subtitle: revisions) { VVChevron() }
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .top) { HairlineDivider(leadingInset: 16) }
                        }
                    }
                    .padding(.horizontal, -16)
                    .padding(.top, 28)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var audioRow: some View {
        HStack(spacing: 12) {
            Button(action: actions.play) {
                Image(systemName: content.playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(VVColor.fgPrimary)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: VVMetric.radiusTall, style: .continuous).fill(VVColor.fillControl))
            }
            .buttonStyle(.plain)
            .disabled(!content.hasAudio)
            .accessibilityLabel(content.playing ? "停止播放" : "播放音频")
            Waveform(
                mode: .replay(content.bars, played: content.duration > 0 ? content.playedSeconds / content.duration : 0),
                bars: 60,
                height: 28
            )
            Text("\(VVClock.format(content.playedSeconds)) / \(VVClock.format(content.duration))")
                .vvText(.footnote)
                .monospacedDigit()
                .foregroundStyle(VVColor.fgSecondary)
                .frame(width: 72, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .opacity(content.hasAudio ? 1 : 0.4)
    }

    private var pills: some View {
        HStack(spacing: 8) {
            Button(action: actions.copy) {
                HStack(spacing: 6) {
                    Image(systemName: content.copied ? "checkmark" : "doc.on.doc").font(.system(size: 12, weight: .regular))
                    Text(content.copied ? "已复制" : "复制")
                }
            }
            .buttonStyle(VVPillStyle())
            Button(action: actions.sendToKeyboard) {
                HStack(spacing: 6) {
                    Image(systemName: content.sent ? "checkmark" : "keyboard").font(.system(size: 11, weight: .regular))
                    Text(content.sent ? "已放到键盘" : "发送到键盘")
                }
            }
            .buttonStyle(VVPillStyle())
            .disabled(content.text.isEmpty)
            Button(content.retranscribing ? "正在重新转写…" : "重新转写", action: actions.retranscribe)
                .buttonStyle(VVPillStyle())
                .disabled(content.retranscribing || !content.hasAudio)
        }
    }
}

// MARK: - Container

struct HistoryDetailView: View {
    @EnvironmentObject private var history: HistoryModel
    let recordID: UUID
    let navigate: (AppRoute) -> Void
    let back: () -> Void
    @State private var bars: [CGFloat] = []
    @State private var playStart: Date?
    @State private var copied = false
    @State private var sent = false

    var body: some View {
        if let record = history.records.first(where: { $0.id == recordID }) {
            TimelineView(.periodic(from: .now, by: playStart == nil ? 3600 : 0.1)) { context in
                DetailScreen(content: content(record, now: context.date), actions: actions(record))
            }
            .task(id: recordID) { await loadBars(record) }
            .onChange(of: history.playingID) { _, id in
                playStart = id == recordID ? Date() : nil
            }
        } else {
            VVPage(title: nil, back: back) {
                Text("记录不存在").vvText(.body).foregroundStyle(VVColor.fgSecondary).padding(.top, 40)
            }
        }
    }

    private func content(_ record: HistoryRecord, now: Date) -> DetailContent {
        var c = DetailContent()
        let text = HistoryModel.displayText(record)
        c.title = DetailFormat.title(record.startedAt)
        c.text = text
        c.meta = DetailFormat.meta(record, text: text)
        c.duration = record.finishedAt.timeIntervalSince(record.startedAt)
        c.playing = history.playingID == record.id
        if c.playing, let playStart { c.playedSeconds = min(c.duration, now.timeIntervalSince(playStart)) }
        c.bars = bars
        c.hasAudio = record.audioRelativePath != nil
        c.retranscribing = history.retranscribing.contains(record.id)
        c.engineSummary = DetailFormat.engine(record)
        c.revisionsSummary = DetailFormat.revisions(record)
        c.status = history.status
        c.copied = copied
        c.sent = sent
        return c
    }

    private func actions(_ record: HistoryRecord) -> DetailActions {
        DetailActions(
            back: back,
            play: { history.togglePlayback(record) },
            copy: {
                let text = HistoryModel.displayText(record)
                guard !text.isEmpty else { return }
                UIPasteboard.general.string = text
                flash($copied)
            },
            sendToKeyboard: {
                let text = HistoryModel.displayText(record)
                guard !text.isEmpty else { return }
                // A fresh ID: the mailbox is idempotent per session, and this
                // record's own entry may already be inserted.
                if (try? MobileEnvironment.mailbox.post(sessionID: UUID(), text: text)) != nil {
                    DarwinNotifier.post(.mailboxChanged)
                    flash($sent)
                }
            },
            retranscribe: { history.retranscribe(record) },
            engine: { navigate(.engine(record.id)) },
            revisions: { navigate(.revisions(record.id)) }
        )
    }

    private func flash(_ flag: Binding<Bool>) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            flag.wrappedValue = false
        }
    }

    /// 60 RMS buckets from the archived audio (real levels, not decoration).
    private func loadBars(_ record: HistoryRecord) async {
        guard let url = try? await HistoryStore.shared.audioURL(for: record) else { return }
        let computed = await Task.detached(priority: .utility) { () -> [CGFloat] in
            guard let chunks = try? ArchivedAudioReader.pcm16Chunks(from: url) else { return [] }
            var samples: [Int16] = []
            for chunk in chunks {
                chunk.data.withUnsafeBytes { raw in samples.append(contentsOf: raw.bindMemory(to: Int16.self)) }
            }
            guard !samples.isEmpty else { return [] }
            let n = 60, per = max(1, samples.count / n)
            var rms: [Double] = []
            for i in 0..<n {
                let slice = samples[min(samples.count, i * per)..<min(samples.count, (i + 1) * per)]
                let sum = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
                rms.append(slice.isEmpty ? 0 : (sum / Double(slice.count)).squareRoot())
            }
            let peak = max(1, rms.max() ?? 1)
            return rms.map { CGFloat(pow($0 / peak, 0.7)) }
        }.value
        bars = computed
    }
}

@MainActor
enum DetailFormat {
    static func title(_ date: Date) -> String {
        HomeGrouping.dayTitle(Calendar.current.startOfDay(for: date)) + " " + HomeGrouping.timeFormatter.string(from: date)
    }

    static func meta(_ record: HistoryRecord, text: String) -> String {
        var parts: [String] = []
        if let app = record.targetApplicationName, !app.isEmpty { parts.append(app) }
        parts.append(VVClock.format(record.finishedAt.timeIntervalSince(record.startedAt)))
        parts.append("\(text.count) 字")
        parts.append(status(record.insertionStatus))
        return parts.joined(separator: " · ")
    }

    static func status(_ s: InsertionStatus) -> String {
        switch s {
        case .inserted: return "已插入"
        case .dispatched: return "已交给键盘"
        case .previewOnly: return "未插入"
        case .copied: return "已复制"
        case .canceled: return "已取消"
        case .failed: return "失败"
        case .unconfirmed: return "未确认"
        }
    }

    /// "Soniox 主 · 百炼热备一致 · 首帧 0.18 s"
    static func engine(_ record: HistoryRecord) -> String {
        var parts: [String] = []
        let primaryID = record.effectiveProviderID ?? record.primary?.providerID
        parts.append(MobileEnvironment.displayName(providerID: primaryID) + " 主")
        if let comparison = record.comparisons?.first {
            let same = comparison.text == record.primary?.text
            parts.append(MobileEnvironment.displayName(providerID: comparison.providerID) + (same ? "热备一致" : "热备不同"))
        }
        if let ms = record.primary?.firstPartialLatencyMilliseconds {
            parts.append(String(format: "首帧 %.2f s", Double(ms) / 1000))
        }
        return parts.joined(separator: " · ")
    }

    static func revisions(_ record: HistoryRecord) -> String? {
        guard let revisions = record.transcriptRevisions, let last = revisions.last else { return nil }
        return "\(revisions.count) 个 · \(MobileEnvironment.displayName(providerID: last.providerID)) \(HomeGrouping.timeFormatter.string(from: last.createdAt))"
    }
}

// MARK: - Drill-ins

/// Engine results and timings for one record.
struct EngineDetailView: View {
    @EnvironmentObject private var history: HistoryModel
    let recordID: UUID
    let back: () -> Void

    var body: some View {
        VVPage(title: "引擎与时间线", back: back) {
            ScrollView {
                if let record = history.records.first(where: { $0.id == recordID }) {
                    VStack(alignment: .leading, spacing: 0) {
                        let summaries = [record.primary].compactMap { $0 } + (record.comparisons ?? [])
                        ForEach(Array(summaries.enumerated()), id: \.offset) { index, summary in
                            VVSectionHeader(title: MobileEnvironment.displayName(providerID: summary.providerID) + (index == 0 ? " · 主" : " · 热备"), first: index == 0)
                            Text(summary.text.isEmpty ? (summary.error ?? "（没有结果）") : summary.text)
                                .vvText(.transcript)
                                .foregroundStyle(summary.text.isEmpty ? VVColor.fgTertiary : VVColor.fgPrimary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 16)
                            Text(timing(summary))
                                .vvText(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(VVColor.fgSecondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func timing(_ s: ProviderSummary) -> String {
        var parts = [s.model]
        if let first = s.firstPartialLatencyMilliseconds { parts.append("首帧 \(first) ms") }
        if let finalize = s.finalizeLatencyMilliseconds { parts.append("收尾 \(finalize) ms") }
        return parts.joined(separator: " · ")
    }
}

/// Re-transcriptions, newest last; the original is never overwritten.
struct RevisionsView: View {
    @EnvironmentObject private var history: HistoryModel
    let recordID: UUID
    let back: () -> Void
    @State private var copiedID: UUID?

    var body: some View {
        VVPage(title: "重新转写的版本", back: back) {
            ScrollView {
                let revisions = history.records.first(where: { $0.id == recordID })?.transcriptRevisions ?? []
                VStack(spacing: 0) {
                    VVRows(data: revisions) { revision in
                        TranscriptRowView(
                            text: revision.text.isEmpty ? (revision.error ?? "") : revision.text,
                            meta: "\(MobileEnvironment.displayName(providerID: revision.providerID)) · \(DetailFormat.title(revision.createdAt))",
                            copied: copiedID == revision.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !revision.text.isEmpty else { return }
                            UIPasteboard.general.string = revision.text
                            copiedID = revision.id
                        }
                    }
                }
            }
        }
    }
}
