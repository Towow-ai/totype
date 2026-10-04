import AppIntents
import SwiftUI

@main
struct VerbatimMobileApp: App {
    @StateObject private var dictation = DictationController.shared
    @StateObject private var history = HistoryModel()
    @StateObject private var lexicon = LexiconModel()
    @State private var path: [AppRoute] = []
    @State private var historyLoaded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = DesignPreview.screen {
                DesignPreviewRoot(screen: screen)
            } else {
                root
            }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Resume a paused session; a request may have been written while
            // the app was suspended.
            if phase == .active { dictation.appBecameActive() }
        }
    }

    private var root: some View {
            RootView(path: $path, historyLoaded: historyLoaded)
                .environmentObject(dictation)
                .environmentObject(history)
                .environmentObject(lexicon)
                .onOpenURL { url in handle(url) }
                .task {
                    dictation.recoverAfterLaunch()
                    await lexicon.reload()
                    await history.reload()
                    historyLoaded = true
                    // Without a cloud key dictation runs on the phone; fetch
                    // the iOS 26 model while the app is in front.
                    if !MobileEnvironment.hasCloudKey {
                        Task.detached(priority: .utility) { await OnDeviceSpeech.prepareAnalyzerModel() }
                    }
                }
    }

    /// `<scheme>://record?request=<id>` starts recording (the keyboard's
    /// mic key when no session answers); `stop` / `cancel` end it;
    /// `history` opens the list (home is the history; retry after a failure).
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == MobileIdentity.urlScheme.lowercased() else { return }
        if url.host == "history" {
            path = []
            return
        }
        if url.host == "record" { path = [] }
        dictation.handleURL(url)
    }
}

struct VerbatimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["用\(.applicationName)录音", "\(.applicationName)听写"],
            shortTitle: "录音",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["停止\(.applicationName)录音"],
            shortTitle: "停止录音",
            systemImageName: "stop.fill"
        )
    }
}

enum AppRoute: Hashable {
    case detail(UUID)
    case engine(UUID)
    case revisions(UUID)
    case lexicon
    case settings
    case key(MobileKeychain.Account)
}

/// Home is the history (no tab bar): Home → detail, plus two tool pages.
/// First run shows the checklist until the first dictation lands.
struct RootView: View {
    @Binding var path: [AppRoute]
    let historyLoaded: Bool
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var history: HistoryModel

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if historyLoaded && history.records.isEmpty {
                    OnboardingView(navigate: push)
                } else {
                    HomeView(navigate: push)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(SwipeBackEnabler().frame(width: 0, height: 0))
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .detail(let id): HistoryDetailView(recordID: id, navigate: push, back: pop)
                case .engine(let id): EngineDetailView(recordID: id, back: pop)
                case .revisions(let id): RevisionsView(recordID: id, back: pop)
                case .lexicon: LexiconView(back: pop)
                case .settings: MobileSettingsView(navigate: push, back: pop)
                case .key(let account): KeyEditView(account: account, back: pop)
                }
            }
        }
        .fullScreenCover(isPresented: $dictation.showReturnHint) {
            ReturnView()
                .environmentObject(dictation)
        }
    }

    private func push(_ route: AppRoute) { path.append(route) }
    private func pop() { if !path.isEmpty { path.removeLast() } }
}
