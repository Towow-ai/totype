import Foundation
import UIKit
import WidgetKit

enum RecordingPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case finalizing

    var shared: SharedSessionPhase {
        switch self {
        case .idle: return .idle
        case .starting: return .starting
        case .recording: return .recording
        case .finalizing: return .finalizing
        }
    }
}

enum RecordingTrigger: String, Sendable {
    case app
    case url
    case intent
    case keyboard
}

enum StopReason: String, Sendable {
    case user
    case interrupted
    case routeLost
    case maximumDuration
}

/// How long an idle session (engine running, nothing recording) lasts after
/// the last dictation. Stored in the app's UserDefaults.
enum SessionIdleTimeout: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3_600
    case manual = 0

    static let storageKey = "sessionIdleTimeoutSeconds"
    static let `default` = SessionIdleTimeout.fiveMinutes

    var id: Int { rawValue }

    var seconds: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .oneMinute: return "1 分钟"
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .oneHour: return "60 分钟"
        case .manual: return "直到手动结束"
        }
    }
}

enum SessionEndReason: String, Sendable {
    case user
    case idleTimeout
    case interrupted
    case routeLost
}

extension Notification.Name {
    static let verbatimHistoryChanged = Notification.Name("VerbatimHistoryChanged")
}

/// Owns the audio session and one dictation at a time.
///
/// Session: inactive → armed (engine running in the background, Live
/// Activity shown) → inactive after the idle timeout, a manual end, an
/// interruption or a lost route. Dictation inside a session: idle → starting
/// → recording → finalizing → idle. Every dictation arms a session first, so
/// the keyboard can start the next one through `KeyboardRequest` without
/// opening the app.
///
/// Invariants:
/// - "Recording" (UI, shared state, Live Activity) is shown only after the
///   first PCM buffer arrives, never on button press.
/// - A result is committed at most once per session: the generation token's
///   `claimCommit` gates the mailbox post, and the mailbox post is itself
///   idempotent per session ID.
/// - The transcript is the provider's text, verbatim. Nothing rewrites it.
/// - Every keyboard request read gets an answer in the shared state, so the
///   keyboard never waits out its timeout for a no-op.
/// - Ending a session never drops audio: a running dictation is stopped and
///   transcribed first.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var level: Float = 0
    @Published private(set) var liveText = ""
    @Published private(set) var notice: String?
    /// Recent levels (oldest first) for the waveform while recording.
    @Published private(set) var levelHistory: [Float] = []
    /// Engine running: the keyboard can dictate without opening the app.
    @Published private(set) var sessionActive = false
    /// Interrupted (call, Siri, other audio): the engine waits for the end of
    /// the interruption, the app coming to the foreground or the idle timeout.
    @Published private(set) var sessionPaused = false
    @Published private(set) var sessionEndsAt: Date?
    /// Set when a dictation was started from the keyboard through a URL:
    /// the app shows the "go back to your app" page.
    @Published var showReturnHint = false
    /// Primary engine unusable (balance, key); shown under the home session row.
    @Published private(set) var providerOutage: HomeOutage?
    /// "阿里云" while the hot standby carries dictation; the keyboard shows "已用阿里云".
    @Published private(set) var fallbackProviderName: String?
    @Published var mixWithOthers: Bool {
        didSet { UserDefaults.standard.set(mixWithOthers, forKey: Self.mixWithOthersKey) }
    }
    /// After a keyboard-started recording runs, go back to the app the
    /// keyboard was in (private API; README "自动返回原 App"). Default on;
    /// ignored in a build without TOTYPE_PRIVATE_HOST_RETURN.
    @Published var autoReturnToHost: Bool {
        didSet { UserDefaults.standard.set(autoReturnToHost, forKey: HostReturnCoordinator.settingKey) }
    }
    @Published var idleTimeout: SessionIdleTimeout {
        didSet {
            UserDefaults.standard.set(idleTimeout.rawValue, forKey: SessionIdleTimeout.storageKey)
            if sessionActive || sessionPaused, phase == .idle {
                scheduleIdleEnd()
                publishShared()
            }
        }
    }

    /// Reused macOS settings model: prompt, hotword weight, Aliyun region,
    /// maximum utterance length. Its provider choice is ignored on iOS.
    let settings = AppSettings()
    var personalTerms: [PersonalTerm] = []

    private static let mixWithOthersKey = "mixWithOthers"
    private let coordinator = DictationSessionCoordinator()
    private let capture = AudioCapture()
    private let liveActivity = LiveActivityController()
    private let hostReturn = HostReturnCoordinator()
    private let retries = RetryCoordinator()
    private var session: MobileTranscriptionSession?
    private var trigger: RecordingTrigger = .app
    private var partials: [String: String] = [:]
    /// 1 Hz shared-state heartbeat on `sharedWriteQueue` (not the main
    /// actor), running while a dictation or session is alive.
    private lazy var heartbeat = HeartbeatTimer(queue: sharedWriteQueue)
    private var maximumDurationTask: Task<Void, Never>?
    private var idleEndTask: Task<Void, Never>?
    private var lastLevelPublish = Date.distantPast
    private var requestObserver: DarwinObserver?
    private var originRequestID: UUID?
    private var handledRequestID: UUID?
    private var handledRequestResult: KeyboardRequestResult?
    private var lastError: String?
    private var lastErrorAt: Date?
    /// Process lifetime only: a relaunch tries every provider again.
    private let providerOutages = ProviderOutageTracker()
    /// The primary the keys would select, before outage routing.
    private var configuredPrimaryID: String?
    /// Which keys exist, read once per dictation in `start()` so later
    /// bookkeeping never touches the keychain on the user path.
    private var configuredProviderIDs: Set<String> = []
    private var restartTask: Task<Void, Never>?
    /// Heartbeat bookkeeping for the diagnostics log (main actor).
    private var lastBeatAt: Date?
    private var maximumBeatGap: TimeInterval = 0
    private var beatCount = 0
    private var beatFailures = 0
    /// Consecutive beats that found the armed engine not running.
    private var engineDownBeats = 0
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Heartbeat and level files are written here, off the main thread.
    private let sharedWriteQueue = DispatchQueue(label: MobileIdentity.label("shared-writes"), qos: .utility)

    private init() {
        // Default on: an armed session then never pauses the user's music,
        // and a mixable session can be re-activated in the background.
        mixWithOthers = UserDefaults.standard.object(forKey: Self.mixWithOthersKey) as? Bool ?? true
        autoReturnToHost = UserDefaults.standard.object(forKey: HostReturnCoordinator.settingKey) as? Bool ?? true
        let stored = UserDefaults.standard.object(forKey: SessionIdleTimeout.storageKey) as? Int
        idleTimeout = stored.flatMap(SessionIdleTimeout.init(rawValue:)) ?? .default
        // Here rather than in the window's .task: an intent can launch the
        // app without a scene.
        retries.isBusy = { [weak self] in self.map { $0.phase != .idle } ?? false }
        requestObserver = DarwinObserver([.keyboardRequest]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleKeyboardRequest() }
        }
        SessionDiagnostics.log(
            "app.launch",
            "version=\(MobileEnvironment.appVersion ?? "?")(\(MobileEnvironment.buildNumber ?? "?")) state=\(Self.appStateName()) idleTimeout=\(idleTimeout.rawValue)s mix=\(mixWithOthers)"
        )
        observeLifecycle()
    }

    /// App lifecycle and memory events, for the diagnostics log only.
    private func observeLifecycle() {
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "app.background"),
            (UIApplication.willEnterForegroundNotification, "app.willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "app.active"),
            (UIApplication.willResignActiveNotification, "app.willResignActive"),
            (UIApplication.willTerminateNotification, "app.willTerminate"),
            (UIApplication.didReceiveMemoryWarningNotification, "app.memoryWarning"),
        ]
        for (name, event) in events {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.logLifecycle(event) }
            })
        }
    }

    private func logLifecycle(_ event: String) {
        SessionDiagnostics.log(event, "\(sessionSummary()) bgRemaining=\(Self.backgroundRemaining()) footprintMB=\(SessionDiagnostics.footprintMB())")
    }

    /// The heartbeat the keyboard decided from against this process's last
    /// write: `hbLagMs` is how much newer the app's write was (near 0–1000
    /// when the keyboard read the current file; larger means the keyboard
    /// judged from an old read), `appBeatAgeMs` how old that write is now.
    nonisolated static func heartbeatComparison(keyboardSaw: Date?, now: Date = Date()) -> String {
        guard let written = MobileEnvironment.sessionState.lastWrittenHeartbeat else { return "hbLagMs=? appBeatAgeMs=?" }
        let lag = keyboardSaw.map { String(Int((written.timeIntervalSince($0) * 1_000).rounded())) } ?? "?"
        return "hbLagMs=\(lag) appBeatAgeMs=\(Int((now.timeIntervalSince(written) * 1_000).rounded()))"
    }

    /// One-line state for the log: no text, only flags.
    private func sessionSummary() -> String {
        "phase=\(phase) active=\(sessionActive) paused=\(sessionPaused) capture=\(capture.state) engineRunning=\(capture.isEngineRunning)"
    }

    static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// `inf` while iOS treats the app as running audio in the background
    /// (or in the foreground); a finite number means it will be suspended.
    static func backgroundRemaining() -> String {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        return remaining > 1e6 ? "inf" : String(format: "%.0fs", remaining)
    }

    // MARK: Lifecycle entry points

    /// Clears state left by a previous process that died mid-session.
    func recoverAfterLaunch() {
        retries.recoverAfterLaunch()
        #if DEBUG
        // Device check of background survival without dictating:
        // `devicectl device process launch … -armSessionOnLaunch YES`.
        if UserDefaults.standard.bool(forKey: "armSessionOnLaunch"), phase == .idle, !sessionActive, !sessionPaused {
            SessionDiagnostics.log("debug.armOnLaunch")
            Task { await armIdleSession() }
            return
        }
        #endif
        guard phase == .idle, !sessionActive, !sessionPaused else { return }
        let stale = MobileEnvironment.sessionState.read()
        // Outages are not carried across launches: drop a stale "已用阿里云".
        if stale.phase != .idle || stale.sessionActive
            || stale.fallbackProviderName != nil || stale.providerNotice != nil {
            publishShared()
        }
        liveActivity.endAll()
    }

    // MARK: Keyboard requests

    /// Reads the keyboard's latest request and answers it. Runs when the
    /// Darwin notification arrives (the app is alive in the background
    /// because the engine is running) and when the app becomes active.
    func handleKeyboardRequest() {
        guard let request = MobileEnvironment.keyboardRequests.unhandled(after: handledRequestID) else { return }
        SessionDiagnostics.log(
            "keyboard.request",
            "action=\(request.action.rawValue) ageMs=\(Int(Date().timeIntervalSince(request.issuedAt) * 1_000)) \(Self.heartbeatComparison(keyboardSaw: request.seenHeartbeatAt)) \(sessionSummary()) appState=\(Self.appStateName())"
        )
        let result: KeyboardRequestResult
        switch request.action {
        case .start:
            if phase != .idle {
                result = .ignored
            } else if capture.state == .running || UIApplication.shared.applicationState == .active {
                result = .accepted
                answer(request.id, result)
                Task { await start(trigger: .keyboard, requestID: request.id) }
                return
            } else if capture.state == .suspended {
                // Try to resume in the background; claim the ID now so the
                // keyboard's URL fallback for it is not run twice.
                handledRequestID = request.id
                handledRequestResult = nil
                Task {
                    if await resumeSession() {
                        answer(request.id, .accepted)
                        await start(trigger: .keyboard, requestID: request.id)
                    } else {
                        answer(request.id, .needsForeground)
                    }
                }
                return
            } else {
                // A background activation fails; the keyboard opens the app.
                result = .needsForeground
            }
        case .retry:
            guard let target = request.targetSessionID else {
                answer(request.id, .ignored)
                return
            }
            // Without a running engine the process may be suspended within
            // seconds; the URL brings it forward and arms a session.
            guard capture.state == .running || UIApplication.shared.applicationState == .active else {
                answer(request.id, .needsForeground)
                return
            }
            answer(request.id, retries.retry(sessionID: target, origin: .keyboard) ? .accepted : .ignored)
            return
        case .stop, .cancel:
            let current = session?.id
            let matches = request.targetSessionID == nil || request.targetSessionID == current
            guard (phase == .starting || phase == .recording), matches else {
                answer(request.id, .ignored)
                return
            }
            answer(request.id, .accepted)
            if request.action == .stop {
                Task { await stop(reason: .user) }
            } else {
                Task { await cancel() }
            }
            return
        }
        answer(request.id, result)
    }

    /// `<scheme>://record?request=<id>` and friends: the keyboard's
    /// fallback when no live session answered. The request ID links the
    /// dictation to the keyboard instance that asked, for auto-insert.
    func handleURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // The keyboard says why it opened the app instead of asking the
        // session (why / hb = heartbeat age in ms / active / paused).
        // Host fields (bundle ID, pid, which lookup found it, swizzle state)
        // name an app, never user text.
        let reported = items.filter { ["why", "hb", "hbAt", "rd", "active", "paused", "host", "hostPid", "hsrc", "htry", "hmiss", "swz"].contains($0.name) }
            .map { "kb.\($0.name)=\($0.value ?? "")" }
            .joined(separator: " ")
        let keyboardSaw = items.first { $0.name == "hbAt" }?.value
            .flatMap(Double.init)
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil }
        SessionDiagnostics.log("url.open", "host=\(url.host ?? "") \(reported) \(Self.heartbeatComparison(keyboardSaw: keyboardSaw)) \(sessionSummary())")
        let requestID = items.first { $0.name == "request" }?.value.flatMap(UUID.init(uuidString:))
        if let requestID {
            // Already acted on (accepted/ignored) through the request file.
            if requestID == handledRequestID, handledRequestResult == .accepted || handledRequestResult == .ignored {
                return
            }
            handledRequestID = requestID
            handledRequestResult = .accepted
        }
        switch url.host {
        case "record":
            if phase == .idle {
                showReturnHint = true
                let returnTo = returnTarget(items)
                let urlAt = Date()
                Task { await start(trigger: .url, requestID: requestID, returnTo: returnTo, urlAt: urlAt) }
            } else {
                if requestID != nil { handledRequestResult = .ignored }
                publishShared()
            }
        case "retry":
            let target = items.first { $0.name == "session" }?.value.flatMap(UUID.init(uuidString:))
            let started = target.map { retries.retry(sessionID: $0, origin: .url) } ?? false
            if requestID != nil, !started { handledRequestResult = .ignored }
            publishShared()
            // Nothing to record: arm a session (it keeps the process alive
            // in the background for the retry, and the next mic tap needs
            // no app switch; arming must finish in the foreground), then go
            // back to the keyboard's app.
            let returnTo = returnTarget(items)
            let urlAt = Date()
            Task {
                if phase == .idle, !sessionActive, !sessionPaused {
                    do {
                        try await armSession()
                        scheduleIdleEnd()
                        publishShared()
                    } catch {
                        SessionDiagnostics.log("retry.arm.failed", "error=\(AudioCapture.describe(error))")
                    }
                }
                if let returnTo { hostReturn.returnWithoutRecording(returnTo, urlAt: urlAt) }
            }
        case "stop":
            Task { await stop(reason: .user) }
        case "cancel":
            Task { await cancel() }
        default:
            if requestID != nil { publishShared() }
        }
    }

    /// The host to return to once recording runs, or nil (logged why).
    private func returnTarget(_ items: [URLQueryItem]) -> HostReturnTarget? {
        guard HostReturnCoordinator.isAvailable, autoReturnToHost else {
            SessionDiagnostics.log("autoReturn.skip", "reason=\(HostReturnCoordinator.isAvailable ? "disabled" : "notBuilt")")
            return nil
        }
        let parsed = HostReturnCoordinator.target(from: items)
        if let skip = parsed.skip { SessionDiagnostics.log("autoReturn.skip", "reason=\(skip)") }
        return parsed.target
    }

    private func answer(_ requestID: UUID, _ result: KeyboardRequestResult) {
        SessionDiagnostics.log("keyboard.answer", "result=\(result.rawValue)")
        handledRequestID = requestID
        handledRequestResult = result
        publishShared()
    }

    // MARK: Session

    /// Makes sure the engine runs: resumes a paused session, else arms a new
    /// one. Arming must first happen in the foreground.
    private func armSession() async throws {
        switch capture.state {
        case .running:
            return
        case .suspended:
            if await resumeSession() { return }
            capture.disarm()
        case .disarmed:
            break
        }
        try await capture.arm(mixWithOthers: mixWithOthers) { [weak self] event in
            Task { @MainActor in await self?.handleCapture(event) }
        }
        sessionActive = true
        sessionPaused = false
        sessionEndsAt = nil
        SessionDiagnostics.log("session.start", "idleTimeout=\(idleTimeout.rawValue)s mix=\(mixWithOthers) appState=\(Self.appStateName())")
        startHeartbeat()
        // Failures still waiting get one more try, once no dictation runs.
        retries.retryWaiting(origin: .sessionStart)
    }

    /// Provider for re-transcribing a failed dictation from the keyboard:
    /// the one that produced the record unless it is known to be out
    /// (balance, key) in this process, then whichever other key exists;
    /// on-device recognition when no key is saved.
    func retryProvider(for record: HistoryRecord) -> (any ASRProvider)? {
        let keychain = MobileEnvironment.keychain
        let preferred = record.effectiveProviderID ?? record.primary?.providerID
        var candidates = [preferred, MobileEnvironment.sonioxProviderID, MobileEnvironment.aliyunProviderID]
            .compactMap { $0 }
        candidates.sort { (providerOutages.outage(for: $0) == nil ? 0 : 1) < (providerOutages.outage(for: $1) == nil ? 0 : 1) }
        for id in candidates {
            switch id {
            case MobileEnvironment.sonioxProviderID where keychain.contains(.soniox):
                return MobileEnvironment.makeSonioxProvider()
            case MobileEnvironment.aliyunProviderID where keychain.contains(.aliyun):
                return MobileEnvironment.makeAliyunProvider()
            default:
                continue
            }
        }
        return MobileEnvironment.hasCloudKey ? nil : MobileEnvironment.makeLocalProvider(terms: personalTerms)
    }

    #if DEBUG
    /// Arms a session with no dictation, then runs the normal idle timer.
    private func armIdleSession() async {
        do {
            try await armSession()
            scheduleIdleEnd()
            publishShared()
        } catch {
            SessionDiagnostics.log("debug.armOnLaunch.failed", "error=\(AudioCapture.describe(error))")
            notice = "无法开启会话：\(error.localizedDescription)"
        }
    }
    #endif

    /// Interruption began: the keyboard must fall back to opening the app at
    /// once; a running dictation is stopped and transcribed. The engine is
    /// kept for `resumeSession()`; the idle timer keeps running.
    private func pauseSession() async {
        guard capture.state == .running else { return }
        SessionDiagnostics.log("session.pause", sessionSummary())
        capture.suspend()
        sessionActive = false
        sessionPaused = true
        publishShared()
        if phase == .starting || phase == .recording {
            await stop(reason: .interrupted)
        } else if idleEndTask == nil {
            scheduleIdleEnd()
            publishShared()
        }
    }

    /// Tries to restart a paused session (interruption ended with
    /// shouldResume, app came to the foreground, or a keyboard request).
    @discardableResult
    func resumeSession() async -> Bool {
        guard sessionPaused, capture.state == .suspended else { return capture.state == .running }
        if let endsAt = sessionEndsAt, endsAt <= Date() {
            await endSession(reason: .idleTimeout)
            return false
        }
        do {
            try await capture.resume()
        } catch {
            SessionDiagnostics.log("session.resume.failed", "error=\(AudioCapture.describe(error)) appState=\(Self.appStateName())")
            return false
        }
        SessionDiagnostics.log("session.resume", "appState=\(Self.appStateName())")
        sessionPaused = false
        sessionActive = true
        startHeartbeat()
        if phase == .idle { scheduleIdleEnd() }
        publishShared()
        return true
    }

    /// Foreground: resume a paused session, end one whose time ran out while
    /// the app was suspended, and read any request written meanwhile.
    func appBecameActive() {
        Task {
            if sessionPaused { await resumeSession() }
            handleKeyboardRequest()
        }
    }

    /// Ends the session. A running dictation is stopped and transcribed first,
    /// so what was already said is kept.
    func endSession(reason: SessionEndReason) async {
        // Releasing audio lets iOS suspend a background app at once; keep it
        // alive until the shared state and the Live Activity are updated.
        let backgroundTask = BackgroundTaskToken(name: "VerbatimEndSession")
        defer { backgroundTask.end() }
        idleEndTask?.cancel()
        idleEndTask = nil
        if phase == .starting || phase == .recording {
            let stopReason: StopReason
            switch reason {
            case .user, .idleTimeout: stopReason = .user
            case .interrupted: stopReason = .interrupted
            case .routeLost: stopReason = .routeLost
            }
            await stop(reason: stopReason)
        }
        idleEndTask?.cancel()
        idleEndTask = nil
        guard sessionActive || sessionPaused || capture.state != .disarmed else { return }
        SessionDiagnostics.log("session.end", "reason=\(reason.rawValue) \(sessionSummary()) appState=\(Self.appStateName())")
        capture.disarm()
        restartTask?.cancel()
        restartTask = nil
        sessionActive = false
        sessionPaused = false
        sessionEndsAt = nil
        let endActivity = phase == .idle
        if endActivity {
            heartbeat.stop()
            lastBeatAt = nil
        }
        switch reason {
        case .interrupted where notice == nil: notice = "会话被其他音频打断，已结束"
        case .routeLost where notice == nil: notice = "麦克风线路变化，会话已结束"
        default: break
        }
        publishShared()
        if endActivity { await liveActivity.endAndWait() }
    }

    private func scheduleIdleEnd() {
        idleEndTask?.cancel()
        idleEndTask = nil
        guard sessionActive || sessionPaused, let seconds = idleTimeout.seconds else {
            sessionEndsAt = nil
            return
        }
        let endsAt = Date().addingTimeInterval(seconds)
        sessionEndsAt = endsAt
        idleEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            self.idleEndTask = nil
            await self.endSession(reason: .idleTimeout)
        }
    }

    func toggle(trigger: RecordingTrigger) async {
        switch phase {
        case .idle: await start(trigger: trigger)
        case .starting, .recording: await stop(reason: .user)
        case .finalizing: break
        }
    }

    func start(trigger: RecordingTrigger, requestID: UUID? = nil,
               returnTo: HostReturnTarget? = nil, urlAt: Date = Date()) async {
        guard phase == .idle, session == nil,
              let token = coordinator.begin() else { return }
        if let returnTo {
            hostReturn.arm(returnTo, sessionID: token.sessionID, urlAt: urlAt)
        } else {
            hostReturn.cancel(reason: nil)
        }
        self.trigger = trigger
        originRequestID = requestID
        notice = nil
        lastError = nil
        lastErrorAt = nil
        liveText = ""
        partials = [:]
        level = 0
        levelHistory = []
        recordingStartedAt = nil
        idleEndTask?.cancel()
        idleEndTask = nil
        sessionEndsAt = nil
        phase = .starting
        SessionDiagnostics.log("dictation.start", "trigger=\(trigger.rawValue) \(sessionSummary()) appState=\(Self.appStateName())")
        publishShared()
        // The Live Activity exists only while listening or recognising
        // (AudioRecordingIntent also needs one while recording). Starting one
        // with the app in the background may be refused; that is logged.
        liveActivity.ensureStarted()
        startHeartbeat()

        guard await AudioCapture.requestPermission() else {
            abortStart(token, message: AudioCapture.CaptureError.permissionDenied.localizedDescription)
            return
        }
        // The user may have stopped while the permission prompt was up.
        guard coordinator.isCurrent(token), phase == .starting else { return }
        if personalTerms.isEmpty {
            // A cold start from the keyboard can arrive before the lexicon
            // view model has loaded.
            personalTerms = (try? await MobileEnvironment.lexiconStore.load()) ?? []
            guard coordinator.isCurrent(token), phase == .starting else { return }
        }

        let keychain = MobileEnvironment.keychain
        let hasSoniox = keychain.contains(.soniox)
        let hasAliyun = keychain.contains(.aliyun)
        let useLocal = !hasSoniox && !hasAliyun
        if useLocal {
            // No cloud key: Apple's on-device recognition. Its permission
            // prompt can only appear in the foreground, like the microphone's.
            if OnDeviceSpeech.authorization == .notDetermined, UIApplication.shared.applicationState == .active {
                _ = await OnDeviceSpeech.requestAuthorization()
                guard coordinator.isCurrent(token), phase == .starting else { return }
            }
            if let reason = await OnDeviceSpeech.unavailableReason() {
                abortStart(token, message: reason)
                return
            }
            guard coordinator.isCurrent(token), phase == .starting else { return }
        }
        let configuredPrimary = hasSoniox ? MobileEnvironment.sonioxProviderID
            : hasAliyun ? MobileEnvironment.aliyunProviderID : MobileEnvironment.localProviderID
        configuredPrimaryID = configuredPrimary
        configuredProviderIDs = useLocal ? [MobileEnvironment.localProviderID] : Set(
            [hasSoniox ? MobileEnvironment.sonioxProviderID : nil, hasAliyun ? MobileEnvironment.aliyunProviderID : nil]
                .compactMap { $0 }
        )
        // A primary known to be out of balance or rejecting its key is not
        // started: the standby takes the user path from the first chunk, and
        // a throttled background probe decides when to return (same policy
        // as macOS).
        let route = ProviderAvailabilityPolicy.route(
            configuredPrimaryID: configuredPrimary,
            configuredStandbyID: hasSoniox && hasAliyun ? MobileEnvironment.aliyunProviderID : nil,
            outages: providerOutages.snapshot()
        )
        let primaryProvider = route.primaryID == MobileEnvironment.localProviderID
            ? MobileEnvironment.makeLocalProvider(terms: personalTerms)
            : MobileEnvironment.makeProvider(id: route.primaryID)
        guard let primary = primaryProvider else {
            abortStart(token, message: "无法创建识别引擎 \(route.primaryID)")
            return
        }
        let standby = route.standbyID.flatMap { MobileEnvironment.makeProvider(id: $0) }
        if !providerOutages.snapshot().isEmpty {
            // Next main-loop turn: the probe is never part of starting to record.
            Task { @MainActor [weak self] in self?.probeUnavailableProviders() }
        }

        let providers = [primary] + (standby.map { [$0] } ?? [])
        let compiled = compileContexts(sessionID: token.sessionID, providerIDs: providers.map(\.id))
        let timeline = SessionTimelineRecorder()
        timeline.mark(.trigger)
        let session = MobileTranscriptionSession(
            token: token,
            timeline: timeline,
            primary: primary,
            standby: standby,
            contexts: compiled.contexts,
            receipts: compiled.receipts,
            eventHandler: { [weak self] event in
                Task { @MainActor in self?.handle(event, token: token) }
            }
        )
        self.session = session

        do {
            try await armSession()
        } catch {
            self.session = nil
            await discard(session)
            SessionDiagnostics.log("dictation.start.failed", "error=\(AudioCapture.describe(error)) appState=\(Self.appStateName())")
            let message = UIApplication.shared.applicationState == .active
                ? "无法启动录音：\(error.localizedDescription)"
                : "会话已结束，需要打开 \(MobileIdentity.displayName) 重新开始：\(error.localizedDescription)"
            abortStart(token, message: message)
            return
        }
        capture.beginRecording { [weak self] chunk, level in
            session.yield(chunk)
            Task { @MainActor in self?.didCapture(level: level, token: token) }
        }
        timeline.mark(.audioHardwareReady)
        scheduleMaximumDuration(token)
    }

    func stop(reason: StopReason) async {
        guard phase == .starting || phase == .recording else { return }
        maximumDurationTask?.cancel()
        guard let session else {
            // Still waiting for the permission prompt: cancel the pending start.
            if let token = coordinator.snapshot().token { coordinator.cancel(token) }
            returnToIdle()
            return
        }
        let token = session.token
        // Stopping from the Live Activity, Control Center or an interruption
        // usually happens with another app in front. capture.stop() releases
        // the audio session, so keep the process alive until the mailbox and
        // history writes below have finished.
        let backgroundTask = BackgroundTaskToken(name: "VerbatimFinalize")
        defer { backgroundTask.end() }

        if phase == .starting {
            // No audio arrived yet, so there is nothing to keep or transcribe.
            capture.endRecording()
            self.session = nil
            await discard(session)
            coordinator.cancel(token)
            notice = reason == .user ? nil : "录音尚未开始就被打断"
            returnToIdle()
            return
        }

        session.timeline.mark(.stopRequested)
        SessionDiagnostics.log("dictation.stop", "reason=\(reason.rawValue)")
        phase = .finalizing
        level = 0
        publishShared()
        if reason == .user || reason == .maximumDuration {
            // Post-roll as on macOS: keep the last syllable after the tap.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        capture.endRecording()
        session.finishInput()
        _ = coordinator.transition(token, to: .finalizing)
        if reason == .interrupted || reason == .routeLost {
            notice = "录音被打断，已按已录部分转写"
        }

        let selection = await session.selectResult()
        await commit(selection, session: session, reason: reason)
    }

    /// Cancel keeps the audio as a draft in history (same as the macOS
    /// retained cancel); nothing is posted to the keyboard.
    func cancel() async {
        guard phase == .starting || phase == .recording else { return }
        guard let session else {
            await stop(reason: .user)
            return
        }
        guard phase == .recording else {
            await stop(reason: .user)
            return
        }
        maximumDurationTask?.cancel()
        let backgroundTask = BackgroundTaskToken(name: "VerbatimCancel")
        defer { backgroundTask.end() }
        let token = session.token
        SessionDiagnostics.log("dictation.cancel")
        capture.endRecording()
        self.session = nil
        coordinator.cancel(token)
        notice = "已取消。录音保存在历史里，可以重新转写"
        returnToIdle()

        let audioURL = await session.cancelKeepingAudio()
        let finishedAt = Date()
        let record = HistoryRecord(
            id: session.id,
            startedAt: session.startedAt,
            finishedAt: finishedAt,
            targetBundleIdentifier: nil,
            targetApplicationName: nil,
            primary: ProviderSummary(
                providerID: session.primaryProviderID,
                model: session.primaryProviderID,
                text: "",
                firstPartialLatencyMilliseconds: nil,
                finalizeLatencyMilliseconds: nil,
                error: "用户取消",
                transportMetrics: nil,
                terminationReason: .cancelled
            ),
            appleBaseline: nil,
            comparisons: nil,
            effectiveProviderID: nil,
            usedOfflineFallback: false,
            insertedText: "",
            insertionStatus: .canceled,
            insertionTransport: InsertionTransport.none,
            insertionAttempts: nil,
            providerContextReceipts: session.receipts,
            audioRelativePath: audioURL.map { "audio/\($0.lastPathComponent)" },
            preRollMilliseconds: Int(AudioCapture.preRollSeconds * 1_000),
            notes: ["platform=ios", "trigger=\(trigger.rawValue)", "stop=cancel"],
            schemaVersion: 2,
            appVersion: MobileEnvironment.appVersion,
            buildNumber: MobileEnvironment.buildNumber,
            timeline: session.timeline.snapshot(),
            selectedReason: nil,
            userPathFinishedAt: finishedAt,
            persistenceFinishedAt: Date(),
            disposition: .retainedDraft,
            audioState: audioURL == nil ? .unavailable : .available
        )
        do {
            try await HistoryStore.shared.append(record)
        } catch {
            notice = "历史保存失败：\(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .verbatimHistoryChanged, object: nil)
    }

    // MARK: Commit

    private func commit(
        _ selection: CloudSelection,
        session: MobileTranscriptionSession,
        reason: StopReason
    ) async {
        let token = session.token
        guard coordinator.isCurrent(token), self.session === session else { return }
        let usable = selection.chosen.isUsable
        // In-memory bookkeeping only (no I/O; key presence was read in
        // start()): billing/auth take the provider out of later sessions;
        // the first time is announced.
        let fromStandby = usable && selection.chosen.providerID != (configuredPrimaryID ?? selection.primary.providerID)
        let outageNotice = recordProviderAvailability(
            selection.primary,
            fallbackProviderID: usable && selection.chosen.providerID != selection.primary.providerID
                ? selection.chosen.providerID
                : nil
        )
        if let standbyOutcome = selection.standby {
            recordProviderAvailability(standbyOutcome, fallbackProviderID: nil)
        }
        fallbackProviderName = fromStandby ? Self.providerName(selection.chosen.providerID) : nil
        // Verbatim: the provider's final text. The only change allowed is
        // restoring a known mishearing where the other engine, already
        // finished, heard the canonical term at the same position.
        let other = selection.chosen.providerID == selection.primary.providerID
            ? selection.standby : selection.primary
        let raw = usable ? (selection.chosen.result?.text ?? "") : ""
        let text = MisrecognitionNormalizer.apply(
            raw,
            rules: MisrecognitionNormalizer.rules(from: personalTerms),
            corroboration: other?.isUsable == true ? other?.result?.text : nil
        ).text

        if usable {
            session.timeline.mark(.resultSelected, providerID: selection.chosen.providerID)
            guard coordinator.claimCommit(token) else { return }
            do {
                try MobileEnvironment.mailbox.post(sessionID: session.id, text: text)
                DarwinNotifier.post(.mailboxChanged)
            } catch {
                notice = "结果已存入历史，但未能交给键盘：\(error.localizedDescription)"
            }
            liveText = text
            session.timeline.mark(.userPathFinished)
        } else {
            session.timeline.mark(.failed)
            _ = coordinator.transition(token, to: .failed)
            let details = [outageNotice, selection.primary.errorMessage, selection.standby?.errorMessage]
                .compactMap { $0 }
                .joined(separator: "；")
            notice = "没有得到可用的转写结果\(details.isEmpty ? "" : "：\(details)")。音频已保存，可在历史里重新转写"
            let reason = FailureCopy.short([selection.primary, selection.standby], offline: retries.isOffline)
            SessionDiagnostics.log("dictation.failure", "reason=\(reason) details=\(details.prefix(240))")
            // The keyboard shows the failure with "重试" from the mailbox
            // entry; `lastError` is only the fallback when that write fails.
            do {
                try MobileEnvironment.mailbox.postFailure(sessionID: session.id, reason: reason)
                DarwinNotifier.post(.mailboxChanged)
            } catch {
                lastError = reason
                lastErrorAt = Date()
            }
        }
        let userPathFinishedAt = Date()
        SessionDiagnostics.log(
            "dictation.result",
            "usable=\(usable) provider=\(selection.chosen.providerID) chars=\(usable ? text.count : 0) \(sessionSummary())"
        )

        // Free the controller before slow bookkeeping so the next dictation
        // can start immediately.
        self.session = nil
        _ = coordinator.finish(token, as: usable ? .completed : .failed)
        returnToIdle()

        let standby: ProviderOutcome?
        if let known = selection.standby {
            standby = known
        } else {
            standby = await session.resolveStandby(timeoutNanoseconds: 4_000_000_000)
        }
        let audioURL = await session.archiveTask.value
        var notes = ["platform=ios", "trigger=\(trigger.rawValue)", "stop=\(reason.rawValue)"]
        if usable { notes.append("mailbox=pending") }
        if let configured = configuredPrimaryID,
           session.primaryProviderID != configured,
           let bypassed = providerOutages.outage(for: configured) {
            notes.append("primary_bypassed=\(configured):\(bypassed.kind.rawValue)")
        }
        let record = HistoryRecord(
            id: session.id,
            startedAt: session.startedAt,
            finishedAt: userPathFinishedAt,
            targetBundleIdentifier: nil,
            targetApplicationName: nil,
            primary: selection.primary.summary,
            appleBaseline: nil,
            comparisons: standby.map { [$0.summary] },
            effectiveProviderID: usable ? selection.chosen.providerID : nil,
            usedOfflineFallback: false,
            insertedText: text,
            insertionStatus: usable ? .previewOnly : .failed,
            insertionTransport: InsertionTransport.none,
            insertionAttempts: nil,
            providerContextReceipts: session.receipts,
            audioRelativePath: audioURL.map { "audio/\($0.lastPathComponent)" },
            preRollMilliseconds: Int(AudioCapture.preRollSeconds * 1_000),
            notes: notes,
            schemaVersion: 2,
            appVersion: MobileEnvironment.appVersion,
            buildNumber: MobileEnvironment.buildNumber,
            timeline: session.timeline.snapshot(),
            selectedReason: selection.reason,
            userPathFinishedAt: userPathFinishedAt,
            persistenceFinishedAt: Date(),
            disposition: usable ? .committed : .failed,
            audioState: audioURL == nil ? .unavailable : .available
        )
        do {
            try await HistoryStore.shared.append(record)
        } catch {
            notice = "历史保存失败：\(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .verbatimHistoryChanged, object: nil)
    }

    // MARK: Provider outages (billing / auth)

    static func providerName(_ providerID: String) -> String {
        switch providerID {
        case MobileEnvironment.sonioxProviderID: return "Soniox"
        case MobileEnvironment.aliyunProviderID: return "阿里云"
        case MobileEnvironment.localProviderID: return "本机识别"
        default: return providerID
        }
    }

    /// Returns "Soniox 余额不足，已改用阿里云" when this outcome has just made
    /// the provider unusable.
    @discardableResult
    private func recordProviderAvailability(
        _ outcome: ProviderOutcome,
        fallbackProviderID: String?
    ) -> String? {
        guard outcome.terminationReason != .cancelled else { return nil }
        let change = providerOutages.record(
            providerID: outcome.providerID,
            completed: outcome.terminationReason == .completed,
            failureKind: outcome.failureKind,
            message: outcome.errorMessage
        )
        refreshProviderOutage()
        guard case .began(let outage) = change else { return nil }
        return ProviderFailureClassifier.notice(
            kind: outage.kind,
            providerName: Self.providerName(outage.providerID),
            fallbackName: fallbackProviderID.map(Self.providerName)
        )
    }

    private func refreshProviderOutage() {
        let outages = providerOutages.snapshot()
        let preferred = configuredPrimaryID.flatMap { outages[$0] }
        guard let outage = preferred ?? outages.values.sorted(by: { $0.since < $1.since }).first else {
            if providerOutage != nil {
                providerOutage = nil
                fallbackProviderName = nil
            }
            return
        }
        let fallbackID = outage.providerID == MobileEnvironment.sonioxProviderID
            ? MobileEnvironment.aliyunProviderID
            : MobileEnvironment.sonioxProviderID
        let fallbackUsable = outages[fallbackID] == nil && configuredProviderIDs.contains(fallbackID)
        let isSoniox = outage.providerID == MobileEnvironment.sonioxProviderID
        let next = HomeOutage(
            message: ProviderFailureClassifier.notice(
                kind: outage.kind,
                providerName: Self.providerName(outage.providerID),
                fallbackName: fallbackUsable ? Self.providerName(fallbackID) : nil
            ),
            actionTitle: outage.kind == .billing ? "去充值" : "检查 Key",
            actionURL: URL(string: isSoniox ? "https://console.soniox.com" : "https://bailian.console.aliyun.com")!,
            probing: providerOutage?.probing ?? false
        )
        if providerOutage != next { providerOutage = next }
    }

    /// At most one probe per provider every ten minutes, or on 重试.
    /// Fire-and-forget: a dictation never waits for it.
    private func probeUnavailableProviders(userRequested: Bool = false) {
        for providerID in providerOutages.snapshot().keys
        where providerOutages.beginProbeIfDue(providerID: providerID, userRequested: userRequested) {
            guard let provider = MobileEnvironment.makeProvider(id: providerID) else { continue }
            let context = compileContexts(sessionID: UUID(), providerIDs: [providerID]).contexts[providerID]
                ?? .personal(terms: [])
            providerOutage?.probing = true
            Task { [weak self] in
                let result = await ProviderProbe.run(provider, context: context)
                guard let self else { return }
                let change = self.providerOutages.apply(probe: result, providerID: providerID)
                self.providerOutage?.probing = false
                self.refreshProviderOutage()
                if case .recovered = change { self.fallbackProviderName = nil }
                self.publishShared()
            }
        }
    }

    /// Home 重试: probe now instead of waiting for the throttle.
    func retryUnavailableProvider() {
        probeUnavailableProviders(userRequested: true)
    }

    // MARK: Contexts

    func compileContexts(
        sessionID: UUID,
        providerIDs: [String]
    ) -> (contexts: [String: ASRContext], receipts: [ProviderContextReceipt]) {
        var contexts: [String: ASRContext] = [:]
        var receipts: [ProviderContextReceipt] = []
        for providerID in providerIDs {
            let compiled = ProviderContextCompiler.compile(
                sessionID: sessionID,
                providerID: providerID,
                personalTerms: personalTerms,
                builtInTerms: settings.contextBuiltInTerms,
                targetBundleIdentifier: nil,
                prompt: settings.transcriptionPrompt,
                hotwordWeight: settings.hotwordWeight,
                speakerBackground: settings.speakerBackground
            )
            contexts[providerID] = compiled.context
            receipts.append(compiled.receipt)
        }
        return (contexts, receipts)
    }

    // MARK: Events

    private func didCapture(level: Float, token: SessionGenerationToken) {
        guard coordinator.isCurrent(token), let session, session.token == token else { return }
        if phase == .starting {
            phase = .recording
            recordingStartedAt = Date()
            _ = coordinator.transition(token, to: .listening)
            publishShared()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Recording really runs now; only now may the app leave.
            hostReturn.recordingStarted(sessionID: token.sessionID)
        }
        hostReturn.audioBuffer(sessionID: token.sessionID)
        let now = Date()
        // ~15 Hz: the in-app waveform and the keyboard's level file.
        if phase == .recording, now.timeIntervalSince(lastLevelPublish) >= 1.0 / 15 {
            lastLevelPublish = now
            self.level = level
            levelHistory.append(level)
            if levelHistory.count > SharedLevelSnapshot.capacity {
                levelHistory.removeFirst(levelHistory.count - SharedLevelSnapshot.capacity)
            }
            let snapshot = SharedLevelSnapshot(
                sessionID: session.id,
                updatedAt: now,
                levels: levelHistory.map { UInt8(max(0, min(255, $0 * 255))) }
            )
            sharedWriteQueue.async { try? MobileEnvironment.levels.write(snapshot) }
        }
    }

    private func handle(_ event: ASREvent, token: SessionGenerationToken) {
        guard coordinator.isCurrent(token), let session, session.token == token else { return }
        switch event {
        case .partial(let providerID, let text):
            partials[providerID] = text
            liveText = partials[session.primaryProviderID] ?? text
        case .finalized(let providerID, let text):
            partials[providerID] = text
        case .failed(let providerID, _):
            partials.removeValue(forKey: providerID)
        case .connected, .warning:
            break
        }
    }

    /// Engine events arrive whether or not a dictation is running.
    /// A route change restarts the engine after a short debounce (AirPods
    /// switch fires several), off the main thread; if that fails the session
    /// ends. A running dictation is always stopped and transcribed first.
    private func handleCapture(_ event: AudioCapture.CaptureEvent) async {
        switch event {
        case .interruptionBegan:
            await pauseSession()
        case .interruptionEnded(let shouldResume):
            // A mixable session resumes even without shouldResume: that flag
            // is a playback hint, and an app that stops recording without
            // notifying others never sets it. Waiting for the foreground left
            // the session paused in the background, so the keyboard fell back
            // to opening the app. Re-activating a mixable session does not
            // interrupt the other app; a non-mixable one would, so it still
            // waits for the hint.
            if shouldResume || mixWithOthers { await resumeSession() }
        case .mediaServicesReset:
            await endSession(reason: .interrupted)
        case .configurationChanged:
            guard capture.state == .running else { return }
            restartTask?.cancel()
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self, self.capture.state == .running else { return }
                do {
                    try await self.capture.restart()
                } catch {
                    SessionDiagnostics.log("engine.restart.failed", "error=\(AudioCapture.describe(error)) appState=\(Self.appStateName())")
                    await self.endSession(reason: .routeLost)
                }
                if !Task.isCancelled { self.restartTask = nil }
            }
        }
    }

    // MARK: Helpers

    /// Capture is not running here: either it never started, or
    /// `AudioCapture.start` already cleaned up after its own failure.
    private func abortStart(_ token: SessionGenerationToken, message: String) {
        coordinator.cancel(token)
        notice = message
        returnToIdle()
    }

    /// Cancels providers and deletes the (empty) audio file of a session
    /// that never captured anything.
    private func discard(_ session: MobileTranscriptionSession) async {
        await session.cancel()
        if let url = await session.archiveTask.value {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Back to idle inside the session (or with no session if arming
    /// failed): the idle timer starts, the heartbeat and Live Activity stay
    /// while the session lives.
    private func returnToIdle() {
        hostReturn.cancel(reason: "dictationEnded")
        hostReturn.dictationEnded()
        phase = .idle
        recordingStartedAt = nil
        level = 0
        showReturnHint = false
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        if sessionActive || sessionPaused {
            scheduleIdleEnd()
        } else {
            heartbeat.stop()
        }
        // The island and Lock Screen show only listening and recognising;
        // the idle session's time left lives on the home session row.
        liveActivity.end()
        publishShared()
        retries.becameIdle()
    }

    private func publishShared() {
        let phase = phase.shared
        let sessionID = session?.id
        let recordingStartedAt = recordingStartedAt
        try? MobileEnvironment.sessionState.publish { [self] state in
            state.phase = phase
            state.sessionID = sessionID
            state.recordingStartedAt = recordingStartedAt
            state.sessionActive = sessionActive
            state.sessionPaused = sessionPaused
            state.sessionEndsAt = sessionEndsAt
            state.originRequestID = originRequestID
            state.handledRequestID = handledRequestID
            state.handledRequestResult = handledRequestResult
            state.lastError = lastError
            state.lastErrorAt = lastErrorAt
            state.fallbackProviderName = fallbackProviderName
            state.providerNotice = providerOutage?.message
            state.sessionIdleTimeout = idleTimeout.seconds
        }
        DarwinNotifier.post(.sessionChanged)
        liveActivity.update(
            phase: phase,
            recordingStartedAt: recordingStartedAt,
            sessionActive: sessionActive,
            sessionPaused: sessionPaused,
            sessionEndsAt: sessionEndsAt
        )
        ControlCenter.shared.reloadControls(ofKind: RecordingControlKind.identifier)
    }

    /// 1 Hz while a dictation or session is alive, idle included. The
    /// timer and the write (no fsync) run on the shared-write queue, so a
    /// busy main thread cannot delay the beat; only the bookkeeping below
    /// hops to the main actor.
    private func startHeartbeat() {
        lastBeatAt = nil
        maximumBeatGap = 0
        beatCount = 0
        engineDownBeats = 0
        heartbeat.start { [weak self] gap, error in
            Task { @MainActor in
                if let error { self?.heartbeatFailed(error) }
                self?.beat(writeGap: gap)
            }
        }
    }

    /// Per beat: gap bookkeeping (between actual writes), a stopped-engine
    /// check, and every 30 beats one `session.alive` line (the evidence
    /// that the app is still running in the background).
    private func beat(writeGap: TimeInterval?) {
        let now = Date()
        if let writeGap { maximumBeatGap = max(maximumBeatGap, writeGap) }
        lastBeatAt = now
        beatCount += 1
        checkEngine()
        if beatCount % 30 == 0 {
            SessionDiagnostics.log(
                "session.alive",
                "\(sessionSummary()) appState=\(Self.appStateName()) bgRemaining=\(Self.backgroundRemaining()) maxBeatGap=\(String(format: "%.2f", maximumBeatGap))s endsIn=\(sessionEndsAt.map { String(format: "%.0fs", $0.timeIntervalSinceNow) } ?? "none") route=\(AudioCapture.routeDescription()) footprintMB=\(SessionDiagnostics.footprintMB())"
            )
            maximumBeatGap = 0
        }
    }

    /// The engine can stop without a notification this code acts on (a
    /// configuration change it missed, a silent stop). Three beats in a row
    /// with an armed but stopped engine and no restart in flight: restart
    /// it the same way as a route change; if that fails the session ends,
    /// so the keyboard opens the app at once instead of waiting 800 ms.
    private func checkEngine() {
        guard capture.state == .running, phase == .idle || phase == .recording else {
            engineDownBeats = 0
            return
        }
        if capture.isEngineRunning {
            engineDownBeats = 0
            return
        }
        engineDownBeats += 1
        guard engineDownBeats == 3, restartTask == nil else { return }
        SessionDiagnostics.log("engine.stoppedUnexpectedly", "\(sessionSummary()) appState=\(Self.appStateName())")
        Task { await handleCapture(.configurationChanged) }
    }

    private func heartbeatFailed(_ error: Error) {
        beatFailures += 1
        if beatFailures == 1 || beatFailures % 60 == 0 {
            SessionDiagnostics.log("heartbeat.write.failed", "count=\(beatFailures) error=\(AudioCapture.describe(error))")
        }
    }

    private func scheduleMaximumDuration(_ token: SessionGenerationToken) {
        maximumDurationTask?.cancel()
        let seconds = max(10, settings.maximumUtteranceSeconds)
        maximumDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.coordinator.isCurrent(token) else { return }
            // Detach from this task first so stop() cancelling it does not
            // cut the post-roll short.
            self.maximumDurationTask = nil
            self.notice = "已达到 \(seconds) 秒上限，已自动结束"
            await self.stop(reason: .maximumDuration)
        }
    }
}

/// Fires every second on `queue` (a serial queue that never blocks for
/// long) and writes the shared-state heartbeat there. `onBeat` gets the
/// time since the previous write and any write error. All state is
/// confined to `queue`; the source is only ever resumed once and cancelled,
/// never suspended.
private final class HeartbeatTimer: @unchecked Sendable {
    private let queue: DispatchQueue
    private var source: DispatchSourceTimer?
    private var lastWrite: Date?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(onBeat: @escaping @Sendable (TimeInterval?, Error?) -> Void) {
        queue.async { [self] in
            source?.cancel()
            lastWrite = nil
            let timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.fire(onBeat) }
            source = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            lastWrite = nil
        }
    }

    private func fire(_ onBeat: @Sendable (TimeInterval?, Error?) -> Void) {
        let now = Date()
        var failure: Error?
        do {
            try MobileEnvironment.sessionState.heartbeat(now: now)
        } catch {
            failure = error
        }
        let gap = lastWrite.map { now.timeIntervalSince($0) }
        lastWrite = now
        onBeat(gap, failure)
    }
}

@MainActor
private final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
