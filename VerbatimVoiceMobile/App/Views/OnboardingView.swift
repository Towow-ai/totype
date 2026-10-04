import SwiftUI
import UIKit

struct OnboardingStep: Identifiable, Equatable {
    enum State: Equatable { case done, now, todo }
    let id: Int
    let title: String
    var detail: String?
    var state: State
}

/// First run (screens/app-onboarding): four steps; done steps show the
/// check where the number was; the last step is a real text field, so
/// "说一句" happens with the keyboard inside the checklist.
struct OnboardingScreen: View {
    let steps: [OnboardingStep]
    var tap: (Int) -> Void = { _ in }
    @Binding var trial: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: VVLayout.navHeight)
                Text(VVCJK.tracked("开始之前", 0.41))
                    .vvText(.largeTitle)
                    .foregroundStyle(VVColor.fgPrimary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52, alignment: .top)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            stepRow(step)
                                .overlay(alignment: .top) { if index > 0 { HairlineDivider(leadingInset: 58) } }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.never)
            }
            .padding(.top, VVLayout.top(proxy.safeAreaInsets.top))
            .ignoresSafeArea(edges: .top)
        }
        .background(VVColor.bgCanvas.ignoresSafeArea())
    }

    private func stepRow(_ step: OnboardingStep) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(step.state == .todo ? VVColor.fillControl : (step.state == .done ? VVColor.fillKeyProminent : VVColor.fgPrimary))
                if step.state == .done {
                    VVCheckGlyph(size: 15).foregroundStyle(VVColor.fgInverse)
                } else {
                    Text("\(step.id)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(step.state == .now ? VVColor.fgInverse : VVColor.fgPrimary)
                }
            }
            .frame(width: 28, height: 28)
            .padding(.top, -2)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .vvText(.body)
                    .foregroundStyle(step.state == .done ? VVColor.fgSecondary : VVColor.fgPrimary)
                if let detail = step.detail {
                    Text(detail)
                        .vvText(.footnote)
                        .foregroundStyle(VVColor.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step.id == 4 {
                    TextField("", text: $trial, prompt: Text("在这里试一句").foregroundStyle(VVColor.fgTertiary), axis: .vertical)
                        .vvText(.body)
                        .foregroundStyle(VVColor.fgPrimary)
                        .tint(VVColor.fgPrimary)
                        .focused(focus)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: VVMetric.radiusTall, style: .continuous).fill(VVColor.bgSunken))
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { tap(step.id) }
    }
}

/// Steps derived from what the app can observe: the keyboard marks its
/// presence only with Full Access, a key is in the keychain, and a first
/// dictation exists in history.
struct OnboardingView: View {
    @EnvironmentObject private var history: HistoryModel
    let navigate: (AppRoute) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardSeen = false
    @State private var hasKey = false
    @State private var localAllowed = false
    @State private var trial = ""
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingScreen(steps: steps, tap: tap, trial: $trial, focus: $focused)
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private var steps: [OnboardingStep] {
        let done1 = keyboardSeen, done3 = hasKey || localAllowed, done4 = !history.records.isEmpty
        let states: [Bool] = [done1, done1, done3, done4]
        let firstOpen = states.firstIndex(of: false)
        func state(_ i: Int) -> OnboardingStep.State { states[i] ? .done : (i == firstOpen ? .now : .todo) }
        return [
            OnboardingStep(id: 1, title: "添加 \(MobileIdentity.displayName) 键盘", detail: done1 ? nil : "设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → \(MobileIdentity.displayName)。", state: state(0)),
            OnboardingStep(id: 2, title: "允许完全访问", detail: "只用于和主 App 交换文字与指令，键盘不联网。", state: state(1)),
            OnboardingStep(id: 3, title: "选识别引擎", detail: engineDetail, state: state(2)),
            OnboardingStep(id: 4, title: "在真输入框里说一句", detail: "长按地球键切到 \(MobileIdentity.displayName)，点麦克风，说完点一下中间的波形。文字出现在下面就算成功。", state: state(3)),
        ]
    }

    private var engineDetail: String? {
        if hasKey { return ConnectionStatusStore.shared.results[MobileEnvironment.sonioxProviderID] }
        if localAllowed { return "用本机识别，准确率不如云端。想更准，到 设置 里填 Soniox Key。" }
        return "点这里填 Soniox Key，准确率最高。不填也能用 iPhone 本机识别，第一次录音时允许语音识别即可。"
    }

    private func tap(_ id: Int) {
        switch id {
        case 1, 2:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case 3:
            navigate(.key(.soniox))
        default:
            focused = true
        }
    }

    private func refresh() {
        keyboardSeen = KeyboardPresence.lastSeen(directory: MobileEnvironment.sharedDirectory) != nil
        hasKey = MobileEnvironment.hasCloudKey
        localAllowed = OnDeviceSpeech.authorization == .authorized
    }
}
