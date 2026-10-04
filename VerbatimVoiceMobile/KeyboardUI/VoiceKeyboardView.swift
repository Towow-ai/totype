import SwiftUI
import UIKit

/// Everything the keyboard face shows, as a value. The extension derives it
/// from `KeyboardModel`; the app's DEBUG design preview builds it by hand.
struct VoiceKeyboardState: Equatable {
    /// One status line (DESIGN.md §7.1); each state has its own sentence.
    enum Status: Equatable {
        /// Live session, nothing to say: the row stays empty (or shows
        /// "已用阿里云"). No standby countdown here (DESIGN.md §13, 2026-10-01).
        case quiet
        /// No session: the first tap opens the app.
        case first
        case paused
        case noFullAccess
        case waitingForApp
        case starting
        case listening
        case finalizing
        case inserted(count: Int)
        case failed(reason: String)
        /// The app is re-transcribing the failed dictation's audio.
        case retrying
        /// A retry failed too: "重试" again, or "稍后再试" (retried when the
        /// network comes back or the next session starts).
        case retryFailed(reason: String)
        case pending(preview: String)
        case notice(String)
    }

    enum Layer: Equatable { case voice, letters }

    var layer: Layer = .voice
    var status: Status = .first
    var mic: MicControl.Phase = .ready
    var elapsed: MicControl.Elapsed = .none
    var wave: Waveform.Mode = .line()
    var micEnabled = true
    var micBusy = false
    /// When set, the ready circle is a `Link` to this URL (no live session).
    var micLink: URL?
    var returnTitle = "换行"
    /// "已用阿里云" while the hot standby carries dictation (primary out of
    /// balance or key); shown on the quiet row and after the inserted sentence.
    var fallbackNote: String?
}

struct VoiceKeyboardActions {
    var keys = KeyboardKeyActions()
    var mic: () -> Void = {}
    var micLinkTapped: () -> Void = {}
    var cancel: () -> Void = {}
    var finish: () -> Void = {}
    var undo: () -> Void = {}
    var retry: () -> Void = {}
    var deferRetry: () -> Void = {}
    var insertPending: () -> Void = {}
    var discardPending: () -> Void = {}
    var setLayer: (VoiceKeyboardState.Layer) -> Void = { _ in }
}

/// The whole keyboard face: status row (44) over the voice layer or the
/// letter layer, on the measured keyboard background. Geometry from
/// `VVGrid`; nothing here depends on the extension, so the app can render it.
struct VoiceKeyboardView: View {
    let state: VoiceKeyboardState
    let actions: VoiceKeyboardActions
    var globe: GlobeKeySource = .none
    /// Extra keyboard-coloured space under the keys (the 34pt home area in
    /// previews; zero in the extension, where the system owns that strip).
    var homeArea: CGFloat = 0

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let grid = VVGrid(width: proxy.size.width, compact: verticalSizeClass == .compact)
            VStack(spacing: 0) {
                KeyboardStatusRow(state: state, actions: actions, compactText: state.layer == .letters)
                    .frame(height: grid.statusHeight)
                switch state.layer {
                case .voice:
                    voiceLayer(grid)
                case .letters:
                    LetterKeyboardView(
                        grid: grid,
                        globe: globe,
                        returnTitle: state.returnTitle,
                        actions: actions.keys,
                        switchToVoice: { actions.setLayer(.voice) }
                    )
                    .frame(height: grid.keyAreaHeight + grid.bottomInset)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: VVGrid(width: 0, compact: verticalSizeClass == .compact).contentHeight + homeArea)
        .background(VVColor.bgKeyboard)
    }

    private func voiceLayer(_ grid: VVGrid) -> some View {
        let area = grid.keyAreaHeight + grid.bottomInset
        // Delete sits top-right on columns 9–10 of row 1 (DESIGN.md §13.4),
        // in every mic phase: deleting never touches the recording. Finish
        // gives up that cell so the two never share a touch.
        let deleteSpan = grid.span(8, 2)
        let deleteFace = CGRect(x: deleteSpan.x, y: grid.rowY(0), width: deleteSpan.w, height: grid.keyHeight)
        let deleteHit = KeyCellGeometry.hit(for: deleteFace, grid: grid, areaHeight: area)
        return ZStack(alignment: .topLeading) {
            MicControl(
                phase: state.mic,
                style: .keyboard,
                grid: grid,
                scale: grid.compact ? .keyboardCompact : .keyboard,
                bandHeight: grid.bandHeight,
                wave: state.wave,
                elapsed: state.elapsed,
                readyEnabled: state.micEnabled,
                readyBusy: state.micBusy,
                ready: state.micLink.map { .link($0, onTap: actions.micLinkTapped) } ?? .perform(actions.mic),
                onCancel: actions.cancel,
                onFinish: actions.finish,
                finishTopRightReserve: deleteHit.maxY
            )
            DeleteKey(hit: deleteHit, face: deleteFace, actions: actions.keys)
            KeyboardBottomRow(
                layer: .voice,
                grid: grid,
                areaHeight: area,
                globe: globe,
                returnTitle: state.returnTitle,
                actions: actions.keys,
                toggleTitle: "ABC",
                onToggle: { actions.setLayer(.letters) }
            )
        }
        .frame(width: grid.width, height: area, alignment: .topLeading)
    }
}

/// Status row (DESIGN.md §7.1): 15/20, the leading phrase Medium in the
/// primary colour, the rest secondary; a pill on the right when there is
/// something to do.
struct KeyboardStatusRow: View {
    let state: VoiceKeyboardState
    let actions: VoiceKeyboardActions
    /// Letters layer: only the leading phrase.
    var compactText = false

    @State private var shake: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            text
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(textIdentity)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            pill
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .vvText(.subhead)
        .foregroundStyle(VVColor.fgSecondary)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .offset(x: shake)
        .animation(.vv(VVMotion.settle, reduceMotion: reduceMotion), value: textIdentity)
        .onChange(of: isFailed) { _, failed in
            guard failed else { return }
            VVHaptics.error()
            guard !reduceMotion else { return }
            Task { @MainActor in
                // 6 pt, twice, 220 ms in total.
                for offset in [6.0, -6.0, 6.0, -6.0, 0.0] {
                    withAnimation(.spring(duration: 0.22, bounce: 0.6)) { shake = offset }
                    try? await Task.sleep(nanoseconds: 44_000_000)
                }
            }
        }
        .onChange(of: isInserted) { _, inserted in
            if inserted { VVHaptics.inserted() }
        }
    }

    private var isFailed: Bool {
        switch state.status {
        case .failed, .retryFailed: return true
        default: return false
        }
    }
    private var isInserted: Bool { if case .inserted = state.status { return true } else { return false } }

    /// Changes only when the sentence changes kind, so ticking timers do
    /// not re-run the slide-in.
    private var textIdentity: String {
        switch state.status {
        case .quiet: return "quiet"
        case .first: return "first"
        case .paused: return "paused"
        case .noFullAccess: return "access"
        case .waitingForApp: return "waiting"
        case .starting: return "starting"
        case .listening: return "listening"
        case .finalizing: return "finalizing"
        case .inserted(let n): return "inserted\(n)"
        case .failed(let r): return "failed\(r)"
        case .retrying: return "retrying"
        case .retryFailed(let r): return "retryFailed\(r)"
        case .pending(let p): return "pending\(p)"
        case .notice(let n): return "notice\(n)"
        }
    }

    @ViewBuilder
    private var text: some View {
        switch state.status {
        case .quiet:
            if let note = state.fallbackNote { en(main(note)) } else { Text(" ") }
        case .first:
            en(Text("点麦克风开始 · 首次会打开 \(MobileIdentity.displayName)，再滑回来"))
        case .paused:
            en(main("会话被打断") + Text(" · 点麦克风会打开 \(MobileIdentity.displayName) 恢复"))
        case .noFullAccess:
            en(main("需要完全访问") + Text(" · 设置 → 键盘 → \(MobileIdentity.displayName)"))
        case .waitingForApp:
            en(main("正在叫醒 \(MobileIdentity.displayName)") + Text("…"))
        case .starting:
            en(main("正在启动麦克风") + Text("…"))
        case .listening:
            en(main("正在听") + Text(" · 说完点一下波形"))
        case .finalizing:
            en(main("识别中") + Text("…"))
        case .inserted(let count):
            en(withFallbackNote(main("已插入 ") + Text("\(count)").fontWeight(.medium).monospacedDigit().foregroundStyle(VVColor.fgPrimary) + main(" 字")))
        case .failed(let reason):
            en(main("没插入") + Text(" · \(reason)"))
        case .retrying:
            en(main("正在重试") + Text("…"))
        case .retryFailed(let reason):
            en(main("仍未成功") + Text(" · \(reason)"))
        case .pending(let preview):
            en(Text(preview))
        case .notice(let notice):
            en(Text(notice))
        }
    }

    private func withFallbackNote(_ t: Text) -> Text {
        guard !compactText, let note = state.fallbackNote else { return t }
        return t + Text(" · \(note)")
    }

    /// Concatenated runs do not pick up the view-level typesetting language.
    private func en(_ t: Text) -> Text { t.typesettingLanguage(Locale.Language(identifier: "en")) }

    private func main(_ s: String) -> Text {
        Text(s).fontWeight(.medium).foregroundStyle(VVColor.fgPrimary)
    }

    @ViewBuilder
    private var pill: some View {
        switch state.status {
        case .inserted:
            Button {
                VVHaptics.undo()
                actions.undo()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 13, weight: .semibold))
                    Text("撤销")
                }
            }
            .buttonStyle(VVPillStyle(onKeyboard: true))
            .transition(.opacity)
        case .failed:
            Button("重试", action: actions.retry)
                .buttonStyle(VVPillStyle(onKeyboard: true))
        case .retryFailed:
            HStack(spacing: 6) {
                Button("稍后再试", action: actions.deferRetry)
                    .buttonStyle(VVPillStyle(onKeyboard: true))
                Button("重试", action: actions.retry)
                    .buttonStyle(VVPillStyle(onKeyboard: true))
            }
        case .pending:
            Button("插入", action: actions.insertPending)
                .buttonStyle(VVPillStyle(prominent: true, onKeyboard: true))
                .contextMenu {
                    Button("忽略这条", role: .destructive, action: actions.discardPending)
                }
        default:
            EmptyView()
        }
    }
}
