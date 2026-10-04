import SwiftUI

struct ReturnContent: Equatable {
    var phase: RecordingPhase = .recording
    var elapsed: MicControl.Elapsed = .none
    var wave: Waveform.Mode = .live([])
    var notice: String?
}

struct ReturnActions {
    var stay: () -> Void = {}
    var cancel: () -> Void = {}
    var finish: () -> Void = {}
}

/// Shown after the keyboard opened the app to start recording (DESIGN.md
/// §7.4, §13). iOS 26.4+ does not return to the previous app by itself and
/// there is no public API for it, so the page has one job: say recording
/// already runs and point at the system back link, which iOS draws in the
/// status bar's top-left corner (left of the Dynamic Island, where the
/// clock was) as "◀ <app name>". The app cannot learn the host's name, so
/// the page gives 微信 as an example instead of drawing a fake link that
/// could sit over the real one.
struct ReturnScreen: View {
    let content: ReturnContent
    let actions: ReturnActions

    private var micPhase: MicControl.Phase {
        switch content.phase {
        case .finalizing: return .finalizing
        case .idle: return .ready
        case .starting, .recording: return .listening
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let top = VVLayout.top(proxy.safeAreaInsets.top)
            ZStack(alignment: .top) {
                // The arrow's tip sits under the status bar's left half,
                // where iOS draws "◀ 微信".
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("点左上角的 ◀ 返回").vvText(.headline)
                            .foregroundStyle(VVColor.fgPrimary)
                        Text("状态栏原来显示时间的地方，会写着刚才的 App，比如「◀ 微信」。沿屏幕底部横条向右滑也能回去。")
                            .vvText(.subhead)
                            .foregroundStyle(VVColor.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 3)
                }
                .foregroundStyle(VVColor.fgPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.trailing, 24)
                .padding(.top, top + 6)

                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        if content.phase == .recording {
                            Circle().fill(VVColor.stateRecording).frame(width: 10, height: 10)
                        }
                        Text(stateTitle).vvText(.headline)
                    }
                    .foregroundStyle(VVColor.fgPrimary)
                    ElapsedText(elapsed: content.elapsed)
                        .vvText(.timerLarge)
                        .foregroundStyle(content.phase == .recording ? VVColor.fgPrimary : VVColor.fgSecondary)
                    Text("回到刚才的 App 接着说，说完点一下键盘中间的波形，文字会直接出现在输入框里。")
                        .vvText(.subhead)
                        .foregroundStyle(VVColor.fgSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, top + 266)

                VStack(spacing: 0) {
                    Spacer()
                    Button(action: actions.stay) {
                        Text("留在 \(MobileIdentity.displayName) 里")
                            .vvText(.subhead)
                            .foregroundStyle(VVColor.fgSecondary)
                            .frame(height: 44)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, -6)
                    MicBar(
                        phase: micPhase,
                        wave: content.wave,
                        lined: false,
                        onCancel: actions.cancel,
                        onFinish: actions.finish
                    )
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(VVColor.bgCanvas.ignoresSafeArea())
    }

    private var stateTitle: String {
        switch content.phase {
        case .recording: return "已经在录音"
        case .starting: return "正在启动麦克风…"
        case .finalizing: return "识别中…"
        case .idle: return content.notice ?? "录音已结束"
        }
    }
}

struct ReturnView: View {
    @EnvironmentObject private var dictation: DictationController

    var body: some View {
        ReturnScreen(content: content, actions: ReturnActions(
            stay: { dictation.showReturnHint = false },
            cancel: { Task { await dictation.cancel() } },
            finish: { Task { await dictation.stop(reason: .user) } }
        ))
    }

    private var content: ReturnContent {
        var c = ReturnContent(phase: dictation.phase, notice: dictation.notice)
        if dictation.phase == .recording, let start = dictation.recordingStartedAt {
            c.elapsed = .running(since: start)
        }
        switch dictation.phase {
        case .finalizing: c.wave = .line()
        case .recording: c.wave = .live(dictation.levelHistory)
        default: c.wave = Waveform.waiting
        }
        return c
    }
}
