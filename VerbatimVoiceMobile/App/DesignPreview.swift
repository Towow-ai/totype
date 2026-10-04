#if DEBUG
import SwiftUI

/// DEBUG only: `-designPreview <screen> [-designTheme dark]` renders one
/// design-v2 screen with fixed data, for simulator screenshots compared
/// against the design screens (see docs/DESIGN.md).
enum DesignPreview {
    static var screen: String? { UserDefaults.standard.string(forKey: "designPreview") }
    static var dark: Bool { UserDefaults.standard.string(forKey: "designTheme") == "dark" }
}

struct DesignPreviewRoot: View {
    let screen: String

    var body: some View {
        content
            .preferredColorScheme(DesignPreview.dark || screen == "lockscreen" ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    @ViewBuilder
    private var content: some View {
        if screen.hasPrefix("kb-") {
            KeyboardPreviewHost(state: Self.keyboardState(screen))
        } else {
            AppScreenPreview(screen: screen)
        }
    }

    static let sampleTranscript = "我觉得这个方案可以，先不要改我的原话，然后那个会议记录都要保留。"

    static func keyboardState(_ screen: String) -> VoiceKeyboardState {
        var s = VoiceKeyboardState()
        s.returnTitle = "发送"
        s.status = .quiet
        switch screen.replacingOccurrences(of: "-dark", with: "") {
        case "kb-first":
            s.status = .first
        case "kb-listening":
            s.status = .listening
            s.mic = .listening
            s.elapsed = .frozen(7)
            s.wave = .fixed(VVSampleLevels.make(48, seed: 11))
        case "kb-finalizing":
            s.status = .finalizing
            s.mic = .finalizing
            s.elapsed = .frozen(9)
            s.wave = .line(phase: Waveform.restPhase)
        case "kb-inserted":
            s.status = .inserted(count: 49)
        case "kb-failed":
            s.status = .failed(reason: "网络不通，录音已留在历史")
        case "kb-pending":
            s.status = .pending(preview: sampleTranscript)
        case "kb-letters":
            s.layer = .letters
        case "kb-starting":
            s.status = .starting
            s.mic = .listening
            s.wave = Waveform.waiting
        default:
            break
        }
        return s
    }
}

/// A plain host behind the keyboard (the mockups show WeChat; only the
/// keyboard region is compared).
private struct KeyboardPreviewHost: View {
    let state: VoiceKeyboardState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            (scheme == .dark ? Color(white: 0.067) : Color(red: 0.929, green: 0.929, blue: 0.929))
            VoiceKeyboardView(state: state, actions: VoiceKeyboardActions(), globe: .preview, homeArea: VVMetric.keyboardHomeArea)
        }
        .ignoresSafeArea()
    }
}

/// App screens with the mockups' data.
private struct AppScreenPreview: View {
    let screen: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        switch screen.replacingOccurrences(of: "-dark", with: "") {
        case "app-home": HomeScreen(content: Self.home, actions: HomeActions())
        case "app-home-listening": HomeScreen(content: Self.homeListening, actions: HomeActions())
        case "app-return":
            ReturnScreen(content: ReturnContent(phase: .recording, elapsed: .frozen(7), wave: .fixed(VVSampleLevels.make(56, seed: 11))), actions: ReturnActions())
        case "app-detail": DetailScreen(content: Self.detail, actions: DetailActions())
        case "app-lexicon": LexiconScreen(terms: Self.terms, draft: $draft)
        case "app-settings": SettingsScreen(content: Self.settings, actions: SettingsActions())
        case "app-onboarding":
            ZStack(alignment: .bottom) {
                OnboardingScreen(steps: Self.steps, trial: $draft, focus: $focused)
                VoiceKeyboardView(state: Self.onboardingKeyboard, actions: VoiceKeyboardActions(), globe: .preview, homeArea: VVMetric.keyboardHomeArea)
            }
            .ignoresSafeArea(edges: .bottom)
        case "island": IslandPreview()
        case "lockscreen": LockPreview(light: false)
        case "lockscreen-light": LockPreview(light: true)
        default: Text("未知画面：\(screen)")
        }
    }

    static var onboardingKeyboard: VoiceKeyboardState {
        var kb = DesignPreviewRoot.keyboardState("kb-first")
        kb.returnTitle = "换行"
        return kb
    }

    /// The bottom bar while listening: ✕ on the left, the capsule centred,
    /// nothing on the right.
    static var homeListening: HomeContent {
        var c = home
        c.session = .listening
        c.sessionEndable = true
        c.mic = .listening
        c.wave = .fixed(VVSampleLevels.make(56, seed: 11))
        c.liveText = "我觉得这个方案可以，先不要改我的原话"
        return c
    }

    static var home: HomeContent {
        var c = HomeContent()
        c.session = .ready(endsAt: nil)
        c.fixedRemaining = 252
        c.sessionEndable = true
        let rows: [(String, String)] = [
            (DesignPreviewRoot.sampleTranscript, "15:24 · 微信 · 0:09"),
            ("那个 PR 我晚点再看，先把 Soniox 的 context 结构化那块跑一下评测，呃，跑完把 P50 发我。", "15:02 · 备忘录 · 0:11"),
            ("明天下午三点开会，记得带上季度报表。", "14:37 · 微信 · 0:07"),
            ("上个月的转化率是 4.2%，先别下结论，等完整数据出来再说。", "11:15 · Slack · 0:12"),
        ]
        let yrows: [(String, String)] = [
            ("帮我把退款流程的三个状态写成表，别加解释。", "昨天 22:40 · ChatGPT · 0:06"),
            ("这段先原样记下来：我们不润色，不改词序，不删口头语。", "昨天 18:03 · 备忘录 · 0:08"),
        ]
        c.sections = [
            HomeSection(title: "今天", summary: "1,284 字 · 23 段", rows: rows.map { HomeRow(id: UUID(), text: $0.0, meta: $0.1) }),
            HomeSection(title: "昨天", summary: "3,902 字 · 61 段", rows: yrows.map { HomeRow(id: UUID(), text: $0.0, meta: $0.1) }),
        ]
        return c
    }

    static var detail: DetailContent {
        var c = DetailContent()
        c.title = "今天 15:24"
        c.text = "我觉得这个方案可以，先不要改我的原话，然后那个会议记录都要保留。呃，还有一个，就是 iPhone 那边的键盘，录音中要能看到音波和时长，不然我不知道它到底在不在听。"
        c.meta = "微信 · 0:09 · 72 字 · 已插入"
        c.duration = 9
        c.playedSeconds = 3.24
        c.bars = VVSampleLevels.make(60, seed: 5)
        c.engineSummary = "Soniox 主 · 百炼热备一致 · 首帧 0.18 s"
        c.revisionsSummary = "1 个 · 百炼 15:31"
        return c
    }

    static let terms: [LexiconTermRow] = [
        ("Claude Code", "克劳德扣的、Cloud Code"), ("Kubernetes", "库伯奈提斯、Cooper"), ("Soniox", "索尼克斯、Sonics"),
        ("TypeScript", "太普斯克瑞普特、Type Script"), ("Opus", "欧普斯"), ("PRD", "皮阿滴"), ("Vercel", ""), ("Supabase", "苏帕贝斯"),
        ("Wispr Flow", "微斯博 flow"), ("Fable", ""),
    ].map { LexiconTermRow(id: $0.0, canonical: $0.0, aliases: $0.1.isEmpty ? [] : $0.1.components(separatedBy: "、")) }

    static var settings: SettingsContent {
        var c = SettingsContent()
        c.sonioxSaved = true
        c.sonioxStatus = "连接正常 · 往返 212 ms"
        c.region = "北京"
        c.idleTimeout = "5 分钟"
        c.maximumLength = "3 分钟"
        c.keyboardSeen = true
        c.localStatus = "可用"
        c.localReady = true
        c.version = "0.4 (112)"
        c.device = "iPhone 17 Pro · iOS 27.0"
        return c
    }

    static let steps: [OnboardingStep] = [
        OnboardingStep(id: 1, title: "添加 \(MobileIdentity.displayName) 键盘", state: .done),
        OnboardingStep(id: 2, title: "允许完全访问", detail: "只用于和主 App 交换文字与指令，键盘不联网。", state: .done),
        OnboardingStep(id: 3, title: "选识别引擎", detail: "连接正常 · 往返 212 ms", state: .done),
        OnboardingStep(id: 4, title: "在真输入框里说一句", detail: "长按地球键切到 \(MobileIdentity.displayName)，点麦克风，说完点一下中间的波形。文字出现在下面就算成功。", state: .now),
    ]
}

/// The island faces inside drawn island shapes (the real island is drawn by
/// the system; this checks the content layout). Only listening and
/// recognising exist; the idle session has no activity (DESIGN.md §13).
private struct IslandPreview: View {
    private let rec = VVActivityState(phase: .recording, sessionActive: true, sessionPaused: false, fixedTimer: "0:07")
    private let fin = VVActivityState(phase: .finalizing, sessionActive: true, sessionPaused: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            label("紧凑 · 正在听（左：红点；右：计时，系统 timer 文本驱动）")
            compact(rec)
            label("紧凑 · 识别中（左：麦克风轮廓；右：…）")
            compact(fin)
            label("最小 · 与其他活动并存（只剩一个红点 / 一个麦克风轮廓）")
            HStack(spacing: 10) {
                ActivityGlyph(state: rec, micSize: 13).frame(width: 37, height: 37).background(Circle().fill(.black))
                ActivityGlyph(state: fin, micSize: 13).frame(width: 37, height: 37).background(Circle().fill(.black))
            }
            .environment(\.colorScheme, .dark)
            label("展开 · 正在听（长按）：取消 / 完成")
            expanded(rec)
            label("展开 · 识别中：没有按钮")
            expanded(fin)
            label("听写结束即结束活动；会话待命不在灵动岛和锁屏出现")
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VVColor.bgSunken)
        .ignoresSafeArea()
        .statusBarHidden()
    }

    private func label(_ s: String) -> some View {
        Text(s).vvText(.footnote).foregroundStyle(VVColor.fgSecondary).padding(.top, 10).padding(.bottom, -4)
    }

    private func compact(_ s: VVActivityState) -> some View {
        HStack {
            ActivityGlyph(state: s, micSize: 13)
            Spacer()
            ActivityTimer(state: s).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(s.recording ? 1 : 0.92))
        }
        .padding(.leading, 11).padding(.trailing, 10)
        .frame(width: 190, height: 37)
        .background(Capsule().fill(.black))
        .environment(\.colorScheme, .dark)
    }

    private func expanded(_ s: VVActivityState) -> some View {
        VStack(spacing: 12) {
            HStack {
                IslandExpandedTitle(state: s)
                Spacer()
                IslandExpandedTimer(state: s)
            }
            .frame(height: 20)
            IslandExpandedBody(state: s) {
                if s.recording {
                    ActivityButtonFace(kind: .cancel, island: true)
                    ActivityButtonFace(kind: .finish, island: true)
                }
            }
        }
        .padding(14)
        .frame(width: 371)
        .background(RoundedRectangle(cornerRadius: VVMetric.radiusIsland, style: .continuous).fill(.black))
    }
}

/// Lock Screen card while listening (the system draws the card shape).
/// Dark by default as the mockup; `-designTheme light` shows the light card,
/// where the recording dot and waveform use the light state/recording grey.
private struct LockPreview: View {
    let light: Bool

    var body: some View {
        let state = VVActivityState(phase: .recording, sessionActive: true, sessionPaused: false, fixedTimer: "0:07")
        ZStack(alignment: .topLeading) {
            (light ? Color(red: 0.80, green: 0.82, blue: 0.86) : Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255)).ignoresSafeArea()
            LockScreenActivityFace(state: state) {
                ActivityButtonFace(kind: .cancel)
                ActivityButtonFace(kind: .finish)
            }
            .frame(width: 361)
            .background(RoundedRectangle(cornerRadius: VVMetric.radiusSheet, style: .continuous).fill(VVActivity.cardBackground))
            .offset(x: 16, y: 570)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, light ? .light : .dark)
    }
}
#endif
