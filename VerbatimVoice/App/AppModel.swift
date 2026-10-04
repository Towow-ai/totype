import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let sonioxAccount = "soniox-api-key"
    nonisolated static let aliyunAccount = "aliyun-bailian-api-key"

    @Published private(set) var state: DictationState = .idle {
        didSet {
            installStatusReporter.update(dictationState: state)
            // Escape belongs exclusively to Verbatim Voice only while audio is
            // actively starting/listening. In every other state it must reach
            // the user's foreground application untouched.
            hotkey.setCancelCaptureActive(state == .starting || state == .listening)
        }
    }
    @Published private(set) var statusMessage = String(localized: "正在启动")
    @Published private(set) var provisionalText = ""
    @Published private(set) var previewText = ""
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastError: String?
    /// Set once per utterance so the menu panel can show elapsed time with a
    /// TimelineView; nothing here ticks through AppModel.
    @Published private(set) var recordingStartedAt: Date?
    // Not @Published: the level changes ~40 times per second while recording.
    // Publishing it invalidated every AppModel observer (menu-bar scene, the
    // retained console window) on the main thread; the overlay has its own
    // direct level path.
    private(set) var audioLevel: Float = 0
    @Published private(set) var microphoneReady = false
    @Published private(set) var microphonePermission = MicrophonePermission.current
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringTrusted = false
    /// Escape self-check (Input Monitoring + keyDown-only tap). Starts optimistic
    /// so nothing alarming flashes before the first check finishes at launch.
    @Published private(set) var escapeCancelAvailable = true
    @Published private(set) var localModelReady = false
    @Published private(set) var sonioxKeyConfigured = false
    @Published private(set) var aliyunKeyConfigured = false
    @Published private(set) var appleBaselineStatus = String(localized: "未检查")
    @Published private(set) var secureInputStatus = String(localized: "未检测到")
    @Published private(set) var recentHistory: [HistoryRecord] = []
    @Published private(set) var launchAtLoginEnabled = false
    @Published var correctionDraft = ""
    @Published private(set) var storageStatus = ""
    @Published private(set) var correctionCaptureStatus = String(localized: "等待下一次可观察的插入")
    @Published private(set) var correctionSuggestions: [CorrectionSuggestion] = []
    @Published private(set) var providerContextStatus = String(localized: "尚未编译个人术语上下文")
    @Published private(set) var historyCopyStatus = ""
    @Published private(set) var retranscribingHistoryIDs: Set<UUID> = []
    @Published private(set) var historyOperationStatus = ""
    @Published private(set) var personalTerms: [PersonalTerm] = []
    @Published private(set) var personalLexiconStatus = String(localized: "正在读取个人词库")
    @Published private(set) var lastProviderContextReceipts: [ProviderContextReceipt] = []
    @Published var personalTermDraft = ""
    /// A cloud provider that rejects requests (balance, key); shown at the
    /// top of the menu panel until a probe or a session proves it healthy.
    @Published private(set) var providerOutageStatus: ProviderOutageStatus?

    let settings: AppSettings
    let audioEngine: WarmAudioEngine
    /// Bundled or downloaded SenseVoice files; the settings pane shows its status.
    let localModels = LocalModelStore()

    private let legacyKeychain = KeychainStore()
    private let personalSecrets = PersonalSecretStore()
    private let hotkey = HotkeyMonitor()
    private let targetService = AccessibilityTargetService()
    private let inserter = PasteboardInserter()
    private let sessionSink = ActiveSessionSink()
    private let correctionMonitor = InsertedTextCorrectionMonitor()
    private let personalLexiconStore = PersonalLexiconStore()
    private let settingsWindowController = SettingsWindowController()
    private let onboardingWindowController = OnboardingWindowController()
    private let installStatusReporter: InstallRuntimeStatusReporter
    private let sessionCoordinator = DictationSessionCoordinator()
    /// Process lifetime only: a relaunch tries every provider again.
    private let providerOutages = ProviderOutageTracker()
    /// At most one idle Soniox actor whose last request ended cleanly; the
    /// next press inside `settings.warmConnectionTTL` reuses its socket.
    private let sonioxWarmPool = SonioxWarmPool()
    /// Soniox handshake started at the key press, consumed by the session.
    private var pendingSonioxPreconnect: PendingSonioxPreconnect?
    private let networkPathObserver = NetworkPathObserver()
    private var activeSession: ActiveDictationSession?
    private var pendingSessionToken: SessionGenerationToken?
    private var pendingTimeline: SessionTimelineRecorder?
    private var pendingPreRollSnapshot: WarmPreRollSnapshot?
    private var providerPartials: [String: String] = [:]
    private var pendingStartTask: Task<Void, Never>?
    private var pendingProviderPreparationTask: Task<Void, Error>?
    private var pendingProviderPreparationID: String?
    private var pendingProviderPreparationSignature: String?
    private var pendingProviderPreparationToken: UUID?
    private var pendingStartShouldFinalize = false
    private var pendingStartPostRollElapsed = false
    private var completionTask: Task<Void, Never>?
    private var cancelUndoTask: Task<Void, Never>?
    private var pendingCancelRequested = false
    private var pendingCancelDeadline: Date?
    private var maximumDurationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var secureInputTimer: Timer?
    private var pendingPreviewSessionID: UUID?
    private var playbackSound: NSSound?
    private var lastExternalApplication: NSRunningApplication?
    /// System uptime when the user asked to stop the current utterance. Used to
    /// detect real keyboard input between stop and the late Unicode dispatch.
    private var stopRequestedUptime: TimeInterval?
    private var correctionCaptureGeneration: UInt64 = 0
    private let sessionLogger = Logger(
        subsystem: AppIdentity.bundleID,
        category: "Session"
    )
    private static let stableAccessibilityPromptKey = "accessibilityPromptedForStableIdentityV1"
    /// Set once the first-run window was finished, skipped or closed, or when every
    /// permission was already in place at launch (so an existing install never sees it).
    private static let onboardingCompletedKey = "onboardingCompletedV1"
    private static let personalSecretMigrationKey = "personalSecretMigrationCompletedV1"
    private static let personalLexiconGlossaryMigrationKey = "personalLexiconGlossaryMigrationCompletedV1"
    private static let sonioxProviderID = "soniox"
    private static let aliyunProviderID = "aliyun-qwen-audio-asr"
    private static let localProviderID = "local-sensevoice"

    private lazy var appleProvider: any ASRProvider = AppleSpeechRecognizerProvider()

    private lazy var overlayController = OverlayPanelController(
        onCancel: { [weak self] in self?.cancelDictation() },
        onUndoCancel: { [weak self] in self?.undoCancel() },
        onCopy: { [weak self] in self?.copyPreview() },
        onInsertCurrent: { [weak self] in self?.insertPreviewAtCurrentFocus() },
        onDismiss: { [weak self] in self?.dismissPreview() }
    )

    init(settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? AppSettings()
        self.settings = resolvedSettings
        _ = AppSettings.launchInterfaceLanguage // fix the language this process started with
        audioEngine = WarmAudioEngine(preRollMilliseconds: resolvedSettings.preRollMilliseconds)
        installStatusReporter = InstallRuntimeStatusReporter()
        localModels.onChange = { [weak self] in self?.refreshLocalModelReady() }
        configureCallbacks()
        installStatusReporter.update(dictationState: state)

        Task { @MainActor [weak self] in
            await self?.start()
        }
    }

    deinit {
        hotkey.stop()
        secureInputTimer?.invalidate()
        pendingStartTask?.cancel()
        pendingProviderPreparationTask?.cancel()
        completionTask?.cancel()
        cancelUndoTask?.cancel()
        maximumDurationTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        overlayController.prepare()

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
        }

        // Inspect the current TCC state on every launch.  A stable-signed
        // install may need one fresh prompt after obsolete ad-hoc identities
        // have been removed, but it must never reopen System Settings on each
        // subsequent start.  The explicit Settings button remains available
        // if the one-time prompt is dismissed.
        accessibilityTrusted = AccessibilityTargetService.isTrusted
        microphonePermission = MicrophonePermission.current
        // On a first run the first-run window asks for Accessibility in its own order.
        let onboardingPending = !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            && !(microphonePermission == .granted && accessibilityTrusted && HotkeyMonitor.hasInputMonitoringAccess)
        if !accessibilityTrusted, !onboardingPending,
           !UserDefaults.standard.bool(forKey: Self.stableAccessibilityPromptKey) {
            UserDefaults.standard.set(true, forKey: Self.stableAccessibilityPromptKey)
            accessibilityTrusted = AccessibilityTargetService.requestTrustPrompt()
        }
        inputMonitoringTrusted = HotkeyMonitor.hasInputMonitoringAccess
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        hotkey.start()
        networkPathObserver.start()
        startSecureInputMonitoring()
        refreshLocalModelReady()
        migrateLegacyCredentialsIfNeeded()
        refreshAPIKeyState()
        await refreshPersonalLexicon(seedIfNeeded: true)
        await refreshHistory()
        await runStorageMaintenance()

        // The microphone is deliberately session-scoped. Keeping an
        // AVAudioEngine input alive while idle interferes with Continuity
        // features such as Universal Clipboard and system live translation.
        releaseAudioCapture()
        statusMessage = readyMessage()

        if settings.appleBaselineEnabled {
            Task { @MainActor [weak self] in
                await self?.prepareAppleBaseline()
            }
        } else {
            appleBaselineStatus = String(localized: "已关闭")
        }

        warmPrimaryCloudProviderIfUseful()
        presentOnboardingIfNeeded()
    }

    private func presentOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.onboardingCompletedKey) else { return }
        let permissionsComplete = microphonePermission == .granted && accessibilityTrusted && inputMonitoringTrusted
        if permissionsComplete, localModelReady || sonioxKeyConfigured || aliyunKeyConfigured {
            defaults.set(true, forKey: Self.onboardingCompletedKey)
            return
        }
        showOnboarding()
    }

    /// First-run window; also reachable from the menu's ⋯ button.
    func showOnboarding() {
        onboardingWindowController.show(model: self) {
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        }
    }

    /// Re-reads the three permissions (the first-run window calls this every second).
    func refreshPermissions() {
        let microphone = MicrophonePermission.current
        if microphonePermission != microphone { microphonePermission = microphone }
        let accessibility = AccessibilityTargetService.isTrusted
        if accessibilityTrusted != accessibility { accessibilityTrusted = accessibility }
        let inputMonitoring = HotkeyMonitor.hasInputMonitoringAccess
        if inputMonitoringTrusted != inputMonitoring { inputMonitoringTrusted = inputMonitoring }
        localModels.refresh()
    }

    func requestMicrophonePermission() {
        Task { @MainActor [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            self?.refreshPermissions()
        }
    }

    func requestAccessibilityForOnboarding() {
        // The prompt registers the app in the Accessibility list; the pane shows it.
        accessibilityTrusted = AccessibilityTargetService.requestTrustPrompt()
        openPrivacySettings(pane: "Privacy_Accessibility")
    }

    func requestInputMonitoringForOnboarding() {
        // CGRequestListenEventAccess registers the app in the Input Monitoring list.
        _ = HotkeyMonitor.requestInputMonitoringAccess()
        openPrivacySettings(pane: "Privacy_ListenEvent")
    }

    func openPrivacySettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Starts a fresh copy of this app a moment after this one quits, so a new
    /// Input Monitoring grant takes effect.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private func refreshLocalModelReady() {
        localModelReady = LocalSenseVoiceProvider.isRuntimeAvailable
        localModels.refresh()
    }

    /// Shown when the local engine is selected but its files are missing: says
    /// what to do next instead of failing silently.
    private var localModelUnavailableMessage: String {
        switch localModels.status {
        case .downloading(let progress):
            return String(localized: "本地模型正在下载（\(Int(progress.fraction * 100))%），完成后再试")
        case .verifying:
            return String(localized: "本地模型正在校验，稍等片刻再试")
        case .failed:
            return String(localized: "本地模型下载失败：到设置 → 识别 重试，或改用云端密钥")
        default:
            return String(localized: "本地模型未安装：到设置 → 识别 下载（约 \(LocalModelFiles.megabytes(LocalModelFiles.approximateTotalBytes))），或改用云端密钥")
        }
    }

    func toggleDictation() {
        switch state {
        case .idle, .failed, .preview:
            beginDictation()
        case .starting, .listening:
            endDictation()
        case .cancelPending:
            // A press after Esc means "start over": keep the cancelled audio in
            // history now and open a new recording. Undo stays on the overlay
            // button and in the menu.
            settleCancelPendingNow()
            beginDictation()
        case .finalizing, .inserting:
            // A third press while the previous utterance is committing must
            // never cancel or duplicate the in-flight insertion.
            break
        }
    }

    func beginDictation() {
        guard state == .idle || state == .failed || state == .preview else { return }
        correctionMonitor.stop()
        correctionCaptureGeneration &+= 1
        stopRequestedUptime = nil
        let targetApplication = currentExternalApplication()
        if state == .preview { dismissPreview() }

        guard !SecureInputMonitor.isEnabled else {
            presentFailure(String(localized: "系统 Secure Input 正在占用键盘事件；先退出密码框或关闭占用它的应用"))
            return
        }
        switch settings.primaryProvider {
        case .localSenseVoice:
            refreshLocalModelReady()
            guard localModelReady else {
                presentFailure(localModelUnavailableMessage)
                return
            }
        case .aliyun:
            refreshAPIKeyState()
            guard aliyunKeyConfigured else {
                presentFailure(String(localized: "已选择阿里云百炼，但未配置 API Key；不会切换到系统听写"))
                return
            }
        case .soniox:
            refreshAPIKeyState()
            guard sonioxKeyConfigured else {
                presentFailure(String(localized: "已选择 Soniox，但未配置 API Key；不会切换到系统听写"))
                return
            }
        }

        let startedAt = Date()
        guard let token = sessionCoordinator.begin() else { return }
        let timeline = SessionTimelineRecorder(wallClockStartedAt: startedAt)
        timeline.mark(.trigger)
        pendingSessionToken = token
        pendingTimeline = timeline
        let targetProcessIdentifier = targetApplication?.processIdentifier
        let targetBundleIdentifier = targetApplication?.bundleIdentifier
        let targetApplicationName = targetApplication?.localizedName

        providerPartials.removeAll(keepingCapacity: true)
        provisionalText = ""
        previewText = ""
        pendingPreviewSessionID = nil
        lastError = nil
        pendingStartShouldFinalize = false
        pendingStartPostRollElapsed = false
        pendingCancelRequested = false
        pendingCancelDeadline = nil
        cancelUndoTask?.cancel()
        cancelUndoTask = nil
        recordingStartedAt = startedAt
        state = .starting
        statusMessage = String(localized: "正在启动麦克风")

        // Establish the session boundary before opening audio. The target
        // application's identity is already captured as PID/bundle metadata;
        // Accessibility is deliberately not queried on the startup path. Every
        // PCM callback is retained until the providers become active.
        sessionSink.beginPendingCapture()
        let overlayStartedAt = Date()
        overlayController.present(
            sessionID: token.sessionID,
            mode: .listening,
            message: statusMessage,
            text: "",
            level: audioEngine.level,
            anchor: nil,
            recordingStartedAt: startedAt
        )
        timeline.mark(.overlayPresented)
        let overlayMilliseconds = Int(Date().timeIntervalSince(overlayStartedAt) * 1_000)
        // Start (or keep) the Soniox socket while the microphone spins up;
        // the session awaits it instead of starting a handshake later.
        preconnectSonioxIfUseful(token: token, targetBundleIdentifier: targetBundleIdentifier)
        networkPathObserver.refreshProxySettings()

        NSLog(
            "[VerbatimVoice] press fast path: overlay=%dms initialLevel=%.3f",
            overlayMilliseconds,
            audioEngine.level
        )

        accessibilityTrusted = AccessibilityTargetService.isTrusted
        pendingStartTask?.cancel()
        pendingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioEngine.requestPermissionAndStart()
            } catch {
                guard !Task.isCancelled,
                      self.sessionCoordinator.isCurrent(token),
                      self.pendingSessionToken == token else {
                    if self.pendingSessionToken == token {
                        self.releaseAudioCapture()
                    }
                    return
                }
                self.failPendingStart(String(localized: "无法开始录音：\(error.localizedDescription)"))
                return
            }
            timeline.mark(.audioHardwareReady)
            guard !Task.isCancelled,
                  self.sessionCoordinator.isCurrent(token),
                  self.pendingSessionToken == token else {
                if self.pendingSessionToken == token {
                    self.releaseAudioCapture()
                }
                return
            }
            self.statusMessage = String(localized: "正在听")
            let preRollStartedAt = Date()
            let preRollSnapshot = self.audioEngine.preRollSnapshot()
            self.pendingPreRollSnapshot = preRollSnapshot
            let preRollMilliseconds = Int(Date().timeIntervalSince(preRollStartedAt) * 1_000)
            NSLog(
                "[VerbatimVoice] audio ready: preRoll=%dms bytes=%d",
                preRollMilliseconds,
                preRollSnapshot.data.count
            )
            // Accessibility discovery is not part of audio startup. The
            // application PID/bundle captured at the key press is sufficient
            // to begin streaming immediately; direct insertion validates that
            // application again at commit time.
            self.completePendingStart(
                token: token,
                timeline: timeline,
                target: nil,
                fallbackProcessIdentifier: targetProcessIdentifier,
                fallbackBundleIdentifier: targetBundleIdentifier,
                fallbackApplicationName: targetApplicationName,
                startedAt: startedAt,
                preRollSnapshot: preRollSnapshot,
                targetCaptureMilliseconds: 0
            )
        }
    }

    private func completePendingStart(
        token: SessionGenerationToken,
        timeline: SessionTimelineRecorder,
        target: TargetSnapshot?,
        fallbackProcessIdentifier: pid_t?,
        fallbackBundleIdentifier: String?,
        fallbackApplicationName: String?,
        startedAt: Date,
        preRollSnapshot: WarmPreRollSnapshot,
        targetCaptureMilliseconds: Int
    ) {
        guard sessionCoordinator.isCurrent(token),
              pendingSessionToken == token,
              (state == .starting
                || (state == .finalizing && pendingStartShouldFinalize)
                || (state == .cancelPending && pendingCancelRequested)) else {
            sessionSink.cancelPendingCapture()
            pendingStartTask = nil
            return
        }

        if let target, target.isSecureField {
            failPendingStart(String(localized: "安全输入字段中已暂停语音输入"))
            return
        }
        if let target, target.compositionLikelyActive {
            failPendingStart(String(localized: "检测到尚未上屏的中文输入法组合文本；先上屏或取消拼音，再按一下\(settings.triggerKey.displayName)"))
            return
        }

        let targetBundleIdentifier = target?.bundleIdentifier ?? fallbackBundleIdentifier
        let profile = AppProfile.profile(for: targetBundleIdentifier)
        let preconnect = pendingSonioxPreconnect?.token == token ? pendingSonioxPreconnect : nil
        let providers = selectedProviders(preconnectedSoniox: preconnect?.provider)
        if let preconnect {
            pendingSonioxPreconnect = nil
            if providers.primary !== preconnect.provider {
                // The route changed (e.g. Soniox just became unavailable):
                // keep the clean socket for a later press instead.
                releaseSonioxPreconnect(preconnect)
            }
        }
        if !providerOutages.snapshot().isEmpty {
            // Next main-loop turn: building the probe's context is not part
            // of audio startup.
            Task { @MainActor [weak self] in self?.probeUnavailableProviders() }
        }
        let primary = providers.primary
        let baseline = providers.baseline
        let sessionID = token.sessionID
        let compiledContexts = compileProviderContexts(
            sessionID: sessionID,
            primary: primary,
            comparisons: providers.comparisons,
            baseline: baseline,
            targetBundleIdentifier: targetBundleIdentifier
        )
        lastProviderContextReceipts = compiledContexts.receipts
        if let primaryReceipt = compiledContexts.receipts.first(where: { $0.provider == primary.id }) {
            providerContextStatus = receiptSummary(primaryReceipt)
        }
        // A preconnect that fails is not a session failure: the provider
        // connects again (with its own retry) in `startUtterance`.
        let preparationTask: Task<Void, Error>? = preconnect.flatMap { preconnect in
            providers.primary === preconnect.provider ? preconnect.task : nil
        }
        pendingProviderPreparationTask = nil
        pendingProviderPreparationID = nil
        pendingProviderPreparationSignature = nil
        pendingProviderPreparationToken = nil

        let session = ActiveDictationSession(
            token: token,
            timeline: timeline,
            startedAt: startedAt,
            target: target,
            targetApplicationPID: target?.processIdentifier ?? fallbackProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier,
            targetApplicationName: target?.applicationName ?? fallbackApplicationName,
            profile: profile,
            contextsByProviderID: compiledContexts.contexts,
            providerContextReceipts: compiledContexts.receipts,
            preRollMilliseconds: settings.preRollMilliseconds,
            primaryProvider: primary,
            primaryPreparationTask: preparationTask,
            comparisonProviders: providers.comparisons,
            appleProvider: baseline,
            // Every session gets a recoverable archive while it is active so
            // Escape can retain a draft even when ordinary successful audio
            // history is disabled. Normal persistence applies that setting.
            saveAudio: true,
            retainLocalFallbackAudio: settings.automaticLocalFallback && localModelReady,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event, token: token) }
            }
        )
        let path = networkPathObserver.current()
        session.networkPath = path.snapshot
        session.networkPathGeneration = path.generation
        returnSonioxToWarmPoolWhenClean(session)
        activeSession = session
        let bufferedChunkCount = sessionSink.install(
            session,
            afterSequence: preRollSnapshot.throughSequence
        )
        session.activate(preRoll: preRollSnapshot)
        pendingPreRollSnapshot = nil
        pendingStartTask = nil
        NSLog(
            "[VerbatimVoice] audio boundary ready: targetCapture=%dms bufferedChunks=%d preRollBytes=%d",
            targetCaptureMilliseconds,
            bufferedChunkCount,
            preRollSnapshot.data.count
        )

        if pendingStartShouldFinalize {
            _ = sessionCoordinator.transition(token, to: .finalizing)
            if pendingStartPostRollElapsed {
                pendingStartShouldFinalize = false
                pendingStartPostRollElapsed = false
                sessionSink.clear(session)
                session.finishInput()
                releaseAudioCapture()
                completionTask = Task { @MainActor [weak self, weak session] in
                    guard let self, let session else { return }
                    await self.finish(session)
                }
            }
            return
        }


        if pendingCancelRequested {
            pendingCancelRequested = false
            sessionSink.clear(session)
            session.finishInput()
            releaseAudioCapture()
            scheduleRetainedCancellation(for: session)
            return
        }

        _ = sessionCoordinator.transition(token, to: .listening)
        state = .listening
        scheduleMaximumDuration(for: session)
    }

    private func failPendingStart(_ message: String) {
        if let preconnect = pendingSonioxPreconnect {
            pendingSonioxPreconnect = nil
            releaseSonioxPreconnect(preconnect)
        }
        if let token = pendingSessionToken {
            pendingTimeline?.mark(.failed)
            _ = sessionCoordinator.cancel(token)
        }
        pendingSessionToken = nil
        pendingTimeline = nil
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingProviderPreparationTask?.cancel()
        pendingProviderPreparationTask = nil
        pendingProviderPreparationID = nil
        pendingProviderPreparationSignature = nil
        pendingProviderPreparationToken = nil
        pendingStartShouldFinalize = false
        pendingStartPostRollElapsed = false
        completionTask?.cancel()
        completionTask = nil
        sessionSink.cancelPendingCapture()
        activeSession = nil
        releaseAudioCapture()
        presentFailure(message)
    }

    func endDictation() {
        guard state == .listening || state == .starting else {
            sessionLogger.notice("stop ignored: state is not recording")
            return
        }
        guard let token = pendingSessionToken ?? activeSession?.token,
              sessionCoordinator.isCurrent(token) else {
            sessionLogger.error("stop ignored: recording state without a current session token")
            return
        }
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        pendingTimeline?.mark(.stopRequested)
        activeSession?.timeline.mark(.stopRequested)
        _ = sessionCoordinator.transition(token, to: .finalizing)

        if activeSession == nil, pendingStartTask != nil {
            pendingStartShouldFinalize = true
            state = .finalizing
            statusMessage = String(localized: "正在定稿")
            overlayController.present(
                sessionID: token.sessionID,
                mode: .finalizing,
                message: statusMessage,
                text: "",
                level: audioLevel,
                anchor: nil
            )

            completionTask?.cancel()
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let postRoll = UInt64(max(0, self.settings.postRollMilliseconds)) * 1_000_000
                if postRoll > 0 { try? await Task.sleep(nanoseconds: postRoll) }
                guard !Task.isCancelled else { return }

                self.pendingStartPostRollElapsed = true
                if let session = self.activeSession {
                    self.pendingStartShouldFinalize = false
                    self.pendingStartPostRollElapsed = false
                    self.sessionSink.clear(session)
                    session.finishInput()
                    self.releaseAudioCapture()
                    await self.finish(session)
                } else {
                    self.sessionSink.endPendingCapture()
                }
            }
            return
        }

        guard let session = activeSession else { return }

        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        state = .finalizing
        statusMessage = String(localized: "正在定稿")
        overlayController.present(
            sessionID: token.sessionID,
            mode: .finalizing,
            message: statusMessage,
            // Keep the release transition compact and stable.  Showing a
            // partial transcript here caused the overlay to visibly reflow
            // before the same text appeared in the destination field.
            text: "",
            level: audioLevel,
            anchor: nil
        )

        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let postRoll = UInt64(max(0, self.settings.postRollMilliseconds)) * 1_000_000
            if postRoll > 0 { try? await Task.sleep(nanoseconds: postRoll) }
            guard !Task.isCancelled else { return }

            self.pendingStartShouldFinalize = false
            self.pendingStartPostRollElapsed = false
            self.sessionSink.clear(session)
            session.finishInput()
            self.releaseAudioCapture()
            await self.finish(session)
        }
    }

    func cancelDictation() {
        if activeSession == nil,
           (pendingStartTask != nil || state == .starting || pendingStartShouldFinalize) {
            completionTask?.cancel()
            completionTask = nil
            maximumDurationTask?.cancel()
            maximumDurationTask = nil
            pendingStartShouldFinalize = false
            pendingStartPostRollElapsed = false
            pendingCancelRequested = true
            let deadline = Date().addingTimeInterval(5)
            pendingCancelDeadline = deadline
            sessionSink.endPendingCapture()
            guard let token = pendingSessionToken else { return }
            pendingTimeline?.mark(.cancelRequested)
            _ = sessionCoordinator.transition(token, to: .cancelPending)
            state = .cancelPending
            statusMessage = String(localized: "已取消")
            provisionalText = ""
            overlayController.presentCancelPending(
                sessionID: token.sessionID,
                deadline: deadline
            )
            schedulePendingStartRetainedCancellation(token: token)
            return
        }

        guard let session = activeSession else {
            dismissPreview()
            return
        }
        if state == .cancelPending { return }
        pendingStartShouldFinalize = false
        pendingStartPostRollElapsed = false
        completionTask?.cancel()
        completionTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        sessionSink.clear(session)
        session.finishInput()
        releaseAudioCapture()
        session.timeline.mark(.cancelRequested)
        _ = sessionCoordinator.transition(session.token, to: .cancelPending)
        state = .cancelPending
        statusMessage = String(localized: "已取消")
        provisionalText = ""
        let deadline = Date().addingTimeInterval(5)
        pendingCancelDeadline = deadline
        overlayController.presentCancelPending(
            sessionID: session.id,
            deadline: deadline
        )
        scheduleRetainedCancellation(for: session)
    }

    func undoCancel() {
        guard state == .cancelPending,
              let token = pendingSessionToken ?? activeSession?.token,
              sessionCoordinator.isCurrent(token) else { return }
        cancelUndoTask?.cancel()
        cancelUndoTask = nil
        pendingTimeline?.mark(.cancelUndone)
        activeSession?.timeline.mark(.cancelUndone)
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        pendingCancelRequested = false
        pendingCancelDeadline = nil
        pendingStartShouldFinalize = activeSession == nil
        pendingStartPostRollElapsed = activeSession == nil
        _ = sessionCoordinator.transition(token, to: .finalizing)
        state = .finalizing
        statusMessage = String(localized: "正在恢复并转写")
        overlayController.present(
            sessionID: token.sessionID,
            mode: .finalizing,
            message: statusMessage,
            text: "",
            level: 0,
            anchor: nil
        )
        guard let session = activeSession else { return }
        completionTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await self.finish(session)
        }
    }

    /// Ends the undo window early, exactly as its timer would.
    private func settleCancelPendingNow() {
        guard state == .cancelPending else { return }
        cancelUndoTask?.cancel()
        cancelUndoTask = nil
        if let session = activeSession, sessionCoordinator.isCurrent(session.token) {
            completeRetainedCancellation(session)
        } else if let token = pendingSessionToken, sessionCoordinator.isCurrent(token) {
            completeRetainedPendingCapture(token: token)
        }
    }

    private func scheduleRetainedCancellation(for session: ActiveDictationSession) {
        cancelUndoTask?.cancel()
        let remaining = max(0, pendingCancelDeadline?.timeIntervalSinceNow ?? 5)
        cancelUndoTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self, let session,
                  self.activeSession === session,
                  self.state == .cancelPending,
                  self.sessionCoordinator.isCurrent(session.token) else { return }
            self.completeRetainedCancellation(session)
        }
    }

    private func schedulePendingStartRetainedCancellation(token: SessionGenerationToken) {
        cancelUndoTask?.cancel()
        let remaining = max(0, pendingCancelDeadline?.timeIntervalSinceNow ?? 5)
        cancelUndoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  self.state == .cancelPending,
                  self.sessionCoordinator.isCurrent(token) else { return }
            if let session = self.activeSession {
                self.completeRetainedCancellation(session)
            } else {
                self.completeRetainedPendingCapture(token: token)
            }
        }
    }

    private func completeRetainedPendingCapture(token: SessionGenerationToken) {
        let finishedAt = Date()
        let timeline = pendingTimeline
        let snapshot = pendingPreRollSnapshot ?? WarmPreRollSnapshot(data: Data(), throughSequence: 0)
        let chunks = sessionSink.drainPending(afterSequence: snapshot.throughSequence)
        pendingStartTask?.cancel()
        pendingStartTask = nil
        releaseAudioCapture()
        cancelPendingProviderPreparation()
        timeline?.mark(.cancelRetained)
        timeline?.mark(.userPathFinished)
        overlayController.dismiss(sessionID: token.sessionID)
        timeline?.mark(.overlayDismissed)
        pendingSessionToken = nil
        pendingTimeline = nil
        pendingPreRollSnapshot = nil
        pendingCancelRequested = false
        pendingCancelDeadline = nil
        cancelUndoTask = nil
        state = .idle
        statusMessage = String(localized: "已保留到历史")
        _ = sessionCoordinator.transition(token, to: .completed)
        _ = sessionCoordinator.finish(token, as: .completed)

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let preRollMilliseconds = settings.preRollMilliseconds
        Task(priority: .utility) { [weak self] in
            let archive = SessionAudioArchive()
            let audioURL: URL?
            do {
                let directory = try await HistoryStore.shared.audioDirectory()
                try await archive.start(sessionID: token.sessionID, preRoll: snapshot.data, directory: directory)
                for chunk in chunks { try await archive.append(chunk.data) }
                audioURL = await archive.finishAndCompress()
            } catch {
                await archive.cancel()
                audioURL = nil
            }
            timeline?.mark(.persistenceFinished)
            let record = HistoryRecord(
                id: token.sessionID,
                startedAt: timeline?.snapshot().wallClockStartedAt ?? finishedAt,
                finishedAt: finishedAt,
                targetBundleIdentifier: nil,
                targetApplicationName: nil,
                primary: nil,
                appleBaseline: nil,
                comparisons: [],
                effectiveProviderID: nil,
                usedOfflineFallback: false,
                insertedText: "",
                insertionStatus: .canceled,
                insertionTransport: InsertionTransport.none,
                insertionAttempts: [],
                audioRelativePath: audioURL.map { "audio/\($0.lastPathComponent)" },
                preRollMilliseconds: preRollMilliseconds,
                notes: [String(localized: "启动阶段取消；音频已保留，可从历史重新转写")],
                schemaVersion: 2,
                appVersion: appVersion,
                buildNumber: buildNumber,
                timeline: timeline?.snapshot(),
                selectedReason: "user_cancelled_during_start_retained_draft",
                userPathFinishedAt: finishedAt,
                persistenceFinishedAt: Date(),
                disposition: .retainedDraft,
                audioState: audioURL == nil ? .unavailable : .available,
                transcriptRevisions: [],
                selectedRevisionID: nil
            )
            try? await HistoryStore.shared.append(record)
            await self?.refreshHistory()
        }
    }

    private func completeRetainedCancellation(_ session: ActiveDictationSession) {
        let finishedAt = Date()
        session.timeline.mark(.cancelRetained)
        session.timeline.mark(.userPathFinished)
        overlayController.dismiss(sessionID: session.id)
        session.timeline.mark(.overlayDismissed)
        activeSession = nil
        pendingSessionToken = nil
        pendingTimeline = nil
        pendingStartTask = nil
        pendingCancelRequested = false
        pendingCancelDeadline = nil
        cancelUndoTask = nil
        completionTask = nil
        state = .idle
        statusMessage = String(localized: "已保留到历史")
        provisionalText = ""
        _ = sessionCoordinator.transition(session.token, to: .completed)
        _ = sessionCoordinator.finish(session.token, as: .completed)

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        Task(priority: .utility) { [weak self] in
            let primary = await session.observePrimary(timeoutNanoseconds: 750_000_000)
            var comparisons: [ProviderRunOutcome] = []
            for providerID in session.comparisonTasks.keys {
                if let outcome = await session.observeComparison(
                    providerID: providerID,
                    timeoutNanoseconds: 100_000_000
                ) {
                    comparisons.append(outcome)
                }
            }
            await session.cancelTranscriptionPreservingArchive()
            let audioURL = await session.archiveTask?.value
            let originalText = primary?.result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let originalRevision: TranscriptRevision? = originalText.isEmpty ? nil : TranscriptRevision(
                id: UUID(),
                createdAt: finishedAt,
                source: .original,
                providerID: primary?.providerID ?? session.primaryProviderID,
                model: primary?.model ?? session.primaryProviderID,
                text: originalText,
                error: primary?.errorMessage
            )
            session.timeline.mark(.persistenceFinished)
            let record = HistoryRecord(
                id: session.id,
                startedAt: session.startedAt,
                finishedAt: finishedAt,
                targetBundleIdentifier: session.targetBundleIdentifier,
                targetApplicationName: session.targetApplicationName,
                primary: primary?.summary,
                appleBaseline: nil,
                comparisons: comparisons.sorted { $0.providerID < $1.providerID }.map(\.summary),
                effectiveProviderID: nil,
                usedOfflineFallback: false,
                insertedText: originalText,
                insertionStatus: .canceled,
                insertionTransport: InsertionTransport.none,
                insertionAttempts: [],
                providerContextReceipts: session.providerContextReceipts,
                audioRelativePath: audioURL.map { "audio/\($0.lastPathComponent)" },
                preRollMilliseconds: session.preRollMilliseconds,
                notes: [String(localized: "用户取消；音频已保留，可从历史重新转写")],
                schemaVersion: 2,
                appVersion: appVersion,
                buildNumber: buildNumber,
                timeline: session.timeline.snapshot(),
                selectedReason: "user_cancelled_retained_draft",
                userPathFinishedAt: finishedAt,
                persistenceFinishedAt: Date(),
                disposition: .retainedDraft,
                audioState: audioURL == nil ? .unavailable : .available,
                transcriptRevisions: originalRevision.map { [$0] },
                selectedRevisionID: originalRevision?.id
            )
            try? await HistoryStore.shared.append(record)
            await self?.refreshHistory()
        }
    }

    func copyPreview() {
        guard !previewText.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = self.pendingPreviewSessionID
            let result = self.inserter.copyOnly(self.previewText)
            if let sessionID {
                try? await HistoryStore.shared.appendAction(
                    sessionID: sessionID,
                    insertionStatus: .copied,
                    message: result.message
                )
            }
            self.statusMessage = result.message
            self.lastTranscript = self.previewText
            self.previewText = ""
            self.pendingPreviewSessionID = nil
            self.state = .idle
            self.overlayController.dismiss()
            await self.refreshHistory()
        }
    }

    func insertPreviewAtCurrentFocus() {
        guard !previewText.isEmpty else { return }
        let target = targetService.capture()
        let text = previewText
        state = .inserting
        statusMessage = String(localized: "正在插入")
        overlayController.present(mode: .finalizing, message: statusMessage, text: "", level: 0, anchor: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessionID = self.pendingPreviewSessionID
            let result: InsertionResult
            if let target {
                result = await self.inserter.insert(
                    text: text,
                    target: target,
                    onDispatched: { [weak self] in self?.overlayController.dismiss() }
                )
            } else {
                result = await self.inserter.insertAtCurrentFocus(
                    text: text,
                    onDispatched: { [weak self] in self?.overlayController.dismiss() }
                )
            }
            if result.status == .inserted || result.status == .dispatched {
                if let sessionID {
                    try? await HistoryStore.shared.appendAction(
                        sessionID: sessionID,
                        insertionStatus: result.status,
                        message: result.message
                    )
                }
                self.lastTranscript = text
                self.previewText = ""
                self.pendingPreviewSessionID = nil
                self.statusMessage = result.message
                self.state = .idle
                self.overlayController.dismiss()
                if let sessionID, let target {
                    self.startCorrectionObservation(
                        sessionID: sessionID,
                        insertedText: text,
                        target: target
                    )
                }
            } else {
                self.state = .preview
                self.statusMessage = result.message
                self.overlayController.present(mode: .preview, message: result.message, text: text, level: 0, anchor: target?.focusBounds)
            }
            await self.refreshHistory()
        }
    }

    func dismissPreview() {
        if let sessionID = pendingPreviewSessionID {
            Task {
                try? await HistoryStore.shared.appendAction(
                    sessionID: sessionID,
                    insertionStatus: .canceled,
                    message: String(localized: "用户关闭了预览")
                )
                await refreshHistory()
            }
        }
        pendingPreviewSessionID = nil
        previewText = ""
        provisionalText = ""
        if state == .preview || state == .failed { state = .idle }
        overlayController.dismiss()
    }

    private func releaseAudioCapture() {
        audioEngine.stop()
        microphoneReady = false
        audioLevel = 0
    }

    func saveSonioxAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try personalSecrets.delete(account: Self.sonioxAccount)
        } else {
            try personalSecrets.set(trimmed, account: Self.sonioxAccount)
        }
        refreshAPIKeyState()
        // A warm socket was configured with the previous key.
        sonioxWarmPool.drain()
        warmPrimaryCloudProviderIfUseful()
    }

    func currentSonioxAPIKey() -> String {
        (try? personalSecrets.get(account: Self.sonioxAccount)) ?? ""
    }

    func saveAliyunAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try personalSecrets.delete(account: Self.aliyunAccount)
        } else {
            try personalSecrets.set(trimmed, account: Self.aliyunAccount)
        }
        refreshAPIKeyState()
    }

    func currentAliyunAPIKey() -> String {
        (try? personalSecrets.get(account: Self.aliyunAccount)) ?? ""
    }

    func testAliyunConnection() async -> String {
        guard aliyunKeyConfigured else { return String(localized: "请先保存阿里云 API Key") }
        let probe = makeAliyunProvider()
        do {
            try await probe.startUtterance(
                id: UUID(),
                context: personalASRContext(providerID: probe.id),
                eventHandler: { _ in }
            )
            await probe.cancel()
            return String(localized: "连接成功：\(settings.aliyunRegion.displayName)")
        } catch {
            await probe.cancel()
            return String(localized: "连接失败：\(error.localizedDescription)")
        }
    }

    func openAliyunAPIKeyGuide() {
        guard let url = URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityTargetService.requestTrustPrompt()
    }

    func requestInputMonitoringPermission() {
        inputMonitoringTrusted = HotkeyMonitor.requestInputMonitoringAccess()
        hotkey.restart()
    }

    /// 隐私与安全性 → 输入监控. A stale grant is fixed by removing Verbatim Voice
    /// there and adding it again, which records the current signing identity.
    func openInputMonitoringSettings() {
        openPrivacySettings(pane: "Privacy_ListenEvent")
    }

    private func applyEscapeCancelAvailability(_ available: Bool) {
        if escapeCancelAvailable != available { escapeCancelAvailable = available }
        overlayController.setEscapeCancelUnavailable(!available)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            presentFailure(String(localized: "开机启动设置失败：\(error.localizedDescription)"))
        }
    }

    func openDataFolder() {
        Task {
            if let url = try? await HistoryStore.shared.baseDirectory() {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// The console page the next `showSettingsWindow` should land on; the view
    /// consumes it and resets it to nil.
    @Published var requestedSettingsDestination: SettingsDestination?

    func showSettingsWindow(_ destination: SettingsDestination? = nil) {
        if let destination { requestedSettingsDestination = destination }
        settingsWindowController.show(model: self)
    }

    func refreshHistory() async {
        let records = (try? await HistoryStore.shared.recent(limit: 20)) ?? []
        let suggestions = (try? await HistoryStore.shared.correctionSuggestions(limit: 20)) ?? []
        recentHistory = Array(records.reversed())
        correctionSuggestions = suggestions
        if correctionDraft.isEmpty {
            correctionDraft = recentHistory.first?.insertedText ?? ""
        }
    }

    func playHistoryAudio(_ record: HistoryRecord) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = try? await HistoryStore.shared.audioURL(for: record) else {
                self.historyOperationStatus = String(localized: "这条历史没有可播放的音频")
                return
            }
            self.playbackSound?.stop()
            self.playbackSound = NSSound(contentsOf: url, byReference: true)
            if self.playbackSound?.play() == true {
                self.historyOperationStatus = String(localized: "正在播放历史音频")
            } else {
                self.historyOperationStatus = String(localized: "历史音频播放失败")
            }
        }
    }

    func retranscribeHistory(
        _ record: HistoryRecord,
        using choice: HistoryRetranscriptionProvider = .automatic
    ) {
        guard !retranscribingHistoryIDs.contains(record.id) else { return }
        retranscribingHistoryIDs.insert(record.id)
        historyOperationStatus = String(localized: "正在重新转写…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.retranscribingHistoryIDs.remove(record.id) }
            guard let audioURL = try? await HistoryStore.shared.audioURL(for: record) else {
                self.historyOperationStatus = String(localized: "音频文件已不存在，无法重新转写")
                return
            }

            let provider: any ASRProvider
            do {
                provider = try self.historyProvider(for: choice)
            } catch {
                self.historyOperationStatus = error.localizedDescription
                return
            }
            let providerID = provider.id
            let model = provider.displayName
            let context = self.personalASRContext(
                providerID: providerID,
                targetBundleIdentifier: record.targetBundleIdentifier
            )

            let chunks: [PCM16Chunk]
            do {
                chunks = try await Task.detached(priority: .userInitiated) {
                    try ArchivedAudioReader.pcm16Chunks(from: audioURL)
                }.value
            } catch {
                self.historyOperationStatus = String(localized: "历史音频读取失败：\(error.localizedDescription)")
                return
            }
            let totalPCMBytes = chunks.reduce(into: 0) { $0 += $1.data.count }
            let isRealtimeCloud = providerID == Self.sonioxProviderID
                || providerID == Self.aliyunProviderID
            let deadlineNanoseconds = HistoryRetranscriptionPolicy.deadlineNanoseconds(
                pcmByteCount: totalPCMBytes,
                isRealtimeCloud: isRealtimeCloud
            )
            let durationSeconds = Int(
                HistoryRetranscriptionPolicy.audioDurationNanoseconds(
                    pcmByteCount: totalPCMBytes
                ) / 1_000_000_000
            )
            self.historyOperationStatus = durationSeconds >= 60
                ? String(localized: "正在重新转写约 \(durationSeconds / 60) 分 \(durationSeconds % 60) 秒的音频…")
                : String(localized: "正在重新转写约 \(durationSeconds) 秒的音频…")

            let task = Task<ProviderRunOutcome, Never>(priority: .userInitiated) {
                do {
                    try await provider.prepare(context: context)
                    try await provider.startUtterance(
                        id: UUID(),
                        context: context,
                        eventHandler: { _ in }
                    )
                    let cloudReplayStartedAt = DispatchTime.now().uptimeNanoseconds
                    var replayedPCMBytes = 0
                    let progressStride = max(1, chunks.count / 20)
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        try await provider.send(chunk)
                        replayedPCMBytes += chunk.data.count
                        let completed = index + 1
                        if completed == chunks.count || completed.isMultiple(of: progressStride) {
                            let percent = HistoryRetranscriptionPolicy.progressPercent(
                                completedChunks: completed,
                                totalChunks: chunks.count
                            )
                            await MainActor.run { [weak self] in
                                guard let self,
                                      self.retranscribingHistoryIDs.contains(record.id) else { return }
                                self.historyOperationStatus = percent == 100
                                    ? String(localized: "音频已发送，等待 \(model) 完成…")
                                    : String(localized: "正在向 \(model) 发送历史音频：\(percent)%")
                            }
                        }
                        if isRealtimeCloud, completed < chunks.count {
                            let now = DispatchTime.now().uptimeNanoseconds
                            let elapsed = now >= cloudReplayStartedAt
                                ? now - cloudReplayStartedAt
                                : UInt64.max
                            let pacing = HistoryRetranscriptionPolicy.cloudReplayPacingNanoseconds(
                                cumulativePCMByteCount: replayedPCMBytes,
                                elapsedNanoseconds: elapsed
                            )
                            if pacing > 0 {
                                try await Task.sleep(nanoseconds: pacing)
                            }
                        }
                    }
                    return .success(try await provider.finalize())
                } catch is CancellationError {
                    return .failure(
                        providerID: providerID,
                        model: model,
                        error: CancellationError(),
                        terminationReason: .cancelled
                    )
                } catch {
                    await provider.cancel()
                    return .failure(providerID: providerID, model: model, error: error)
                }
            }

            let outcome: ProviderRunOutcome
            switch await CompletionDeadline.wait(
                for: task,
                timeoutNanoseconds: deadlineNanoseconds,
                onTimeout: {
                    task.cancel()
                    await provider.cancel()
                }
            ) {
            case .completed(let completed):
                outcome = completed
            case .timedOut:
                outcome = .failure(
                    providerID: providerID,
                    model: model,
                    error: ASRProviderError.timeout(
                        String(localized: "历史重转写超过按音频时长计算的 \(deadlineNanoseconds / 1_000_000_000) 秒截止")
                    ),
                    terminationReason: .timedOut
                )
            }

            let revision = TranscriptRevision(
                id: UUID(),
                createdAt: Date(),
                source: .retranscription,
                providerID: providerID,
                model: outcome.result?.model ?? model,
                text: outcome.result?.text ?? "",
                error: outcome.errorMessage
            )
            do {
                try await HistoryStore.shared.appendRevision(sessionID: record.id, revision: revision)
                await self.refreshHistory()
                let failureReason = outcome.errorMessage ?? String(localized: "未知错误")
                self.historyOperationStatus = outcome.result == nil
                    ? String(localized: "重新转写失败：\(failureReason)")
                    : String(localized: "已新增一个转写版本（不会自动插入）")
            } catch {
                self.historyOperationStatus = String(localized: "转写已完成，但版本保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func historyProvider(for choice: HistoryRetranscriptionProvider) throws -> any ASRProvider {
        let resolved: HistoryRetranscriptionProvider
        if choice == .automatic {
            switch settings.primaryProvider {
            case .soniox where sonioxKeyConfigured: resolved = .soniox
            case .aliyun where aliyunKeyConfigured: resolved = .aliyun
            case .localSenseVoice where localModelReady: resolved = .localSenseVoice
            default:
                if sonioxKeyConfigured { resolved = .soniox }
                else if aliyunKeyConfigured { resolved = .aliyun }
                else { resolved = .localSenseVoice }
            }
        } else {
            resolved = choice
        }
        switch resolved {
        case .automatic:
            throw ASRProviderError.unavailable(String(localized: "无法选择重转写模型"))
        case .soniox:
            guard sonioxKeyConfigured else { throw ASRProviderError.missingAPIKey(" Soniox") }
            return makeSonioxProvider()
        case .aliyun:
            guard aliyunKeyConfigured else { throw ASRProviderError.missingAPIKey(String(localized: "阿里云")) }
            return makeAliyunProvider()
        case .localSenseVoice:
            guard localModelReady else { throw ASRProviderError.unavailable(String(localized: "本地模型尚未就绪")) }
            return LocalSenseVoiceProvider()
        }
    }

    func refreshPersonalLexicon(seedIfNeeded: Bool = false) async {
        do {
            let defaults = UserDefaults.standard
            let shouldSeed = seedIfNeeded
                && !defaults.bool(forKey: Self.personalLexiconGlossaryMigrationKey)
            let loaded: [PersonalTerm]
            if shouldSeed {
                var seedCanonicals = settings.glossaryTerms
                if settings.transcriptionPrompt.localizedCaseInsensitiveContains("skill"),
                   settings.transcriptionPrompt.localizedCaseInsensitiveContains("SKU"),
                   !seedCanonicals.contains(where: { $0.caseInsensitiveCompare("skill") == .orderedSame }) {
                    seedCanonicals.append("skill")
                }
                let confirmedAt = Date()
                let seeds = seedCanonicals.map { canonical in
                    PersonalTerm(
                        canonical: canonical,
                        aliases: canonical.caseInsensitiveCompare("skill") == .orderedSame ? ["SKU"] : [],
                        confirmedAt: confirmedAt,
                        correctionCount: canonical.caseInsensitiveCompare("skill") == .orderedSame ? 1 : 0,
                        pinned: true
                    )
                }
                loaded = try await personalLexiconStore.seedIfMissing(seeds)
                defaults.set(true, forKey: Self.personalLexiconGlossaryMigrationKey)
            } else {
                loaded = try await personalLexiconStore.load()
            }
            personalTerms = loaded
            let activeCount = loaded.filter { $0.state == .confirmed }.count
            let pinnedCount = loaded.filter { $0.state == .confirmed && $0.pinned }.count
            personalLexiconStatus = String(localized: "个人词 \(activeCount, format: .number.grouping(.never)) 个，其中钉住 \(pinnedCount, format: .number.grouping(.never)) 个；仅保存在本机")
        } catch {
            personalTerms = []
            personalLexiconStatus = String(localized: "个人词库不可用，已回退兼容词表：\(error.localizedDescription)")
        }
    }

    func addPersonalTerm() {
        let canonical = personalTermDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        if let existing = personalTerms.first(where: {
            $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
        }) {
            if existing.state != .confirmed || !existing.pinned {
                var updated = existing
                updated.state = .confirmed
                updated.pinned = true
                upsertPersonalTerm(updated, message: String(localized: "已重新启用并钉住“\(existing.canonical)”"))
            } else {
                personalLexiconStatus = String(localized: "“\(existing.canonical)”已在个人词库中")
            }
            personalTermDraft = ""
            return
        }
        personalTermDraft = ""
        upsertPersonalTerm(
            PersonalTerm(canonical: canonical, pinned: true),
            message: String(localized: "已加入并钉住“\(canonical)”，下次录音生效")
        )
    }

    func togglePersonalTermPinned(_ term: PersonalTerm) {
        var updated = term
        updated.pinned.toggle()
        if updated.state != .confirmed { updated.state = .confirmed }
        upsertPersonalTerm(
            updated,
            message: updated.pinned ? String(localized: "已钉住“\(term.canonical)”") : String(localized: "已取消钉住“\(term.canonical)”")
        )
    }

    func togglePersonalTermEnabled(_ term: PersonalTerm) {
        var updated = term
        updated.state = term.state == .confirmed ? .retired : .confirmed
        upsertPersonalTerm(
            updated,
            message: updated.state == .confirmed
                ? String(localized: "已恢复“\(term.canonical)”，下次录音生效")
                : String(localized: "已停用“\(term.canonical)”，下次录音不再发送")
        )
    }

    func deletePersonalTerm(_ term: PersonalTerm) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.personalTerms = try await self.personalLexiconStore.delete(termID: term.id)
                self.personalLexiconStatus = String(localized: "已从当前个人词库删除“\(term.canonical)”")
                self.cancelPendingProviderPreparation()
                self.warmPrimaryCloudProviderIfUseful()
            } catch {
                self.personalLexiconStatus = String(localized: "删除失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: Personal profile

    @Published private(set) var profileStatus = ""
    @Published private(set) var profileImportPreview: ProfileImportPreview?
    private var pendingProfileImport: (url: URL, profile: PersonalProfile)?

    func currentProfile() -> PersonalProfile {
        settings.makeProfile(lexicon: personalTerms)
    }

    func exportProfile(to url: URL) {
        do {
            try currentProfile().encoded().write(to: url, options: .atomic)
            profileStatus = String(localized: "已导出到 \(url.lastPathComponent)。文件不含 API Key、历史和录音。")
        } catch {
            profileStatus = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    func prepareProfileImport(from url: URL) {
        do {
            let incoming = try PersonalProfile.decode(from: Data(contentsOf: url))
            pendingProfileImport = (url, incoming)
            profileImportPreview = ProfileImportPreview(
                fileName: url.lastPathComponent,
                changes: PersonalProfile.changes(current: currentProfile(), incoming: incoming)
            )
            profileStatus = ""
        } catch {
            cancelProfileImport()
            profileStatus = String(localized: "无法读取配置文件：\(error.localizedDescription)")
        }
    }

    func cancelProfileImport() {
        pendingProfileImport = nil
        profileImportPreview = nil
    }

    /// Backs the current profile up next to the imported file, then applies the
    /// imported one. The lexicon is merged, never pruned.
    func confirmProfileImport() {
        guard let pending = pendingProfileImport else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = pending.url.deletingLastPathComponent()
            .appendingPathComponent("verbatim-profile-backup-\(formatter.string(from: Date())).json")
        do {
            try currentProfile().encoded().write(to: backupURL, options: .withoutOverwriting)
        } catch {
            profileStatus = String(localized: "没有导入：无法在 \(backupURL.deletingLastPathComponent().lastPathComponent) 里写入备份（\(error.localizedDescription)）")
            return
        }
        cancelProfileImport()
        settings.apply(pending.profile)
        let upserts = pending.profile.lexiconUpserts(into: personalTerms)
        upsertPersonalTerms(upserts, message: String(localized: "已导入配置，原配置备份为 \(backupURL.lastPathComponent)"))
        applyRuntimeSettings()
    }

    func addPersonalAliases(canonical: String, aliases: [String]) {
        let upserts = PersonalProfile(
            lexicon: [.init(canonical: canonical, aliases: aliases, pinned: true)]
        ).lexiconUpserts(into: personalTerms)
        guard !upserts.isEmpty else {
            personalLexiconStatus = String(localized: "“\(canonical)”已有这些别名")
            return
        }
        upsertPersonalTerms(upserts, message: String(localized: "已保存“\(canonical)”的别名，下次录音生效"))
    }

    func removePersonalAlias(_ alias: String, from term: PersonalTerm) {
        var updated = term
        updated.aliases.removeAll { $0.caseInsensitiveCompare(alias) == .orderedSame }
        upsertPersonalTerm(updated, message: String(localized: "已删除“\(term.canonical)”的别名“\(alias)”"))
    }

    private func upsertPersonalTerms(_ terms: [PersonalTerm], message: String) {
        guard !terms.isEmpty else {
            profileStatus = message
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for term in terms {
                    self.personalTerms = try await self.personalLexiconStore.upsert(term)
                }
                self.personalLexiconStatus = message
                self.profileStatus = message
                self.cancelPendingProviderPreparation()
                self.warmPrimaryCloudProviderIfUseful()
            } catch {
                self.personalLexiconStatus = String(localized: "个人词保存失败：\(error.localizedDescription)")
                self.profileStatus = self.personalLexiconStatus
            }
        }
    }

    private func upsertPersonalTerm(_ term: PersonalTerm, message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.personalTerms = try await self.personalLexiconStore.upsert(term)
                self.personalLexiconStatus = message
                self.cancelPendingProviderPreparation()
                self.warmPrimaryCloudProviderIfUseful()
            } catch {
                self.personalLexiconStatus = String(localized: "个人词保存失败：\(error.localizedDescription)")
            }
        }
    }

    func playMostRecentAudio() {
        guard let record = recentHistory.first else {
            statusMessage = String(localized: "还没有历史记录")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = try? await HistoryStore.shared.audioURL(for: record) else {
                self.statusMessage = String(localized: "最近一条记录没有可播放的音频")
                return
            }
            self.playbackSound = NSSound(contentsOf: url, byReference: true)
            guard self.playbackSound?.play() == true else {
                self.statusMessage = String(localized: "音频播放失败")
                return
            }
            self.statusMessage = String(localized: "正在播放最近一条原始音频")
        }
    }

    func copyHistoryRecord(_ record: HistoryRecord) {
        copyHistoryText(
            record.insertedText,
            successMessage: String(localized: "已复制这条历史的完整文字（\(record.insertedText.count, format: .number.grouping(.never)) 字）")
        )
    }

    func copyHistoryProviderOutput(_ summary: ProviderSummary) {
        copyHistoryText(
            summary.text,
            successMessage: String(localized: "已复制 \(summary.model) 的完整结果（\(summary.text.count, format: .number.grouping(.never)) 字）")
        )
    }

    private func copyHistoryText(_ text: String, successMessage: String) {
        guard !text.isEmpty else {
            historyCopyStatus = String(localized: "这项结果是空的，没有可复制内容")
            return
        }
        let result = inserter.copyOnly(text)
        historyCopyStatus = result.status == .copied ? successMessage : result.message
        statusMessage = historyCopyStatus
    }

    func saveCorrection() {
        guard let record = recentHistory.first else { return }
        let corrected = correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else {
            statusMessage = String(localized: "修正文本不能为空")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let replacement = CorrectionInference.replacement(
                    from: record.insertedText,
                    to: corrected
                ).map {
                    CorrectionReplacement(
                        original: $0.original,
                        corrected: $0.corrected,
                        punctuationOnly: $0.punctuationOnly
                    )
                }
                try await HistoryStore.shared.appendAction(
                    sessionID: record.id,
                    correctedText: corrected,
                    message: String(localized: "用户人工修正"),
                    originalText: record.insertedText,
                    correctionSource: "manual-settings",
                    targetBundleIdentifier: record.targetBundleIdentifier,
                    replacements: replacement.map { [$0] }
                )
                self.statusMessage = String(localized: "修正已保存，可用于之后对照原始音频")
                await self.refreshHistory()
            } catch {
                self.presentFailure(String(localized: "保存修正失败：\(error.localizedDescription)"))
            }
        }
    }

    func addCorrectionSuggestionToGlossary(_ suggestion: CorrectionSuggestion) {
        let term = suggestion.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !suggestion.punctuationOnly else { return }
        let existing = Set(settings.glossaryTerms.map { $0.lowercased() })
        guard !existing.contains(term.lowercased()) else {
            statusMessage = String(localized: "“\(term)”已经在个人术语中")
            return
        }
        let separator = settings.glossaryText.hasSuffix("\n") || settings.glossaryText.isEmpty ? "" : "\n"
        settings.glossaryText += separator + term + "\n"
        statusMessage = String(localized: "已将“\(term)”加入个人术语")
    }

    func runStorageMaintenance() async {
        do {
            let quotaBytes = Int64(max(64, settings.audioQuotaMegabytes)) * 1_024 * 1_024
            let result = try await HistoryStore.shared.performMaintenance(
                retentionDays: settings.audioRetentionDays,
                quotaBytes: quotaBytes
            )
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            storageStatus = result.deletedAudioFiles == 0
                ? String(localized: "音频空间正常")
                : String(localized: "已清理 \(result.deletedAudioFiles) 个音频，释放 \(formatter.string(fromByteCount: result.reclaimedBytes))")
        } catch {
            storageStatus = String(localized: "清理检查失败：\(error.localizedDescription)")
        }
    }

    func applyRuntimeSettings() {
        cancelPendingProviderPreparation()
        refreshLocalModelReady()
        audioEngine.setPreRoll(milliseconds: settings.preRollMilliseconds)
        if activeSession == nil, pendingStartTask == nil {
            releaseAudioCapture()
        }
        if settings.appleBaselineEnabled {
            Task { @MainActor [weak self] in await self?.prepareAppleBaseline() }
        } else {
            appleBaselineStatus = String(localized: "已关闭")
        }
        Task { @MainActor [weak self] in await self?.runStorageMaintenance() }
        warmPrimaryCloudProviderIfUseful()
    }

    private func readyMessage(_ key: TriggerKey? = nil) -> String {
        String(localized: "就绪：\((key ?? settings.triggerKey).displayName) 开始；空闲时麦克风已释放")
    }

    private func configureCallbacks() {
        audioEngine.onChunk = { [sessionSink] chunk in
            sessionSink.yield(chunk)
        }

        audioEngine.$level
            .throttle(for: .milliseconds(25), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] level in
                guard let self else { return }
                if self.state == .starting || self.state == .listening {
                    self.audioLevel = level
                    self.overlayController.updateLevel(level)
                } else {
                    // Preserve a fresh first-frame sample without publishing
                    // idle microphone levels through AppModel. Publishing here
                    // made the menu-bar scene redraw continuously while idle.
                    self.overlayController.cacheLevel(level)
                }
            }
            .store(in: &cancellables)

        audioEngine.$isRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                self.microphoneReady = running
                if self.state == .idle {
                    self.statusMessage = self.readyMessage()
                } else if running, self.state == .starting {
                    self.statusMessage = String(localized: "正在听")
                }
            }
            .store(in: &cancellables)

        audioEngine.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.lastError = message
                if self.state != .idle, !self.audioEngine.isRunning {
                    self.statusMessage = message
                }
            }
            .store(in: &cancellables)

        settings.$preRollMilliseconds
            .dropFirst()
            .sink { [weak self] milliseconds in self?.audioEngine.setPreRoll(milliseconds: milliseconds) }
            .store(in: &cancellables)

        // The trigger key changes in place: the event tap is not recreated.
        hotkey.setTriggerKey(settings.triggerKey)
        settings.$triggerKey
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] key in
                guard let self else { return }
                self.hotkey.setTriggerKey(key)
                if self.state == .idle { self.statusMessage = self.readyMessage(key) }
            }
            .store(in: &cancellables)

        hotkey.onPress = { [weak self] in self?.toggleDictation() }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() }
        hotkey.onEscapeCancelAvailabilityChanged = { [weak self] available in
            self?.applyEscapeCancelAvailability(available)
        }
        hotkey.onFailure = { [weak self] message in
            self?.lastError = message
            self?.statusMessage = message
        }


        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApplication = application
        }
        .store(in: &cancellables)
    }

    /// Returns a reason when a late automatic insertion would disturb what the
    /// user is doing now: they switched to another application, or pressed a
    /// real key after asking to stop (for example, started an input-method
    /// composition while the transcript was still finalizing).
    private func lateDispatchHazard(targetPID: pid_t?) -> String? {
        if let targetPID,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
           frontmost.processIdentifier != targetPID {
            return String(localized: "你已切换到其他应用，未自动输入；可点“复制”")
        }
        if let stopRequestedUptime {
            let sinceStop = ProcessInfo.processInfo.systemUptime - stopRequestedUptime
            // HID state counts only physical input, never our own posted events.
            let sinceKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
            if sinceStop > 0.15, sinceKeyDown < sinceStop - 0.05 {
                return String(localized: "结束后检测到键盘输入，为避免打断你正在打的字，未自动输入；可点“复制”")
            }
        }
        return nil
    }

    private func currentExternalApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
            return frontmost
        }
        if let remembered = lastExternalApplication, !remembered.isTerminated {
            return remembered
        }
        return nil
    }

    private func startSecureInputMonitoring() {
        secureInputTimer?.invalidate()
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Permission and login-item checks can cross process/service
                // boundaries. Poll them conservatively and only publish an
                // actual change, never a duplicate value on every timer tick.
                let accessibilityTrusted = AccessibilityTargetService.isTrusted
                let inputMonitoringTrusted = HotkeyMonitor.hasInputMonitoringAccess
                let launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
                if self.accessibilityTrusted != accessibilityTrusted {
                    self.accessibilityTrusted = accessibilityTrusted
                }
                let inputMonitoringChanged = self.inputMonitoringTrusted != inputMonitoringTrusted
                if inputMonitoringChanged {
                    self.inputMonitoringTrusted = inputMonitoringTrusted
                }
                // Re-run the Escape self-check off-main when the grant changes, and
                // keep re-checking while it is unavailable so a fixed grant clears
                // the menu notice without a relaunch. A recording's own Escape tap
                // is the live check, so skip while one may hold it.
                if self.state == .idle || self.state == .preview || self.state == .failed,
                   inputMonitoringChanged || !self.escapeCancelAvailable {
                    self.hotkey.refreshEscapeCancelAvailability()
                }
                if self.launchAtLoginEnabled != launchAtLoginEnabled {
                    self.launchAtLoginEnabled = launchAtLoginEnabled
                }
                let secureInputNone = String(localized: "未检测到")
                if SecureInputMonitor.isEnabled {
                    let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? String(localized: "未知应用")
                    let secureStatus = String(localized: "已开启（前台：\(frontmost)；占用者可能不同）")
                    if self.secureInputStatus != secureStatus {
                        self.secureInputStatus = secureStatus
                    }
                    if self.state == .idle {
                        let message = String(localized: "Secure Input 正在开启；全局热键可能收不到事件")
                        if self.statusMessage != message { self.statusMessage = message }
                    }
                } else {
                    if self.secureInputStatus != secureInputNone {
                        self.secureInputStatus = secureInputNone
                    }
                    if self.state == .idle {
                        let message = self.readyMessage()
                        if self.statusMessage != message { self.statusMessage = message }
                    }
                }
            }
        }
    }

    private func prepareAppleBaseline() async {
        guard settings.appleBaselineEnabled else {
            appleBaselineStatus = String(localized: "已关闭")
            return
        }
        appleBaselineStatus = String(localized: "正在准备 Apple 系统听写")
        do {
            try await appleProvider.prepare(context: personalASRContext(providerID: appleProvider.id))
            appleBaselineStatus = String(localized: "Apple 系统听写就绪")
        } catch {
            appleBaselineStatus = String(localized: "不可用：\(error.localizedDescription)")
        }
    }

    private func handle(_ event: ASREvent, token: SessionGenerationToken) {
        guard sessionCoordinator.isCurrent(token), activeSession?.token == token else { return }
        switch event {
        case .connected(let providerID):
            if providerID == activeSession?.primaryProviderID,
               state == .starting || state == .listening {
                statusMessage = String(localized: "正在听")
            }
        case .partial(let providerID, let text):
            guard state == .starting || state == .listening else { return }
            providerPartials[providerID] = text
            let preferred = activeSession.flatMap { providerPartials[$0.primaryProviderID] }
                ?? providerPartials[appleProvider.id]
                ?? text
            provisionalText = preferred
        case .finalized(let providerID, let text):
            providerPartials[providerID] = text
        case .warning(_, let message):
            lastError = message
        case .failed(let providerID, let message):
            providerPartials.removeValue(forKey: providerID)
            lastError = String(localized: "\(providerID)：\(message)")
        }
    }

    private func finish(_ session: ActiveDictationSession) async {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        guard activeSession === session,
              sessionCoordinator.isCurrent(session.token) else { return }

        let stopUptime = DispatchTime.now().uptimeNanoseconds
        let cloudDeadline = stopUptime &+ CloudLocalRacePolicy.cloudDeadlineNanoseconds
        let userPathDeadline = stopUptime &+ CloudLocalRacePolicy.userPathDeadlineNanoseconds
        func remaining(until deadline: UInt64) -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            return deadline > now ? deadline - now : 1_000_000
        }

        let appleOutcome: ProviderRunOutcome? = nil
        var primaryOutcome: ProviderRunOutcome
        var chosenOutcome: ProviderRunOutcome
        var alreadyResolvedComparisons: [String: ProviderRunOutcome] = [:]
        var usedOfflineFallback = false
        var selectedReason = "primary_completed"
        /// "Soniox 余额不足，已改用阿里云" when this session found the primary unusable.
        var outageNotice: String?
        var sessionNotes: [String] = []
        let standbyID = session.comparisonTasks.keys.first {
            $0 == Self.sonioxProviderID || $0 == Self.aliyunProviderID
        }

        if session.primaryProviderID == Self.localProviderID {
            primaryOutcome = await session.resolvePrimary(
                timeoutNanoseconds: remaining(until: userPathDeadline)
            )
            chosenOutcome = primaryOutcome
            selectedReason = "local_primary"
        } else {
            // Liveness at stop (0.3.79). A primary that never connected or
            // already failed gets no preference window; two dead clouds start
            // the local engine immediately. Otherwise the local engine joins
            // the race 2.5 s after stop, and the first usable result wins.
            let primaryView = session.livenessView(providerID: session.primaryProviderID)
            let standbyView = standbyID.flatMap { session.livenessView(providerID: $0) }
            let primarySilent = primaryView.map(ProviderLivenessPolicy.isSilent) ?? false
            let localAvailable = settings.automaticLocalFallback && localModelReady
            let cloudsDeadAtStop = localAvailable && (primaryView.map {
                ProviderLivenessPolicy.cloudsDeadAtStop(primary: $0, standby: standbyView)
            } ?? false)
            if primarySilent {
                sessionNotes.append(String(localized: "停止时主云已无声（未建连或已报错），未等偏好窗口"))
            }
            if cloudsDeadAtStop {
                sessionNotes.append(String(localized: "录音期间两家云端都不可用，停止后立即本地转写"))
            }

            let cloudTask = Task { @MainActor [weak self, weak session] () -> CloudPhaseResult in
                guard let self, let session else { return CloudPhaseResult(decision: .noUsableResult) }
                return await self.resolveCloudPhase(
                    session: session,
                    standbyID: standbyID,
                    primarySilent: primarySilent,
                    cloudDeadline: cloudDeadline
                )
            }
            let race = await raceCloudAgainstLocal(
                session: session,
                cloudTask: cloudTask,
                stopUptime: stopUptime,
                cloudsDeadAtStop: cloudsDeadAtStop,
                localAvailable: localAvailable,
                userPathDeadline: userPathDeadline
            )
            if let local = race.local {
                alreadyResolvedComparisons[Self.localProviderID] = local
            }
            if race.localCancelled {
                sessionNotes.append(String(localized: "本地赛跑已启动，云端先到，已停止本地"))
            }

            if case .takeLocal(let reason) = race.decision, let local = race.local {
                // The cloud never answered in time: stop both runs so a late
                // final cannot linger, and keep whatever they already returned.
                session.quarantinePrimary()
                if let standbyID {
                    session.quarantineComparison(providerID: standbyID)
                    if let standby = race.cloud?.standby {
                        alreadyResolvedComparisons[standbyID] = standby
                    }
                }
                primaryOutcome = race.cloud?.primary ?? ProviderRunOutcome.failure(
                    providerID: session.primaryProviderID,
                    model: session.primaryProviderID,
                    error: ASRProviderError.timeout(String(localized: "本地先完成，主云已停止")),
                    terminationReason: .quarantined
                )
                chosenOutcome = local
                usedOfflineFallback = true
                selectedReason = reason
                statusMessage = race.localStart == .cloudStalled
                    ? String(localized: "云端较慢，已改用本地")
                    : String(localized: "云端不可用，已改用本地")
                overlayController.showProviderBadge(String(localized: "本地"), sessionID: session.id)
            } else {
                let cloud = race.cloud ?? CloudPhaseResult(decision: .noUsableResult)
                let resolvedPrimary = cloud.primary
                let standbyOutcome = cloud.standby
                switch cloud.decision {
                case .takePrimary(let reason) where resolvedPrimary != nil:
                    primaryOutcome = resolvedPrimary!
                    chosenOutcome = primaryOutcome
                    selectedReason = reason
                case .takeStandby(let reason) where standbyOutcome != nil && standbyID != nil:
                    let standby = standbyOutcome!
                    primaryOutcome = resolvedPrimary ?? ProviderRunOutcome.failure(
                        providerID: session.primaryProviderID,
                        model: session.primaryProviderID,
                        error: ASRProviderError.timeout(String(localized: "主云未在热备结果前完成")),
                        terminationReason: .quarantined
                    )
                    alreadyResolvedComparisons[standbyID!] = standby
                    chosenOutcome = standby
                    selectedReason = reason
                    session.quarantinePrimary()
                    statusMessage = primaryOutcome.failureKind?.disablesProvider == true
                        ? String(localized: "主云不可用，已采用热备结果")
                        : String(localized: "主云收尾较慢，已采用热备结果")
                    overlayController.showProviderBadge(
                        Self.providerDisplayName(standbyID),
                        sessionID: session.id
                    )
                default:
                    if let resolvedPrimary {
                        primaryOutcome = resolvedPrimary
                    } else {
                        primaryOutcome = await session.resolvePrimary(timeoutNanoseconds: 1_000_000)
                    }
                    chosenOutcome = primaryOutcome
                    if let standbyID {
                        if let standbyOutcome {
                            alreadyResolvedComparisons[standbyID] = standbyOutcome
                        } else if let standby = await session.resolveComparison(
                            providerID: standbyID,
                            timeoutNanoseconds: 1_000_000
                        ) {
                            alreadyResolvedComparisons[standbyID] = standby
                        }
                    }
                }
            }

            // Billing/auth take a provider out of later sessions; a completed
            // run clears it. Only the moment it becomes unusable is announced.
            let fallbackID = isUsable(chosenOutcome) && chosenOutcome.providerID != primaryOutcome.providerID
                ? chosenOutcome.providerID
                : nil
            outageNotice = recordProviderAvailability(primaryOutcome, fallbackProviderID: fallbackID)
            if let standbyID, let standby = alreadyResolvedComparisons[standbyID] {
                recordProviderAvailability(standby, fallbackProviderID: nil)
            }
            if let bypassed = providerOutages.outage(for: configuredCloudPrimaryID),
               session.primaryProviderID != configuredCloudPrimaryID {
                sessionNotes.append(
                    String(localized: "\(Self.providerDisplayName(bypassed.providerID)) 不可用（\(bypassed.kind.rawValue)），本次直接使用\(Self.providerDisplayName(session.primaryProviderID))")
                )
            }
        }

        guard activeSession === session,
              sessionCoordinator.isCurrent(session.token) else { return }
        let chosen = chosenOutcome.result

        guard let chosen,
              !chosen.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.timeline.mark(.failed)
            activeSession = nil
            pendingSessionToken = nil
            pendingTimeline = nil
            completionTask = nil
            state = .failed
            _ = sessionCoordinator.transition(session.token, to: .failed)
            _ = sessionCoordinator.finish(session.token, as: .failed)
            let localFailure = alreadyResolvedComparisons[Self.localProviderID]?.errorMessage
            let details = [outageNotice, primaryOutcome.errorMessage, localFailure, appleOutcome?.errorMessage]
                .compactMap { $0 }
                .joined(separator: String(localized: "；"))
            presentFailure(details.isEmpty ? String(localized: "没有得到可用的转写结果") : details)
            refreshProviderOutageStatus()
            persist(
                session: session,
                primary: primaryOutcome,
                alreadyResolvedApple: appleOutcome,
                alreadyResolvedComparisons: alreadyResolvedComparisons,
                effectiveProviderID: nil,
                usedOfflineFallback: false,
                insertedText: "",
                insertion: InsertionResult(status: .failed, message: details, clipboardRestored: true),
                selectedReason: "all_providers_failed",
                userPathFinishedAt: Date(),
                extraNotes: sessionNotes
            )
            return
        }

        session.timeline.mark(.resultSelected, providerID: chosenOutcome.providerID)

        // The application PID captured at the Option press is the automatic
        // insertion lease. Never rebuild an Accessibility target here:
        // Electron/WebKit trees have blocked real completed transcripts for
        // 1.5-3 seconds. A pre-existing explicit target can still contribute
        // join context, while the normal path dispatches directly to the PID.
        let insertionTarget = session.target
        let insertionProfile = insertionTarget.map { AppProfile.profile(for: $0.bundleIdentifier) }
            ?? session.profile

        let preceding: Character?
        if insertionTarget?.selectedRange?.length == 0 {
            preceding = insertionTarget?.precedingCharacter
        } else {
            preceding = nil
        }
        let joinConfiguration = TextJoinConfiguration(
            removeTerminalPeriodInChat: settings.removeChatTerminalPeriod && insertionProfile.removeTerminalPeriod,
            // Do not alter the recognized text just because the preceding
            // character is Latin. Literal mode leaves joining decisions to
            // the user instead of silently inserting content.
            addSpaceBetweenLatinRuns: false,
            appendTrailingSpaceAfterLatin: settings.appendTrailingSpaceAfterEnglish && insertionProfile.appendTrailingSpaceAfterEnglish,
            stripTrailingNewlineInTerminal: insertionProfile.stripTrailingNewline
        )
        // Restore personal terms that ASR is known to mishear (aliases in the
        // personal lexicon), but only where the other cloud engine heard the
        // canonical term. Only results that have already arrived are used;
        // this never waits. Raw provider text stays in the history record.
        let normalized = MisrecognitionNormalizer.apply(
            chosen.text,
            rules: MisrecognitionNormalizer.rules(from: personalTerms),
            corroboration: await corroboratingText(
                for: session,
                chosenProviderID: chosenOutcome.providerID,
                primary: primaryOutcome,
                resolved: alreadyResolvedComparisons
            )
        )
        if !normalized.applied.isEmpty || !normalized.uncorroborated.isEmpty {
            sessionLogger.notice("misrecognition restore applied=\(normalized.applied.count, privacy: .public) uncorroborated=\(normalized.uncorroborated.count, privacy: .public)")
        }
        let preparedText = TextJoinPolicy.prepare(
            transcript: normalized.text,
            precedingCharacter: preceding,
            appKind: session.profile.kind,
            configuration: joinConfiguration
        )

        provisionalText = preparedText
        lastTranscript = preparedText
        guard sessionCoordinator.claimCommit(session.token) else { return }
        state = .inserting
        statusMessage = String(localized: "正在插入")
        // Stay in the existing finalizing panel instead of presenting and
        // repositioning it for a second intermediate state.
        overlayController.updateMessage(statusMessage, sessionID: session.id)

        let insertedNotice = outageNotice
        let onInsertionDispatched: (() -> Void) = { [weak self, weak session] in
            guard let self, let session,
                  self.activeSession === session,
                  self.sessionCoordinator.isCurrent(session.token) else { return }
            session.timeline.mark(.unicodeDispatched)
            // The listening/finalizing overlay ends here; the brief 已插入 pill is
            // swapped in on the next main-loop turn and dismisses itself.
            self.overlayController.showInserted(
                characterCount: preparedText.filter { !$0.isWhitespace }.count,
                notice: insertedNotice,
                sessionID: session.id
            )
            session.timeline.mark(.overlayDismissed)
            session.timeline.mark(.userPathFinished)
            self.activeSession = nil
            self.pendingSessionToken = nil
            self.pendingTimeline = nil
            self.completionTask = nil
            self.state = .idle
            self.previewText = ""
            self.pendingPreviewSessionID = nil
            self.provisionalText = ""
            _ = self.sessionCoordinator.finish(session.token, as: .completed)
        }
        let insertion: InsertionResult
        if let hazard = lateDispatchHazard(targetPID: session.targetApplicationPID) {
            // Typing into another app or continuing to type after stop must not
            // be interrupted by re-activating the old target or injecting
            // keystrokes into an input-method composition.
            sessionLogger.notice("automatic insertion withheld: \(hazard, privacy: .public)")
            insertion = InsertionResult(status: .previewOnly, message: hazard, clipboardRestored: true)
        } else if let target = insertionTarget {
            insertion = await inserter.insert(
                text: preparedText,
                target: target,
                onDispatched: onInsertionDispatched
            )
        } else {
            if let processIdentifier = session.targetApplicationPID {
                insertion = await inserter.insertAtApplication(
                    text: preparedText,
                    processIdentifier: processIdentifier,
                    applicationName: session.targetApplicationName,
                    onDispatched: onInsertionDispatched
                )
            } else {
                insertion = await inserter.insertAtCurrentFocus(
                    text: preparedText,
                    onDispatched: onInsertionDispatched
                )
            }
        }
        let userPathFinishedAt = Date()

        installStatusReporter.beginCriticalPersistence()
        if insertion.status == .inserted || insertion.status == .dispatched {
            statusMessage = insertion.message
            // `onInsertionDispatched` already completed the user path. Any AX
            // or correction observation below is background bookkeeping only.
            if let observationTarget = insertion.resolvedTarget ?? insertionTarget {
                startCorrectionObservation(
                    sessionID: session.id,
                    insertedText: preparedText,
                    target: observationTarget
                )
            } else if let pid = session.targetApplicationPID {
                scheduleBackgroundCorrectionCapture(
                    sessionID: session.id,
                    insertedText: preparedText,
                    processIdentifier: pid,
                    bundleIdentifier: session.targetBundleIdentifier
                )
            } else {
                correctionCaptureStatus = String(localized: "本次目标不提供可观察文本；未监听后续修改")
            }
        } else {
            activeSession = nil
            pendingSessionToken = nil
            pendingTimeline = nil
            completionTask = nil
            _ = sessionCoordinator.transition(session.token, to: .failed)
            _ = sessionCoordinator.finish(session.token, as: .failed)
            state = .preview
            statusMessage = insertion.message
            previewText = preparedText
            pendingPreviewSessionID = session.id
            overlayController.present(
                sessionID: session.id,
                mode: .preview,
                message: insertion.message,
                text: preparedText,
                level: 0,
                anchor: nil
            )
        }

        refreshProviderOutageStatus()
        persist(
            session: session,
            primary: primaryOutcome,
            alreadyResolvedApple: appleOutcome,
            alreadyResolvedComparisons: alreadyResolvedComparisons,
            effectiveProviderID: chosenOutcome.providerID,
            usedOfflineFallback: usedOfflineFallback,
            insertedText: preparedText,
            insertion: insertion,
            selectedReason: selectedReason,
            userPathFinishedAt: userPathFinishedAt,
            extraNotes: sessionNotes
        )
    }

    /// Terminals expose no editable AX text value; scanning them only costs time.
    private static let correctionCaptureSkippedBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    /// Since 0.3.63 the target field is no longer captured before dispatch, so
    /// correction observation (the source of learned hotwords) silently stopped.
    /// Capture after the user path has finished, off the main thread, and only
    /// start observing if no newer utterance has begun meanwhile.
    private func scheduleBackgroundCorrectionCapture(
        sessionID: UUID,
        insertedText: String,
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) {
        guard settings.correctionCaptureEnabled else {
            correctionCaptureStatus = String(localized: "插入后修改观察已关闭")
            return
        }
        if let bundleIdentifier, Self.correctionCaptureSkippedBundles.contains(bundleIdentifier) {
            correctionCaptureStatus = String(localized: "终端不提供可观察文本；未监听后续修改")
            return
        }
        correctionCaptureGeneration &+= 1
        let generation = correctionCaptureGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            let snapshot = await Task.detached(priority: .utility) {
                AccessibilityTargetService().capture(processIdentifier: processIdentifier)
            }.value
            guard let self,
                  generation == self.correctionCaptureGeneration,
                  self.state == .idle || self.state == .preview else { return }
            guard let snapshot else {
                self.correctionCaptureStatus = String(localized: "当前输入控件不暴露文本内容；未观察后续修改")
                return
            }
            self.startCorrectionObservation(
                sessionID: sessionID,
                insertedText: insertedText,
                target: snapshot
            )
        }
    }

    /// A replacement the user has made at least twice after dictation is
    /// learned as a personal term automatically (removable in the console).
    private func learnHotwordIfRepeated(_ replacement: CorrectionReplacement) async {
        guard !replacement.punctuationOnly else { return }
        let corrected = replacement.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = replacement.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty,
              (2...24).contains(corrected.count),
              corrected.rangeOfCharacter(from: .letters) != nil,
              !personalTerms.contains(where: { $0.canonical.caseInsensitiveCompare(corrected) == .orderedSame })
        else { return }
        let suggestions = (try? await HistoryStore.shared.correctionSuggestions(limit: 200)) ?? []
        let occurrences = suggestions
            .filter { !$0.punctuationOnly && $0.corrected.trimmingCharacters(in: .whitespacesAndNewlines) == corrected }
            .reduce(0) { $0 + $1.occurrences }
        guard occurrences >= 2 else { return }
        sessionLogger.notice("hotword learned from repeated correction")
        upsertPersonalTerm(
            PersonalTerm(canonical: corrected, category: .other, pinned: false),
            message: String(localized: "已自动学习热词“\(corrected)”（你改过 \(occurrences) 次：\(original) → \(corrected)）")
        )
    }

    private func startCorrectionObservation(
        sessionID: UUID,
        insertedText: String,
        target: TargetSnapshot
    ) {
        guard settings.correctionCaptureEnabled else {
            correctionCaptureStatus = String(localized: "插入后修改观察已关闭")
            return
        }
        correctionCaptureStatus = String(localized: "正在短时观察本次插入的文字修改")
        let isObserving = correctionMonitor.observe(insertedText: insertedText, target: target) { [weak self] corrected, replacement in
            guard let self else { return }
            let capturedOriginal = replacement.original.isEmpty ? String(localized: "（新增）") : replacement.original
            let capturedCorrected = replacement.corrected.isEmpty ? String(localized: "（删除）") : replacement.corrected
            self.correctionCaptureStatus = replacement.punctuationOnly
                ? String(localized: "已捕获一次标点修正")
                : String(localized: "已捕获：\(capturedOriginal) → \(capturedCorrected)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await HistoryStore.shared.appendAction(
                        sessionID: sessionID,
                        correctedText: corrected,
                        message: String(localized: "已从目标输入框捕获用户修改"),
                        originalText: insertedText,
                        correctionSource: "observed-after-insertion",
                        targetBundleIdentifier: target.bundleIdentifier,
                        replacements: [replacement]
                    )
                    await self.refreshHistory()
                    await self.learnHotwordIfRepeated(replacement)
                } catch {
                    self.correctionCaptureStatus = String(localized: "修改已观察到，但保存失败")
                }
            }
        }
        if !isObserving {
            correctionCaptureStatus = String(localized: "当前输入控件不暴露文本内容；未观察后续修改")
        }
    }

    /// The cloud half of the post-stop selection, without side effects (the
    /// caller applies status, badge and quarantine only for the winner).
    /// Rules live in `CloudSelectionPolicy` (shared with iOS).
    private func resolveCloudPhase(
        session: ActiveDictationSession,
        standbyID: String?,
        primarySilent: Bool,
        cloudDeadline: UInt64
    ) async -> CloudPhaseResult {
        func remaining(until deadline: UInt64) -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            return deadline > now ? deadline - now : 1_000_000
        }
        // The primary gets the policy preference window
        // (`RealtimeCompletionPolicy.primaryPreferenceNanoseconds`) unless it
        // is already silent; one that failed with billing/auth returns at once.
        let softPrimary = await session.observePrimary(
            timeoutNanoseconds: max(
                1_000_000,
                CloudSelectionPolicy.preferenceWindowNanoseconds(primarySilent: primarySilent)
            )
        )
        var resolvedPrimary = softPrimary
        var standbyOutcome: ProviderRunOutcome?
        if let standbyID {
            standbyOutcome = await session.observeComparison(
                providerID: standbyID,
                timeoutNanoseconds: 1_000_000
            )
        }
        func standbyState() -> CloudCandidateState? {
            standbyID == nil ? nil : candidateState(standbyOutcome)
        }
        var decision = CloudSelectionPolicy.decide(
            primary: candidateState(resolvedPrimary),
            standby: standbyState(),
            stage: .softDeadline,
            primarySilent: primarySilent
        )
        switch decision {
        case .waitForPrimary:
            // No standby: the primary alone has the shared cloud deadline.
            resolvedPrimary = await session.resolvePrimary(
                timeoutNanoseconds: remaining(until: cloudDeadline)
            )
            decision = CloudSelectionPolicy.decide(
                primary: candidateState(resolvedPrimary),
                standby: standbyState(),
                stage: .softDeadline
            )
        case .waitForStandby, .waitForFirstUsable:
            if let standbyID,
               let winner = await session.raceCloudFinals(
                standbyProviderID: standbyID,
                timeoutNanoseconds: remaining(until: cloudDeadline)
               ) {
                if winner.isPrimary {
                    resolvedPrimary = winner.outcome
                } else {
                    standbyOutcome = winner.outcome
                }
                decision = CloudSelectionPolicy.decide(
                    primary: candidateState(resolvedPrimary),
                    standby: standbyState(),
                    stage: .race
                )
            } else {
                decision = .noUsableResult
            }
        case .takePrimary, .takeStandby, .noUsableResult:
            break
        }
        return CloudPhaseResult(decision: decision, primary: resolvedPrimary, standby: standbyOutcome)
    }

    /// Races the cloud selection against the local engine on the retained
    /// audio (`CloudLocalRacePolicy`). The local engine starts at stop when
    /// both clouds were already dead, 2.5 s after stop when no cloud result
    /// has arrived, or when the cloud selection gives up; the first usable
    /// result wins and a cloud result arriving first still wins.
    private func raceCloudAgainstLocal(
        session: ActiveDictationSession,
        cloudTask: Task<CloudPhaseResult, Never>,
        stopUptime: UInt64,
        cloudsDeadAtStop: Bool,
        localAvailable: Bool,
        userPathDeadline: UInt64
    ) async -> CloudLocalRaceResult {
        enum RaceEvent: Sendable {
            case cloud(CloudPhaseResult)
            case local(ProviderRunOutcome)
            case timer
        }
        let (events, sink) = AsyncStream<RaceEvent>.makeStream()
        Task { sink.yield(.cloud(await cloudTask.value)) }
        let delay = CloudLocalRacePolicy.localStartDelay(cloudsDeadAtStop: cloudsDeadAtStop)
        if localAvailable, delay > 0 {
            Task {
                let target = stopUptime &+ delay
                let now = DispatchTime.now().uptimeNanoseconds
                if target > now { try? await Task.sleep(nanoseconds: target - now) }
                sink.yield(.timer)
            }
        }

        var cloud: CloudPhaseResult?
        var local: ProviderRunOutcome?
        var localRun: LocalFallbackRun?
        var localStart: LocalRaceStart?
        func decide() -> CloudLocalRaceDecision {
            let now = DispatchTime.now().uptimeNanoseconds
            let cloudPhase: CloudRacePhase = cloud.map { $0.isUsable ? .usable : .exhausted } ?? .pending
            let localPhase: LocalRacePhase
            if !localAvailable {
                localPhase = .unavailable
            } else if let local {
                localPhase = isUsable(local) ? .usable : .failed
            } else {
                localPhase = localRun == nil ? .notStarted : .running
            }
            return CloudLocalRacePolicy.decide(
                elapsedSinceStop: now > stopUptime ? now - stopUptime : 0,
                cloud: cloudPhase,
                local: localPhase,
                cloudsDeadAtStop: cloudsDeadAtStop,
                localStart: localStart
            )
        }

        var iterator = events.makeAsyncIterator()
        var decision = decide()
        raceLoop: while true {
            switch decision {
            case .startLocal(let start):
                localStart = start
                let now = DispatchTime.now().uptimeNanoseconds
                let run = session.startLocalFallback(
                    context: personalASRContext(
                        providerID: Self.localProviderID,
                        targetBundleIdentifier: session.targetBundleIdentifier
                    ),
                    timeoutNanoseconds: userPathDeadline > now ? userPathDeadline - now : 1_000_000
                )
                localRun = run
                if start != .cloudExhausted {
                    statusMessage = String(localized: "云端较慢，正在同时用本地转写")
                    overlayController.updateMessage(statusMessage, sessionID: session.id)
                }
                Task { sink.yield(.local(await run.task.value)) }
                decision = decide()
            case .wait:
                guard let event = await iterator.next() else {
                    decision = .noUsableResult
                    break raceLoop
                }
                switch event {
                case .cloud(let result): cloud = result
                case .local(let outcome): local = outcome
                case .timer: break
                }
                decision = decide()
            case .takeCloud, .takeLocal, .noUsableResult:
                break raceLoop
            }
        }
        sink.finish()

        var localCancelled = false
        if case .takeLocal = decision {
            // handled by the caller
        } else if let localRun, local == nil {
            localRun.cancel()
            localCancelled = true
            local = ProviderRunOutcome.failure(
                providerID: Self.localProviderID,
                model: Self.localProviderID,
                error: CancellationError(),
                terminationReason: .cancelled
            )
        }
        return CloudLocalRaceResult(
            decision: decision,
            cloud: cloud,
            local: local,
            localStart: localStart,
            localCancelled: localCancelled
        )
    }

    private func persist(
        session: ActiveDictationSession,
        primary: ProviderRunOutcome,
        alreadyResolvedApple: ProviderRunOutcome?,
        alreadyResolvedComparisons: [String: ProviderRunOutcome],
        effectiveProviderID: String?,
        usedOfflineFallback: Bool,
        insertedText: String,
        insertion: InsertionResult,
        selectedReason: String,
        userPathFinishedAt: Date,
        extraNotes: [String] = []
    ) {
        let appleTask = session.appleTask
        let comparisonTasks = session.comparisonTasks
        let archiveTask = session.archiveTask
        let shouldKeepSuccessfulAudio = settings.saveAudio
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var networkPath = session.networkPath
        if networkPath != nil, let startGeneration = session.networkPathGeneration {
            networkPath?.changedDuringSession = networkPathObserver.current().generation != startGeneration
        }
        let recordedNetworkPath = networkPath
        Task(priority: .utility) { [weak self] in
            var comparisons = alreadyResolvedComparisons
            for (providerID, _) in comparisonTasks where comparisons[providerID] == nil {
                if let outcome = await session.resolveComparison(
                    providerID: providerID,
                    timeoutNanoseconds: 2_000_000_000
                ) {
                    comparisons[providerID] = outcome
                }
            }
            let apple: ProviderRunOutcome?
            if let alreadyResolvedApple {
                apple = alreadyResolvedApple
            } else if let appleTask {
                switch await CompletionDeadline.wait(
                    for: appleTask,
                    timeoutNanoseconds: 2_000_000_000,
                    onTimeout: { appleTask.cancel() }
                ) {
                case .completed(let outcome): apple = outcome
                case .timedOut: apple = nil
                }
            } else {
                apple = nil
            }

            var audioURL: URL?
            if let archiveTask {
                switch await CompletionDeadline.wait(
                    for: archiveTask,
                    timeoutNanoseconds: 5_000_000_000,
                    onTimeout: { archiveTask.cancel() }
                ) {
                case .completed(let url): audioURL = url
                case .timedOut: audioURL = nil
                }
            } else {
                audioURL = nil
            }
            if !shouldKeepSuccessfulAudio, let disposableURL = audioURL {
                try? FileManager.default.removeItem(at: disposableURL)
                audioURL = nil
            }
            let persistenceFinishedAt = Date()
            session.timeline.mark(.persistenceFinished)
            let originalRevision = insertedText.isEmpty ? nil : TranscriptRevision(
                id: UUID(),
                createdAt: userPathFinishedAt,
                source: .original,
                providerID: effectiveProviderID ?? primary.providerID,
                model: effectiveProviderID == primary.providerID
                    ? primary.model
                    : (comparisons[effectiveProviderID ?? ""]?.model ?? primary.model),
                text: insertedText,
                error: nil
            )
            func summary(_ outcome: ProviderRunOutcome) -> ProviderSummary {
                var summary = outcome.summary
                summary.liveness = session.livenessRecord(providerID: outcome.providerID)
                return summary
            }
            let record = HistoryRecord(
                id: session.id,
                startedAt: session.startedAt,
                finishedAt: userPathFinishedAt,
                targetBundleIdentifier: session.targetBundleIdentifier,
                targetApplicationName: session.targetApplicationName,
                primary: summary(primary),
                appleBaseline: apple?.summary,
                comparisons: comparisons.values
                    .sorted { $0.providerID < $1.providerID }
                    .map(summary),
                effectiveProviderID: effectiveProviderID,
                usedOfflineFallback: usedOfflineFallback,
                insertedText: insertedText,
                insertionStatus: insertion.status,
                insertionTransport: insertion.transport,
                insertionAttempts: insertion.attempts,
                providerContextReceipts: session.providerContextReceipts,
                audioRelativePath: audioURL.map { "audio/\($0.lastPathComponent)" },
                preRollMilliseconds: session.preRollMilliseconds,
                notes: [insertion.message] + (usedOfflineFallback ? [String(localized: "云端失败后使用本地模型")] : []) + extraNotes,
                schemaVersion: 2,
                appVersion: appVersion,
                buildNumber: buildNumber,
                timeline: session.timeline.snapshot(),
                selectedReason: selectedReason,
                userPathFinishedAt: userPathFinishedAt,
                persistenceFinishedAt: persistenceFinishedAt,
                disposition: insertion.status == .failed ? .failed : .committed,
                audioState: audioURL == nil ? .unavailable : .available,
                transcriptRevisions: originalRevision.map { [$0] },
                selectedRevisionID: originalRevision?.id,
                networkPath: recordedNetworkPath
            )
            try? await HistoryStore.shared.append(record)
            // Only the canonical append is installation-critical. UI refresh
            // and quota maintenance must never strand the runtime handshake in
            // `criticalPersist` if SwiftUI or filesystem enumeration stalls.
            await MainActor.run { [weak self] in
                self?.finishCriticalPersistence()
            }
            await self?.refreshHistory()
            await self?.runStorageMaintenance()
        }
    }

    private func finishCriticalPersistence() {
        installStatusReporter.endCriticalPersistence()
    }

    private func selectedProviders(preconnectedSoniox: LeasedSonioxProvider? = nil) -> (
        primary: any ASRProvider,
        comparisons: [any ASRProvider],
        baseline: (any ASRProvider)?,
        bypassedOutage: ProviderOutage?
    ) {
        if settings.primaryProvider == .localSenseVoice {
            return (LocalSenseVoiceProvider(), [], nil, nil)
        }
        let configuredPrimaryID = configuredCloudPrimaryID

        // S0 runs exactly two cloud instances per session: the configured
        // primary plus the other configured cloud as a non-blocking hot
        // standby. Local ASR is intentionally not streamed in parallel; it
        // replays the complete retained audio only after both cloud routes
        // have exhausted the shared eight-second cloud budget.
        let configuredStandbyID: String?
        if configuredPrimaryID == Self.sonioxProviderID, aliyunKeyConfigured {
            configuredStandbyID = Self.aliyunProviderID
        } else if configuredPrimaryID == Self.aliyunProviderID, sonioxKeyConfigured {
            configuredStandbyID = Self.sonioxProviderID
        } else {
            configuredStandbyID = nil
        }

        // A primary known to be out of balance or rejecting its key is not
        // started at all: the standby takes the user path from the first
        // chunk, and a throttled background probe decides when to return.
        let route = ProviderAvailabilityPolicy.route(
            configuredPrimaryID: configuredPrimaryID,
            configuredStandbyID: configuredStandbyID,
            outages: providerOutages.snapshot()
        )
        let comparisons = route.standbyID.map { [makeSessionCloudProvider(id: $0, preconnected: nil)] } ?? []
        let primary = makeSessionCloudProvider(id: route.primaryID, preconnected: preconnectedSoniox)
        return (primary, comparisons, nil, route.bypassedOutage)
    }

    /// Live dictation providers. Soniox comes from the warm pool (or the
    /// press-time preconnect) behind a per-session lease; history
    /// retranscription and outage probes keep cold, TTL-0 instances.
    private func makeSessionCloudProvider(
        id: String,
        preconnected: LeasedSonioxProvider?
    ) -> any ASRProvider {
        guard id == Self.sonioxProviderID else { return makeAliyunProvider() }
        if let preconnected { return preconnected }
        return LeasedSonioxProvider(base: sonioxWarmPool.take() ?? makePooledSonioxProvider())
    }

    private func makePooledSonioxProvider() -> SonioxProvider {
        SonioxProvider(
            apiKeyProvider: { [personalSecrets] in
                guard let key = try personalSecrets.get(account: Self.sonioxAccount),
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ASRProviderError.missingAPIKey("Soniox")
                }
                return key
            },
            // Only an actor whose request ended with a clean `<fin>` is ever
            // offered back (`returnSonioxToWarmPoolWhenClean`); timeouts,
            // failures and cancels close the socket and drop the instance.
            // Soniox bills idle stream time, so the TTL is the cost knob.
            warmTTLProvider: { @MainActor [weak self] in
                self?.settings.warmConnectionTTL ?? 0
            }
        )
    }

    private func preconnectSonioxIfUseful(
        token: SessionGenerationToken,
        targetBundleIdentifier: String?
    ) {
        // With a zero TTL `prepare` would close the socket right away.
        guard settings.primaryProvider == .soniox,
              settings.warmConnectionTTL > 0,
              sonioxKeyConfigured,
              providerOutages.outage(for: Self.sonioxProviderID) == nil else { return }
        if var pending = pendingSonioxPreconnect {
            // An unused preconnect from a press that never became a session.
            pending.token = token
            pendingSonioxPreconnect = pending
            return
        }
        let provider = LeasedSonioxProvider(base: sonioxWarmPool.take() ?? makePooledSonioxProvider())
        let context = personalASRContext(
            providerID: Self.sonioxProviderID,
            targetBundleIdentifier: targetBundleIdentifier
        )
        let task = Task<Void, Error>(priority: .userInitiated) {
            // A warm socket with the same configuration returns at once.
            try? await provider.prepare(context: context)
        }
        pendingSonioxPreconnect = PendingSonioxPreconnect(token: token, provider: provider, task: task)
    }

    /// A preconnected socket that no session used is still clean.
    private func releaseSonioxPreconnect(_ preconnect: PendingSonioxPreconnect) {
        let base = preconnect.provider.base
        let task = preconnect.task
        Task { @MainActor [weak self] in
            _ = try? await task.value
            self?.sonioxWarmPool.offer(base)
        }
    }

    private func returnSonioxToWarmPoolWhenClean(_ session: ActiveDictationSession) {
        guard let leased = session.cloudProvider(id: Self.sonioxProviderID) as? LeasedSonioxProvider,
              let task = session.providerTask(id: Self.sonioxProviderID) else { return }
        let base = leased.base
        Task { @MainActor [weak self] in
            let outcome = await task.value
            guard outcome.terminationReason == .completed else { return }
            self?.sonioxWarmPool.offer(base)
        }
    }

    private func makeCloudProvider(id: String) -> any ASRProvider {
        id == Self.aliyunProviderID ? makeAliyunProvider() : makeSonioxProvider()
    }

    static func providerDisplayName(_ providerID: String?) -> String {
        switch providerID {
        case sonioxProviderID: return "Soniox"
        case aliyunProviderID: return String(localized: "阿里云")
        case localProviderID: return String(localized: "本地")
        default: return providerID ?? String(localized: "热备")
        }
    }

    // MARK: Provider outages (billing / auth)

    /// Records what this session learned about a cloud provider. Returns the
    /// one-line notice to show after insertion when the provider has just
    /// become unusable and the standby result was used instead.
    @discardableResult
    private func recordProviderAvailability(
        _ outcome: ProviderRunOutcome?,
        fallbackProviderID: String?
    ) -> String? {
        guard let outcome,
              outcome.providerID == Self.sonioxProviderID || outcome.providerID == Self.aliyunProviderID,
              outcome.terminationReason != .cancelled else { return nil }
        let change = providerOutages.record(
            providerID: outcome.providerID,
            completed: outcome.terminationReason == .completed,
            failureKind: outcome.failureKind,
            message: outcome.errorMessage
        )
        // The published menu status is refreshed by the caller after the
        // user path (Unicode dispatch) has finished.
        guard case .began(let outage) = change else { return nil }
        sessionLogger.notice("provider outage began: \(outage.providerID, privacy: .public) kind=\(outage.kind.rawValue, privacy: .public)")
        return ProviderFailureClassifier.notice(
            kind: outage.kind,
            providerName: Self.providerDisplayName(outage.providerID),
            fallbackName: fallbackProviderID.map { Self.providerDisplayName($0) }
        )
    }

    private func refreshProviderOutageStatus() {
        let outages = providerOutages.snapshot()
        let configuredPrimaryID = configuredCloudPrimaryID
        // The configured primary's outage is the one that changes the user path.
        guard let outage = outages[configuredPrimaryID] ?? outages.values.sorted(by: { $0.since < $1.since }).first else {
            if providerOutageStatus != nil { providerOutageStatus = nil }
            return
        }
        let fallbackID = outage.providerID == Self.sonioxProviderID ? Self.aliyunProviderID : Self.sonioxProviderID
        let fallbackAvailable = outages[fallbackID] == nil
            && (fallbackID == Self.aliyunProviderID ? aliyunKeyConfigured : sonioxKeyConfigured)
        let status = ProviderOutageStatus(
            outage: outage,
            message: ProviderFailureClassifier.notice(
                kind: outage.kind,
                providerName: Self.providerDisplayName(outage.providerID),
                fallbackName: fallbackAvailable ? Self.providerDisplayName(fallbackID) : nil
            ),
            probing: providerOutageStatus?.providerID == outage.providerID && providerOutageStatus?.probing == true
        )
        if providerOutageStatus != status { providerOutageStatus = status }
    }

    /// At most one background probe per provider every ten minutes, or on
    /// the menu's 重试. Never awaited by a dictation.
    private func probeUnavailableProviders(userRequested: Bool = false) {
        for providerID in providerOutages.snapshot().keys
        where providerOutages.beginProbeIfDue(providerID: providerID, userRequested: userRequested) {
            let provider = makeCloudProvider(id: providerID)
            let context = personalASRContext(providerID: providerID)
            if providerOutageStatus?.providerID == providerID {
                providerOutageStatus?.probing = true
            }
            Task(priority: .utility) { [weak self] in
                let result = await ProviderProbe.run(provider, context: context)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let change = self.providerOutages.apply(probe: result, providerID: providerID)
                    if self.providerOutageStatus?.providerID == providerID {
                        self.providerOutageStatus?.probing = false
                    }
                    self.refreshProviderOutageStatus()
                    if case .recovered = change {
                        self.sessionLogger.notice("provider recovered: \(providerID, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Menu panel 重试: probe now instead of waiting for the throttle.
    func retryUnavailableProvider() {
        probeUnavailableProviders(userRequested: true)
    }

    private var configuredCloudPrimaryID: String {
        settings.primaryProvider == .aliyun ? Self.aliyunProviderID : Self.sonioxProviderID
    }

    /// A provider outcome as the selection policy sees it; nil is still running.
    private func candidateState(_ outcome: ProviderRunOutcome?) -> CloudCandidateState {
        guard let outcome else { return .pending }
        if isUsable(outcome) { return .usable }
        return .failed(outcome.failureKind)
    }

    private func isUsable(_ outcome: ProviderRunOutcome) -> Bool {
        guard let text = outcome.result?.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The other cloud engine's final for the same audio, if it has already
    /// arrived. Local fallback results never corroborate.
    private func corroboratingText(
        for session: ActiveDictationSession,
        chosenProviderID: String,
        primary: ProviderRunOutcome,
        resolved: [String: ProviderRunOutcome]
    ) async -> String? {
        let cloudIDs = [Self.sonioxProviderID, Self.aliyunProviderID]
        guard cloudIDs.contains(chosenProviderID),
              let otherID = cloudIDs.first(where: { $0 != chosenProviderID }) else { return nil }
        let candidate: ProviderRunOutcome?
        if primary.providerID == otherID {
            candidate = primary
        } else if let known = resolved[otherID] {
            candidate = known
        } else {
            candidate = await session.observeComparison(providerID: otherID, timeoutNanoseconds: 1_000_000)
        }
        guard let candidate, isUsable(candidate) else { return nil }
        return candidate.result?.text
    }

    private func personalASRContext(
        providerID: String? = nil,
        targetBundleIdentifier: String? = nil
    ) -> ASRContext {
        let resolvedProviderID = providerID ?? {
            switch settings.primaryProvider {
            case .soniox: return "soniox"
            case .aliyun: return "aliyun-qwen-audio-asr"
            case .localSenseVoice: return "local-sensevoice"
            }
        }()
        return ProviderContextCompiler.compile(
            sessionID: UUID(),
            providerID: resolvedProviderID,
            personalTerms: effectivePersonalTerms,
            builtInTerms: settings.contextBuiltInTerms,
            targetBundleIdentifier: targetBundleIdentifier,
            prompt: settings.transcriptionPrompt,
            hotwordWeight: settings.hotwordWeight,
            speakerBackground: settings.speakerBackground
        ).context
    }

    private var effectivePersonalTerms: [PersonalTerm] {
        if !personalTerms.isEmpty { return personalTerms }
        return settings.glossaryTerms.map {
            PersonalTerm(canonical: $0, pinned: true)
        }
    }

    private func compileProviderContexts(
        sessionID: UUID,
        primary: any ASRProvider,
        comparisons: [any ASRProvider],
        baseline: (any ASRProvider)?,
        targetBundleIdentifier: String?
    ) -> (contexts: [String: ASRContext], receipts: [ProviderContextReceipt]) {
        var providers: [any ASRProvider] = [primary]
        providers.append(contentsOf: comparisons)
        if let baseline, !providers.contains(where: { $0.id == baseline.id }) {
            providers.append(baseline)
        }
        var contexts: [String: ASRContext] = [:]
        var receipts: [ProviderContextReceipt] = []
        for provider in providers {
            let compiled = ProviderContextCompiler.compile(
                sessionID: sessionID,
                providerID: provider.id,
                personalTerms: effectivePersonalTerms,
                builtInTerms: settings.contextBuiltInTerms,
                targetBundleIdentifier: targetBundleIdentifier,
                prompt: settings.transcriptionPrompt,
                hotwordWeight: settings.hotwordWeight,
                speakerBackground: settings.speakerBackground
            )
            contexts[provider.id] = compiled.context
            receipts.append(compiled.receipt)
        }
        return (contexts, receipts)
    }

    func receiptSummary(_ receipt: ProviderContextReceipt) -> String {
        if receipt.capabilitiesUsed.contains("terms_unsupported") {
            return String(localized: "\(receipt.provider)：本地暂不支持个人术语")
        }
        if receipt.droppedCount > 0 {
            return String(localized: "\(receipt.provider)：上次已发送 \(receipt.includedTerms.count, format: .number.grouping(.never)) / 候选 \(receipt.candidateCount, format: .number.grouping(.never))，未发送 \(receipt.droppedCount, format: .number.grouping(.never))")
        }
        return String(localized: "\(receipt.provider)：上次已发送 \(receipt.includedTerms.count, format: .number.grouping(.never)) / 候选 \(receipt.candidateCount, format: .number.grouping(.never))")
    }

    private func scheduleMaximumDuration(for session: ActiveDictationSession) {
        maximumDurationTask?.cancel()
        let seconds = max(10, settings.maximumUtteranceSeconds)
        maximumDurationTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled,
                  let self,
                  let session,
                  self.activeSession === session,
                  self.state == .listening || self.state == .starting else { return }
            self.statusMessage = String(localized: "已达到 \(seconds) 秒上限，正在自动定稿")
            self.endDictation()
        }
    }

    private func refreshAPIKeyState() {
        do {
            sonioxKeyConfigured = try personalSecrets.contains(account: Self.sonioxAccount)
        } catch {
            NSLog("[VerbatimVoice] personal Soniox credential check failed: %@", error.localizedDescription)
        }
        do {
            aliyunKeyConfigured = try personalSecrets.contains(account: Self.aliyunAccount)
        } catch {
            NSLog("[VerbatimVoice] personal Aliyun credential check failed: %@", error.localizedDescription)
        }
        NSLog(
            "[VerbatimVoice] API Key items: soniox=%d aliyun=%d",
            sonioxKeyConfigured ? 1 : 0,
            aliyunKeyConfigured ? 1 : 0
        )
    }

    private func makeAliyunProvider() -> AliyunASRProvider {
        AliyunASRProvider(
            apiKeyProvider: { [personalSecrets] in
                guard let key = try personalSecrets.get(account: Self.aliyunAccount),
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ASRProviderError.missingAPIKey(String(localized: "阿里云百炼"))
                }
                return key
            },
            regionProvider: {
                AliyunRegion(
                    rawValue: UserDefaults.standard.string(forKey: "aliyunRegion") ?? ""
                ) ?? .beijing
            }
        )
    }

    private func makeSonioxProvider() -> SonioxProvider {
        SonioxProvider(
            apiKeyProvider: { [personalSecrets] in
                guard let key = try personalSecrets.get(account: Self.sonioxAccount),
                      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ASRProviderError.missingAPIKey("Soniox")
                }
                return key
            },
            // A session owns this socket. It must never be returned to a warm
            // pool after timeout/cancel because that is how poisoned actors
            // contaminated later recordings.
            warmTTLProvider: { 0 }
        )
    }

    /// Reads the old Keychain at most once, then normal app operation never
    /// touches it again. A canceled migration is also considered completed so
    /// it cannot become another recurring authorization loop; the user can
    /// paste the key into Settings later.
    private func migrateLegacyCredentialsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.personalSecretMigrationKey) else { return }
        defer { defaults.set(true, forKey: Self.personalSecretMigrationKey) }

        for account in [Self.sonioxAccount, Self.aliyunAccount] {
            if (try? personalSecrets.contains(account: account)) == true { continue }
            guard let value = try? legacyKeychain.get(account: account),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try? personalSecrets.set(value, account: account)
        }
    }

    private func providerPreparationSignature(
        for provider: any ASRProvider,
        context: ASRContext
    ) -> String {
        let terms = context.terms.joined(separator: "\u{1F}")
        let general = context.general
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1E}")
        return provider.id + "|" + context.languages.joined(separator: ",")
            + "|" + terms + "|" + general + "|" + context.text
    }

    @discardableResult
    private func providerPreparationTask(
        for provider: any ASRProvider,
        context: ASRContext
    ) -> Task<Void, Error> {
        let signature = providerPreparationSignature(for: provider, context: context)
        if pendingProviderPreparationID == provider.id,
           pendingProviderPreparationSignature == signature,
           let existing = pendingProviderPreparationTask {
            return existing
        }

        cancelPendingProviderPreparation()
        let token = UUID()
        let task = Task(priority: .userInitiated) {
            try await provider.prepare(context: context)
        }
        pendingProviderPreparationTask = task
        pendingProviderPreparationID = provider.id
        pendingProviderPreparationSignature = signature
        pendingProviderPreparationToken = token

        Task { @MainActor [weak self] in
            _ = try? await task.value
            guard let self, self.pendingProviderPreparationToken == token else { return }
            self.pendingProviderPreparationTask = nil
            self.pendingProviderPreparationID = nil
            self.pendingProviderPreparationSignature = nil
            self.pendingProviderPreparationToken = nil
        }
        return task
    }

    private func cancelPendingProviderPreparation() {
        pendingProviderPreparationTask?.cancel()
        pendingProviderPreparationTask = nil
        pendingProviderPreparationID = nil
        pendingProviderPreparationSignature = nil
        pendingProviderPreparationToken = nil
    }

    private func warmPrimaryCloudProviderIfUseful() {
        // Frozen for S0. Reusing a warmed WebSocket across utterances makes a
        // timeout capable of poisoning the next session. Audio pre-roll keeps
        // the first word safe while the session-owned socket connects.
    }

    private func presentFailure(_ message: String) {
        lastError = message
        statusMessage = message
        state = .failed
        overlayController.present(mode: .failure, message: message, text: provisionalText, level: 0, anchor: nil)
        overlayController.dismiss(after: 2.2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            guard let self, self.state == .failed, self.activeSession == nil else { return }
            self.state = .idle
        }
    }
}

/// Menu-panel view of a `ProviderOutage`.
struct ProviderOutageStatus: Equatable {
    let providerID: String
    let kind: ProviderFailureKind
    /// e.g. "Soniox 余额不足，已改用阿里云".
    let message: String
    let actionTitle: String
    let actionURL: URL
    var probing: Bool

    init(outage: ProviderOutage, message: String, probing: Bool) {
        providerID = outage.providerID
        kind = outage.kind
        self.message = message
        self.probing = probing
        let isSoniox = outage.providerID == "soniox"
        actionTitle = outage.kind == .billing ? String(localized: "去充值") : String(localized: "检查 Key")
        actionURL = URL(string: isSoniox ? "https://console.soniox.com" : "https://bailian.console.aliyun.com")!
    }
}

/// A Soniox handshake started at the key press, before the session exists.
private struct PendingSonioxPreconnect {
    var token: SessionGenerationToken
    let provider: LeasedSonioxProvider
    let task: Task<Void, Error>
}

/// The cloud half of the post-stop selection.
struct CloudPhaseResult: Sendable {
    let decision: CloudSelectionDecision
    var primary: ProviderRunOutcome? = nil
    var standby: ProviderRunOutcome? = nil

    var isUsable: Bool {
        switch decision {
        case .takePrimary: return primary != nil
        case .takeStandby: return standby != nil
        default: return false
        }
    }
}

struct CloudLocalRaceResult {
    let decision: CloudLocalRaceDecision
    let cloud: CloudPhaseResult?
    /// The local outcome, or a cancelled placeholder when the cloud won.
    let local: ProviderRunOutcome?
    let localStart: LocalRaceStart?
    let localCancelled: Bool
}
