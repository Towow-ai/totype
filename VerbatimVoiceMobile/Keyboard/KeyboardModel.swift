import Foundation
import UIKit

/// Keyboard side of the session protocol.
///
/// Mic key: when the state says a session is active and its heartbeat is
/// younger than the idle timeout (`SharedSessionState.keyboardRoute`), the
/// keyboard writes a `KeyboardRequest`, posts `.keyboardRequest` and waits up
/// to `KeyboardRequest.answerTimeout` for the app's answer; otherwise, or
/// when the answer is `needsForeground` or missing, it opens
/// `<scheme>://record?request=<id>` instead. The route is judged from
/// the heartbeat age at the moment the state was read, never against the
/// render clock: the keyboard does not re-read while idle.
///
/// Auto-insert: dictations this keyboard instance started or stopped are
/// remembered in memory only. Their result is claimed and inserted as soon as
/// it appears, but only while this instance is visible. Leaving (disappear)
/// or a rebuilt process forgets them, and the result stays pending behind the
/// "插入" button.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Layer {
        case voice
        case letters
    }

    struct UndoOffer: Equatable {
        let text: String
        /// `documentContextBeforeInput` right after the insert; undo is only
        /// safe while the field still looks exactly like this.
        let contextAfter: String?
        let insertedAt: Date
    }

    @Published private(set) var pending: MailboxEntry?
    /// The newest failed or retrying dictation still worth showing.
    @Published private(set) var failure: MailboxEntry?
    @Published private(set) var session: SharedSessionState = .idle
    /// When `session` was read; the heartbeat age is measured at this
    /// instant (set together with `session`).
    private(set) var sessionReadAt = Date.distantPast
    @Published private(set) var levels: [UInt8] = []
    /// Both start from the last value this extension saw (its own
    /// UserDefaults) and are re-read only after `viewDidAppear`.
    @Published private(set) var hasFullAccess = KeyboardEnvironmentCache.hasFullAccess
    @Published private(set) var needsGlobeKey = KeyboardEnvironmentCache.needsGlobeKey
    @Published private(set) var returnKeyType: UIReturnKeyType = .default
    @Published private(set) var notice: String?
    @Published private(set) var waitingForApp = false
    @Published private(set) var undoOffer: UndoOffer?
    @Published var layer: Layer = .voice
    /// The app this keyboard is typing into, for this appearance only. It
    /// rides on the `<scheme>://record` URL so the app can return there
    /// once recording runs (README "自动返回原 App"). Rendered into the mic
    /// `Link`, so it must be known before the tap.
    @Published private(set) var hostTag: HostTag?

    struct HostTag: Equatable {
        let bundleID: String
        let pid: Int32
        /// Which lookup found it: 0 right after appearing, 1 at +150 ms,
        /// 2 at +400 ms, higher from later text changes or the tap path.
        let attempt: Int
    }
    /// Set by the SwiftUI root (`@Environment(\.openURL)`, the mechanism
    /// `Link` uses; it needs Full Access).
    var openURL: ((URL) -> Void)?

    private weak var controller: UIInputViewController?
    private let directory: URL?
    private let mailbox: Mailbox?
    private let stateStore: SharedSessionStateStore?
    private let requestStore: KeyboardRequestStore?
    private let levelStore: SharedLevelStore?
    private var observer: DarwinObserver?
    private var hostObservers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?
    /// Interval of the running poll loop (fast while dictating or waiting,
    /// 1 s otherwise while visible).
    private var pollInterval: UInt64 = 0
    private var answerTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?
    private var isVisible = false
    /// Set after `viewDidAppear` (one main-queue turn later), cleared on
    /// disappear. `textDocumentProxy` and `needsInputModeSwitchKey` are only
    /// touched while this is true.
    private var proxyReady = false
    private var outstanding: KeyboardRequest?
    /// Heartbeat of the state in which a request went unanswered. Until a
    /// newer heartbeat shows up, the mic opens the app directly (the proven
    /// `Link`) instead of waiting 800 ms again. Cleared on disappear.
    private var unansweredHeartbeat: Date?
    /// Start requests sent by this instance; matched against
    /// `originRequestID` to learn the dictation they started.
    private var startRequestIDs: [UUID] = []
    /// Dictations whose result this instance should insert by itself.
    private var awaitedSessionIDs: Set<UUID> = []
    /// Host lookups done in this appearance, and the last host pid seen
    /// (both for the diagnostics query when the host stays unknown).
    private var hostLookups = 0
    private var lastHostPid: Int32 = 0
    /// Bumped on every appear/disappear so stale delayed lookups do nothing.
    private var appearance = 0
    /// Delays after `viewDidAppear` (+1 turn) for the host lookup. The
    /// arbiter state sometimes lands a moment after the keyboard appears;
    /// the whole retry window stays within 400 ms and never blocks the UI.
    private static let hostLookupDelays: [Int] = [0, 150, 400]
    /// A failure older than this no longer shows in the status row (it is
    /// still retried automatically and kept in the app's history).
    static let failureShownFor: TimeInterval = 30 * 60
    static let fastPoll: UInt64 = 66_000_000
    /// While visible and idle: catches anything a missed Darwin
    /// notification or appearance callback would leave stale (device:
    /// ChatGPT sometimes showed no waveform while recording ran).
    static let idlePoll: UInt64 = 1_000_000_000

    /// Diagnostics (`keyboard-log.txt`): this controller instance, and
    /// per-dictation counts of what the waveform read.
    private let instanceTag = String(UUID().uuidString.prefix(4))
    private struct LevelStats {
        let sessionID: UUID?
        let startedAt = Date()
        var reads = 0
        var shown = 0
        var missing = 0
        var otherSession = 0
        var maxStaleMs = 0
        var firstShownMs: Int?
    }
    private var levelStats: LevelStats?

    init(controller: UIInputViewController) {
        self.controller = controller
        directory = AppGroup.sharedDirectory()
        mailbox = directory.map { Mailbox(directory: $0) }
        stateStore = directory.map { SharedSessionStateStore(directory: $0) }
        requestStore = directory.map { KeyboardRequestStore(directory: $0) }
        levelStore = directory.map { SharedLevelStore(directory: $0) }
        observer = DarwinObserver([.mailboxChanged, .sessionChanged]) { [weak self] notification in
            MainActor.assumeIsolated { self?.refresh(source: notification == .sessionChanged ? "darwinSession" : "darwinMailbox") }
        }
        // The host coming back from the background may not re-run the
        // appearance callbacks (the keyboard never left its window), and
        // Darwin notifications posted while suspended are lost.
        let host: [(Notification.Name, String)] = [
            (.NSExtensionHostWillEnterForeground, "hostForeground"),
            (.NSExtensionHostDidBecomeActive, "hostActive"),
            (.NSExtensionHostDidEnterBackground, "hostBackground")
        ]
        for (name, label) in host {
            hostObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let inWindow = self.controller?.viewIfLoaded?.window != nil
                    KeyboardDiagnostics.log("kb.\(label)", "inst=\(self.instanceTag) visible=\(self.isVisible ? 1 : 0) inWindow=\(inWindow ? 1 : 0) phase=\(self.phase.rawValue)")
                    guard label != "hostBackground" else { return }
                    // On screen again without appearance callbacks: count as
                    // visible so polling (waveform, answers) runs. The proxy
                    // stays untouched until the next viewDidAppear (crash in
                    // `_controllerState`), so auto-insert waits behind 插入.
                    if !self.isVisible, inWindow { self.isVisible = true }
                    self.refresh(source: label)
                }
            })
        }
        KeyboardDiagnostics.log("kb.init", "inst=\(instanceTag)")
    }

    /// For the globe key, which needs the controller as its touch target
    /// (`handleInputModeList(from:with:)`).
    var inputController: UIInputViewController? { controller }

    var phase: SharedSessionPhase { session.effectivePhase() }

    /// Heartbeat age when the state was read, in seconds.
    var heartbeatAgeAtRead: TimeInterval { sessionReadAt.timeIntervalSince(session.heartbeatAt) }

    /// Deterministic for a given read, so a SwiftUI re-render seconds later
    /// cannot turn the mic into a `Link`.
    var micRoute: KeyboardMicRoute {
        if let unansweredHeartbeat, session.sessionActive, session.heartbeatAt <= unansweredHeartbeat {
            return .openApp(why: "unanswered")
        }
        return session.keyboardRoute(heartbeatAge: heartbeatAgeAtRead)
    }

    var sessionLive: Bool { micRoute == .request }

    private func readSession() {
        session = stateStore?.read() ?? .idle
        sessionReadAt = Date()
    }

    var recentError: String? {
        guard phase == .idle, let error = session.lastError, let at = session.lastErrorAt,
              Date().timeIntervalSince(at) < 120 else { return nil }
        return error
    }

    var returnTitle: String {
        switch returnKeyType {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .join: return "加入"
        case .route: return "路线"
        case .continue: return "继续"
        case .emergencyCall: return "紧急呼叫"
        default: return "换行"
        }
    }

    /// System keyboards tint these return keys blue.
    var returnIsProminent: Bool {
        switch returnKeyType {
        case .send, .search, .google, .yahoo, .go, .done, .join, .route, .continue: return true
        default: return false
        }
    }

    // MARK: Lifecycle

    /// `viewWillAppear`: re-read the shared files with the cached
    /// environment. Never touches the text proxy (see
    /// `KeyboardViewController.viewWillAppear`).
    func willAppear() {
        isVisible = true
        proxyReady = false
        resetHost()
        refresh(source: "willAppear")
        KeyboardDiagnostics.log("kb.appear", "inst=\(instanceTag) \(stateSummary)")
    }

    /// `viewDidAppear`: the host connection is current now. Read the
    /// environment one main-queue turn later, then refresh again, since
    /// presence, auto-insert and the mic link all depend on Full Access.
    func didAppear() {
        isVisible = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.proxyReady = true
            self.updateEnvironment()
            if let directory = self.directory, self.hasFullAccess { KeyboardPresence.mark(directory: directory) }
            self.refresh(source: "didAppear")
            self.scheduleHostLookups()
        }
    }

    func textDidChange() {
        guard proxyReady else { return }
        updateEnvironment()
        if hostTag == nil { lookUpHost() }
    }

    func disappeared() {
        KeyboardDiagnostics.log("kb.disappear", "inst=\(instanceTag) \(stateSummary)")
        finishLevelStats(reason: "disappear")
        isVisible = false
        proxyReady = false
        // Leaving the field forgets auto-insert targets: results arriving
        // later wait behind the "插入" button.
        awaitedSessionIDs.removeAll()
        startRequestIDs.removeAll()
        outstanding = nil
        unansweredHeartbeat = nil
        waitingForApp = false
        answerTask?.cancel()
        answerTask = nil
        pollTask?.cancel()
        pollTask = nil
        clearUndo()
        resetHost()
    }

    // MARK: Host app

    private func resetHost() {
        appearance += 1
        hostTag = nil
        hostLookups = 0
        lastHostPid = 0
    }

    /// Runs after `viewDidAppear` (proxy ready), so nothing here overlaps
    /// the re-presentation window in which the controller must not be
    /// touched. The lookup itself never reads `textDocumentProxy`.
    private func scheduleHostLookups() {
        let current = appearance
        for delay in Self.hostLookupDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self, self.appearance == current, self.isVisible, self.proxyReady,
                      self.hostTag == nil else { return }
                self.lookUpHost()
            }
        }
    }

    private func lookUpHost() {
        guard proxyReady, isVisible, let controller else { return }
        var pid: Int32 = 0
        let bundle = VVHostIdentity.resolveHost(for: controller, pid: &pid)
        let attempt = hostLookups
        hostLookups += 1
        lastHostPid = pid
        if let bundle {
            let tag = HostTag(bundleID: bundle, pid: pid, attempt: attempt)
            if tag != hostTag { hostTag = tag }
        }
    }

    /// `host` and `hostPid` let the app return to the host after recording
    /// starts; the rest is for the diagnostics log only. Without a host the
    /// app keeps its return guide page.
    private var hostQuery: String {
        var items = ["swz=\(VVHostIdentity.swizzleOutcome)"]
        if let hostTag {
            items += ["host=\(hostTag.bundleID)", "hostPid=\(hostTag.pid)", "hsrc=pidMap", "htry=\(hostTag.attempt)"]
        } else {
            items += ["hostPid=\(lastHostPid)", "hmiss=\(hostLookups)"]
        }
        return items.joined(separator: "&")
    }

    private func updateEnvironment() {
        guard proxyReady, isVisible, let controller else { return }
        let access = controller.hasFullAccess
        let globe = controller.needsInputModeSwitchKey
        if access != hasFullAccess { hasFullAccess = access }
        if globe != needsGlobeKey { needsGlobeKey = globe }
        returnKeyType = controller.textDocumentProxy.returnKeyType ?? .default
        KeyboardEnvironmentCache.store(hasFullAccess: access, needsGlobeKey: globe)
    }

    func refresh(source: String = "other") {
        reload(source: source)
        updatePolling()
    }

    /// Phase, session flags, heartbeat age at read and the route, for the
    /// keyboard log.
    private var stateSummary: String {
        let route: String
        switch micRoute {
        case .request: route = "request"
        case .openApp(let why): route = "open:\(why)"
        }
        return "phase=\(phase.rawValue) active=\(session.sessionActive ? 1 : 0) paused=\(session.sessionPaused ? 1 : 0) hbAgeMs=\(Int((heartbeatAgeAtRead * 1_000).rounded())) route=\(route) rev=\(session.revision)"
    }

    /// Re-reads the shared files and acts on them; never touches polling.
    private func reload(source: String = "other") {
        if mailbox == nil {
            notice = "无法访问共享容器，请重装 \(MobileIdentity.displayName)"
        }
        let snapshot = mailbox?.read()
        let latestPending = snapshot?.latestPending
        if latestPending != pending { pending = latestPending }
        let latestFailure = snapshot?.latestFailure.flatMap {
            $0.state == .retrying || Date().timeIntervalSince($0.updatedAt) < Self.failureShownFor ? $0 : nil
        }
        if latestFailure != failure { failure = latestFailure }
        let previousPhase = phase
        let previousSession = session.sessionID
        readSession()
        if phase != previousPhase {
            KeyboardDiagnostics.log("kb.phase", "inst=\(instanceTag) \(previousPhase.rawValue)->\(phase.rawValue) src=\(source) visible=\(isVisible ? 1 : 0) polling=\(pollTask == nil ? 0 : 1) \(stateSummary)")
        }
        if phase == .recording {
            if levelStats == nil || levelStats?.sessionID != session.sessionID || previousSession != session.sessionID {
                finishLevelStats(reason: "newDictation")
                levelStats = LevelStats(sessionID: session.sessionID)
            }
            let snapshot = levelStore?.read()
            let matches = snapshot?.sessionID == session.sessionID
            let next = matches ? snapshot?.levels ?? [] : []
            if next != levels { levels = next }
            recordLevels(snapshot: snapshot, matches: matches)
        } else {
            if !levels.isEmpty { levels = [] }
            if previousPhase == .recording { finishLevelStats(reason: "phase=\(phase.rawValue)") }
        }
        linkStartedDictation()
        checkAnswer()
        autoInsertIfAwaited()
    }

    private func recordLevels(snapshot: SharedLevelSnapshot?, matches: Bool) {
        guard var stats = levelStats else { return }
        stats.reads += 1
        if snapshot == nil {
            stats.missing += 1
        } else if !matches {
            stats.otherSession += 1
        } else if let snapshot, !snapshot.levels.isEmpty {
            stats.shown += 1
            if stats.firstShownMs == nil { stats.firstShownMs = Int(Date().timeIntervalSince(stats.startedAt) * 1_000) }
            stats.maxStaleMs = max(stats.maxStaleMs, Int(Date().timeIntervalSince(snapshot.updatedAt) * 1_000))
        }
        levelStats = stats
    }

    /// One line per dictation seen while recording: how many level reads
    /// had data, were missing, or belonged to another dictation.
    private func finishLevelStats(reason: String) {
        guard let stats = levelStats else { return }
        levelStats = nil
        KeyboardDiagnostics.log(
            "kb.levels",
            "inst=\(instanceTag) end=\(reason) reads=\(stats.reads) shown=\(stats.shown) missing=\(stats.missing) otherSession=\(stats.otherSession) firstShownMs=\(stats.firstShownMs.map(String.init) ?? "none") maxStaleMs=\(stats.maxStaleMs) visible=\(isVisible ? 1 : 0)"
        )
    }

    // MARK: Mic

    /// Idle: start. Starting/recording: finish. Finalizing: nothing.
    func micTapped() {
        guard hasFullAccess else {
            notice = "需要在 设置 → 键盘 → \(MobileIdentity.displayName) 里打开“允许完全访问”"
            return
        }
        clearUndo()
        readSession()
        switch phase {
        case .idle: send(.start)
        case .starting, .recording: send(.stop)
        case .finalizing: break
        }
    }

    func finishTapped() {
        guard phase == .starting || phase == .recording else { return }
        send(.stop)
    }

    func cancelTapped() {
        guard phase == .starting || phase == .recording else { return }
        send(.cancel)
    }

    /// "重试" on a failed dictation: the app re-transcribes its audio in
    /// the background; while this keyboard stays visible the result is
    /// inserted by itself (with undo), otherwise it waits behind "插入".
    func retryTapped() {
        guard hasFullAccess else {
            notice = "需要在 设置 → 键盘 → \(MobileIdentity.displayName) 里打开“允许完全访问”"
            return
        }
        guard let entry = failure, entry.state == .failed else {
            // A failure known only from the session state (mailbox write
            // failed): the app's history can still retry it.
            if failure == nil, recentError != nil { openHistory() }
            return
        }
        clearUndo()
        readSession()
        send(.retry, target: entry.sessionID)
    }

    /// "稍后再试": hide the failure; the app retries it once when the
    /// network comes back or the next session starts.
    func deferRetryTapped() {
        guard let entry = failure, let mailbox, hasFullAccess else { return }
        _ = try? mailbox.deferRetry(sessionID: entry.sessionID)
        KeyboardDiagnostics.log("kb.deferRetry", "inst=\(instanceTag)")
        DarwinNotifier.post(.mailboxChanged)
        refresh(source: "deferRetry")
    }

    private func send(_ action: KeyboardRequestAction, target explicitTarget: UUID? = nil) {
        let target = action == .start ? nil : explicitTarget ?? session.sessionID
        let request = KeyboardRequest(action: action, targetSessionID: target, seenHeartbeatAt: session.heartbeatAt)
        switch action {
        case .start: startRequestIDs = Array((startRequestIDs + [request.id]).suffix(4))
        case .stop, .retry: if let target { awaitedSessionIDs.insert(target) }
        case .cancel: if let target { awaitedSessionIDs.remove(target) }
        }
        notice = nil
        KeyboardDiagnostics.log("kb.request", "inst=\(instanceTag) action=\(action.rawValue) \(stateSummary)")

        if case .openApp(let why) = micRoute {
            open(request, why: why)
            return
        }
        guard let requestStore else {
            open(request, why: "writeFailed")
            return
        }
        do {
            try requestStore.write(request)
        } catch {
            open(request, why: "writeFailed")
            return
        }
        outstanding = request
        waitingForApp = true
        DarwinNotifier.post(.keyboardRequest)
        updatePolling()
        answerTask?.cancel()
        answerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(KeyboardRequest.answerTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reload(source: "answerTimeout")
            // Still unanswered: the app is suspended or gone.
            if let outstanding = self.outstanding, outstanding.id == request.id {
                self.unansweredHeartbeat = self.session.heartbeatAt
                self.open(request, why: "timeout")
            }
        }
    }

    private func checkAnswer() {
        guard let request = outstanding, let result = session.answer(to: request.id) else { return }
        KeyboardDiagnostics.log("kb.answer", "inst=\(instanceTag) action=\(request.action.rawValue) result=\(result.rawValue) ms=\(Int(Date().timeIntervalSince(request.issuedAt) * 1_000))")
        outstanding = nil
        waitingForApp = false
        answerTask?.cancel()
        answerTask = nil
        if result == .needsForeground {
            open(request, why: "needsForeground")
        }
    }

    /// First tap with no live session: a `Link` destination, opened inside
    /// the tap like W1 did. The app answers this fresh ID; nothing to track,
    /// since the keyboard disappears when the app opens.
    var recordURL: URL {
        let why: String
        if case .openApp(let reason) = micRoute { why = reason } else { why = "request" }
        return URL(string: "\(MobileIdentity.urlScheme)://record?request=\(UUID().uuidString)&\(diagnosticQuery(why: why))&\(hostQuery)")!
    }

    /// Why the keyboard is opening the app instead of asking the running
    /// session, logged by the app (`diagnostics/session-log.txt`) so one
    /// reproduction names the branch. Never carries text. `hb` is the
    /// heartbeat age when the state was read; `hbAt` the heartbeat itself
    /// (epoch ms), which the app compares with its own last write; `rd` how
    /// long ago that read was when this URL was built (for a `Link`, at
    /// render time).
    private func diagnosticQuery(why: String) -> String {
        let known = session.heartbeatAt != .distantPast
        let age = known ? Int((heartbeatAgeAtRead * 1_000).rounded()) : -1
        let at = known ? Int64((session.heartbeatAt.timeIntervalSince1970 * 1_000).rounded()) : -1
        let read = Int((Date().timeIntervalSince(sessionReadAt) * 1_000).rounded())
        return "why=\(why)&hb=\(age)&hbAt=\(at)&rd=\(read)&active=\(session.sessionActive ? 1 : 0)&paused=\(session.sessionPaused ? 1 : 0)"
    }

    /// Falls back to opening the app; the URL carries the request ID so the
    /// app answers the same request and the result can still be linked.
    private func open(_ request: KeyboardRequest, why: String) {
        outstanding = nil
        waitingForApp = false
        answerTask?.cancel()
        answerTask = nil
        let host: String
        var extra = ""
        switch request.action {
        case .start: host = "record"
        case .stop: host = "stop"
        case .cancel: host = "cancel"
        case .retry:
            host = "retry"
            if let target = request.targetSessionID { extra = "&session=\(target.uuidString)" }
        }
        KeyboardDiagnostics.log("kb.open", "inst=\(instanceTag) action=\(request.action.rawValue) why=\(why) \(stateSummary)")
        // Programmatic path: one more live lookup just before building the URL.
        if hostTag == nil { lookUpHost() }
        guard let url = URL(string: "\(MobileIdentity.urlScheme)://\(host)?request=\(request.id.uuidString)\(extra)&\(diagnosticQuery(why: why))&\(hostQuery)"),
              let openURL else {
            notice = "无法打开 \(MobileIdentity.displayName)，请先打开一次主 App"
            return
        }
        openURL(url)
    }

    func openHistory() {
        guard let url = URL(string: "\(MobileIdentity.urlScheme)://history") else { return }
        openURL?(url)
    }

    /// The app publishes `originRequestID` with the dictation it started.
    private func linkStartedDictation() {
        guard let origin = session.originRequestID, let sessionID = session.sessionID,
              startRequestIDs.contains(origin) else { return }
        startRequestIDs.removeAll { $0 == origin }
        awaitedSessionIDs.insert(sessionID)
    }

    // MARK: Insert

    private func autoInsertIfAwaited() {
        guard isVisible, proxyReady, hasFullAccess, let entry = pending, awaitedSessionIDs.contains(entry.sessionID) else { return }
        awaitedSessionIDs.remove(entry.sessionID)
        insert(entry)
    }

    /// Manual path for results this instance did not ask for.
    func insertPending() {
        guard let entry = pending else { return }
        // A tap means the keyboard is on screen and connected, even if the
        // deferred viewDidAppear read has not run yet.
        proxyReady = true
        insert(entry)
    }

    /// At most once: claim (state + revision checked under the file lock),
    /// insert, then mark inserted. If the extension dies between insert and
    /// mark, the entry stays `claimed` and is never inserted again. The text
    /// goes in exactly as the app delivered it.
    private func insert(_ entry: MailboxEntry) {
        guard proxyReady, let mailbox, let proxy = controller?.textDocumentProxy else { return }
        guard hasFullAccess else {
            notice = "需要在 设置 → 键盘 里打开“允许完全访问”"
            return
        }
        do {
            guard let claimed = try mailbox.claim(sessionID: entry.sessionID, expectedRevision: entry.revision) else {
                notice = "这条内容已插入过或已变化"
                refresh()
                return
            }
            proxy.insertText(claimed.text)
            try mailbox.markInserted(sessionID: claimed.sessionID)
            notice = nil
            offerUndo(text: claimed.text, contextAfter: proxy.documentContextBeforeInput)
            DarwinNotifier.post(.mailboxChanged)
        } catch {
            notice = "插入失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func discardPending() {
        guard let entry = pending, let mailbox, hasFullAccess else { return }
        _ = try? mailbox.discard(sessionID: entry.sessionID)
        DarwinNotifier.post(.mailboxChanged)
        refresh(source: "discard")
    }

    private func offerUndo(text: String, contextAfter: String?) {
        undoOffer = UndoOffer(text: text, contextAfter: contextAfter, insertedAt: Date())
        undoTask?.cancel()
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.undoOffer = nil
        }
    }

    private func clearUndo() {
        undoTask?.cancel()
        undoTask = nil
        undoOffer = nil
    }

    /// Deletes exactly what was inserted, only if the cursor has not moved
    /// and nothing else was typed since.
    func undoInsert() {
        guard let offer = undoOffer, let proxy = controller?.textDocumentProxy else { return }
        clearUndo()
        let selection = proxy.selectedText ?? ""
        // The context before the cursor may be truncated by the host, so
        // either side can be the longer one. No context means no proof.
        guard selection.isEmpty, let after = offer.contextAfter, !after.isEmpty,
              proxy.documentContextBeforeInput == after,
              after.hasSuffix(offer.text) || offer.text.hasSuffix(after) else {
            notice = "光标已移动，无法撤销；原文在 \(MobileIdentity.displayName) 历史里"
            return
        }
        for _ in 0..<offer.text.count { proxy.deleteBackward() }
        notice = "已撤销插入，原文在 \(MobileIdentity.displayName) 历史里"
    }

    // MARK: Keys

    func insert(_ text: String) {
        clearUndo()
        controller?.textDocumentProxy.insertText(text)
    }

    func deleteBackward() {
        clearUndo()
        controller?.textDocumentProxy.deleteBackward()
    }

    /// Deletes back to the previous word boundary (accelerated delete).
    func deleteWordBackward() {
        clearUndo()
        guard let proxy = controller?.textDocumentProxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else {
            proxy.deleteBackward()
            return
        }
        var count = 0
        var sawWord = false
        for character in before.reversed() {
            if character.isWhitespace || character.isPunctuation {
                if sawWord { break }
            } else {
                sawWord = true
                // CJK has no spaces: treat each ideograph as a word.
                if character.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true {
                    if count == 0 { count = 1 }
                    break
                }
            }
            count += 1
        }
        for _ in 0..<max(1, count) { proxy.deleteBackward() }
    }

    func moveCursor(by offset: Int) {
        clearUndo()
        controller?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    func returnKey() {
        insert("\n")
    }

    func advanceToNextInputMode() {
        controller?.advanceToNextInputMode()
    }

    func playClick() {
        UIDevice.current.playInputClick()
    }

    // MARK: Polling

    /// ~15 Hz while a dictation runs or a request waits for its answer
    /// (waveform, timer, answer); 1 Hz otherwise while visible. The app
    /// posts `.sessionChanged` on every transition, but a notification
    /// posted while this process was suspended is lost, and the host can
    /// come back without new appearance callbacks; the slow poll bounds how
    /// long the keyboard can stay behind (a missed "recording" meant no
    /// waveform). The loop holds `self` only weakly, so a released keyboard
    /// stops it.
    private var desiredPollInterval: UInt64? {
        guard isVisible else { return nil }
        return waitingForApp || phase != .idle ? Self.fastPoll : Self.idlePoll
    }

    private func updatePolling() {
        guard let interval = desiredPollInterval else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        if pollTask != nil, pollInterval == interval { return }
        pollTask?.cancel()
        pollInterval = interval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                self.reload(source: interval == Self.fastPoll ? "poll" : "tick")
                if self.desiredPollInterval != interval {
                    self.pollTask = nil
                    self.updatePolling()
                    return
                }
            }
        }
    }
}

/// Last environment values this extension read, so a fresh instance starts
/// with them instead of touching the controller before `viewDidAppear`.
enum KeyboardEnvironmentCache {
    private static let accessKey = "lastHasFullAccess"
    private static let globeKey = "lastNeedsGlobeKey"

    static var hasFullAccess: Bool { UserDefaults.standard.bool(forKey: accessKey) }
    /// Face ID iPhones draw their own globe below the keyboard; the default
    /// only matters until the first read.
    static var needsGlobeKey: Bool { UserDefaults.standard.object(forKey: globeKey) as? Bool ?? false }

    static func store(hasFullAccess: Bool, needsGlobeKey: Bool) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: accessKey) as? Bool != hasFullAccess { defaults.set(hasFullAccess, forKey: accessKey) }
        if defaults.object(forKey: globeKey) as? Bool != needsGlobeKey { defaults.set(needsGlobeKey, forKey: globeKey) }
    }
}
