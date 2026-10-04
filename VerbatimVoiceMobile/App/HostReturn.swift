import Foundation
#if TOTYPE_PRIVATE_HOST_RETURN
import ObjectiveC
#endif
import UIKit

/// The app the keyboard was typing into, as the keyboard reported it on a
/// `<scheme>://record` URL (`host`, `hostPid`). The app never derives
/// the host itself: the `_UIRemoteKeyboards` state visible here was stale on
/// device (it still named WeChat while the user was in Notes).
struct HostReturnTarget: Equatable {
    let bundleID: String
    let pid: Int?
    /// Which keyboard lookup found it (`htry`), for the log.
    let lookup: String
}

/// Returns to the host app once recording runs (README "自动返回原 App").
///
/// Order, verified on a device with iOS 26.6 beta (2026-10-01):
/// 1. `-[LSApplicationWorkspace openApplicationWithBundleID:]` (private):
///    WeChat and Notes came back to the exact screen, no prompt, ~35 ms.
/// 2. Only if (1) is missing or returns NO: a bundle-ID -> URL scheme table
///    with verified entries only (WeChat; first use asks "打开微信？").
/// 3. Otherwise nothing: the return guide page stays up.
///
/// Both the host lookup in the keyboard and (1) are private API, compiled
/// only with TOTYPE_PRIVATE_HOST_RETURN (Config/Shared.xcconfig). Without
/// it the keyboard never reports a host, so nothing here fires and every
/// keyboard-started recording keeps the guide page.
///
/// A target is armed by the URL, bound to one dictation, and fired at most
/// once: `delayAfterFirstBuffer` after the first PCM buffer (which proves
/// the audio session is active and the engine delivers), once the app is
/// active. An earlier build waited ~1 s after the URL; device logs 2026-10-01
/// showed the first buffer 0.5–0.7 s after the URL, so that floor only
/// added waiting. Whether audio keeps flowing after the switch is checked
/// for every return (`autoReturn.postReturnAudio`).
@MainActor
final class HostReturnCoordinator {
    static let settingKey = "autoReturnToHost"
    /// False in a build without TOTYPE_PRIVATE_HOST_RETURN; settings then
    /// hide the switch.
    #if TOTYPE_PRIVATE_HOST_RETURN
    nonisolated static let isAvailable = true
    #else
    nonisolated static let isAvailable = false
    #endif
    /// Margin after the first buffer before leaving the foreground.
    static let delayAfterFirstBuffer: TimeInterval = 0.1
    /// Window after the app reaches the background in which PCM must keep
    /// arriving, and the largest gap between buffers still counted as
    /// continuous (buffers come every ~40–100 ms).
    static let postReturnWindow: TimeInterval = 2.0
    static let postReturnMaxGap: TimeInterval = 0.4
    /// Waiting for the app to become active before giving up.
    static let activeDeadline: TimeInterval = 4.0
    /// System surfaces the keyboard can sit in but that were never tested
    /// as a return target.
    static let unsupportedHosts: Set<String> = ["com.apple.springboard", "com.apple.Spotlight"]
    /// Scheme fallback, verified entries only (device test 2026-10-01).
    static let verifiedSchemes: [String: String] = ["com.tencent.xin": "weixin://"]

    private struct Armed {
        let target: HostReturnTarget
        let sessionID: UUID
        let urlAt: Date
        /// False for a return with nothing recording (a `retry` URL).
        var watchAudio = true
    }

    private var armed: Armed?
    private var fireTask: Task<Void, Never>?
    private var attemptAt: Date?
    private var attemptMethod = ""
    private var verdictTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// PCM flow from the return attempt until `postReturnWindow` after the
    /// app reached the background.
    private struct AudioWatch {
        let sessionID: UUID
        let attemptAt: Date
        var lastBufferAt: Date
        var buffers = 0
        var maxGap: TimeInterval = 0
        var backgroundAt: Date?
    }
    private var audioWatch: AudioWatch?
    private var audioWatchTask: Task<Void, Never>?

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
    }

    // MARK: Parsing

    /// Reads the keyboard's host fields. Returns nil with the reason when
    /// there is nothing to return to.
    static func target(from items: [URLQueryItem]) -> (target: HostReturnTarget?, skip: String?) {
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let bundleID = value("host") else {
            return (nil, "noHost hmiss=\(value("hmiss") ?? "?") hostPid=\(value("hostPid") ?? "?")")
        }
        // ASCII letters, digits and ".-_" only.
        var allowed = CharacterSet(charactersIn: ".-_")
        allowed.insert(charactersIn: "a"..."z")
        allowed.insert(charactersIn: "A"..."Z")
        allowed.insert(charactersIn: "0"..."9")
        guard bundleID.count <= 155, bundleID.contains("."),
              bundleID.unicodeScalars.allSatisfy(allowed.contains) else {
            return (nil, "invalidHost")
        }
        if bundleID.hasPrefix(MobileIdentity.appBundleID) { return (nil, "selfHost") }
        if unsupportedHosts.contains(bundleID) { return (nil, "unsupportedHost host=\(bundleID)") }
        return (HostReturnTarget(bundleID: bundleID, pid: value("hostPid").flatMap(Int.init),
                                 lookup: "htry=\(value("htry") ?? "?")"), nil)
    }

    // MARK: Lifecycle

    /// A `record` URL started dictation `sessionID` with this target.
    func arm(_ target: HostReturnTarget, sessionID: UUID, urlAt: Date) {
        cancel(reason: nil)
        armed = Armed(target: target, sessionID: sessionID, urlAt: urlAt)
    }

    /// A `retry` URL: nothing records, so return as soon as the app is
    /// active (the retry runs in the background).
    func returnWithoutRecording(_ target: HostReturnTarget, urlAt: Date) {
        cancel(reason: nil)
        let token = UUID()
        let armed = Armed(target: target, sessionID: token, urlAt: urlAt, watchAudio: false)
        self.armed = armed
        let readyAt = Date()
        fireTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.activeDeadline)
            while !Task.isCancelled, UIApplication.shared.applicationState != .active, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.delayAfterFirstBuffer * 1_000_000_000))
            guard !Task.isCancelled, let self, self.armed?.sessionID == token else { return }
            self.fire(armed, firstBufferAt: readyAt)
        }
    }

    /// The dictation ended or failed before recording ran.
    func cancel(reason: String?) {
        fireTask?.cancel()
        fireTask = nil
        if let armed, let reason {
            SessionDiagnostics.log("autoReturn.skip", "reason=\(reason) host=\(armed.target.bundleID)")
        }
        armed = nil
    }

    /// First PCM buffer of dictation `sessionID`.
    func recordingStarted(sessionID: UUID) {
        guard let armed, armed.sessionID == sessionID, fireTask == nil else { return }
        let firstBufferAt = Date()
        fireTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.delayAfterFirstBuffer * 1_000_000_000))
            let deadline = Date().addingTimeInterval(Self.activeDeadline)
            while !Task.isCancelled, UIApplication.shared.applicationState == .inactive, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled, let self, self.armed?.sessionID == sessionID else { return }
            self.fire(armed, firstBufferAt: firstBufferAt)
        }
    }

    private func fire(_ armed: Armed, firstBufferAt: Date) {
        self.armed = nil
        fireTask = nil
        let state = UIApplication.shared.applicationState
        let timing = "msSinceUrl=\(Self.ms(since: armed.urlAt)) msSinceFirstBuffer=\(Self.ms(since: firstBufferAt))"
        guard state == .active else {
            // Background: the user already went back by hand.
            SessionDiagnostics.log("autoReturn.skip",
                                   "reason=notActive appState=\(state == .background ? "background" : "inactive") host=\(armed.target.bundleID) \(timing)")
            return
        }
        let host = armed.target.bundleID
        SessionDiagnostics.log("autoReturn.plan",
                               "host=\(host) hostPid=\(armed.target.pid.map(String.init) ?? "?") src=keyboard \(armed.target.lookup) \(timing)")

        let started = Date()
        let workspace = Self.openWithWorkspace(host)
        let workspaceMs = Self.ms(since: started)
        switch workspace {
        case .returned(true):
            begin(method: "workspace", sessionID: armed.sessionID, watchAudio: armed.watchAudio)
            SessionDiagnostics.log("autoReturn.attempt", "method=workspace returned=1 ms=\(workspaceMs) host=\(host)")
            return
        case .returned(false):
            SessionDiagnostics.log("autoReturn.attempt", "method=workspace returned=0 ms=\(workspaceMs) host=\(host)")
        case .unavailable(let why):
            SessionDiagnostics.log("autoReturn.attempt", "method=workspace unavailable=\(why) host=\(host)")
        }

        guard let scheme = Self.verifiedSchemes[host], let url = URL(string: scheme) else {
            SessionDiagnostics.log("autoReturn.result", "leftForeground=0 reason=noFallback host=\(host) guide=shown")
            return
        }
        begin(method: "scheme", sessionID: armed.sessionID, watchAudio: armed.watchAudio)
        let schemeStarted = Date()
        UIApplication.shared.open(url, options: [:]) { ok in
            SessionDiagnostics.log("autoReturn.attempt",
                                   "method=scheme url=\(scheme) ok=\(ok ? 1 : 0) ms=\(Self.ms(since: schemeStarted)) host=\(host)")
        }
    }

    /// Starts the "did we actually leave" check. One verdict per attempt:
    /// at `didEnterBackground`, or after 3 s without it.
    private func begin(method: String, sessionID: UUID, watchAudio: Bool) {
        let now = Date()
        attemptAt = now
        attemptMethod = method
        audioWatchTask?.cancel()
        audioWatchTask = nil
        audioWatch = watchAudio ? AudioWatch(sessionID: sessionID, attemptAt: now, lastBufferAt: now) : nil
        verdictTask?.cancel()
        verdictTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.attemptAt != nil else { return }
            self.attemptAt = nil
            self.audioWatch = nil
            SessionDiagnostics.log("autoReturn.result",
                                   "method=\(self.attemptMethod) leftForeground=0 waitedMs=3000 guide=shown")
        }
    }

    /// Every PCM buffer of dictation `sessionID` (main actor, cheap).
    func audioBuffer(sessionID: UUID) {
        guard var watch = audioWatch, watch.sessionID == sessionID else { return }
        let now = Date()
        watch.maxGap = max(watch.maxGap, now.timeIntervalSince(watch.lastBufferAt))
        watch.lastBufferAt = now
        watch.buffers += 1
        audioWatch = watch
    }

    /// The dictation ended inside the window: report what was seen so far.
    func dictationEnded() {
        guard audioWatch?.backgroundAt != nil else { return }
        reportAudio(endedEarly: true)
    }

    private func reportAudio(endedEarly: Bool = false) {
        guard var watch = audioWatch, let backgroundAt = watch.backgroundAt else { return }
        audioWatch = nil
        audioWatchTask?.cancel()
        audioWatchTask = nil
        let now = Date()
        // A silence running into the end of the window counts as a gap too.
        watch.maxGap = max(watch.maxGap, now.timeIntervalSince(watch.lastBufferAt))
        let ok = watch.buffers > 0 && watch.maxGap <= Self.postReturnMaxGap
        SessionDiagnostics.log(
            "autoReturn.postReturnAudio",
            "\(ok ? "ok" : "gap") buffers=\(watch.buffers) maxGapMs=\(Int((watch.maxGap * 1_000).rounded())) msAttemptToBackground=\(Int((backgroundAt.timeIntervalSince(watch.attemptAt) * 1_000).rounded())) windowMs=\(Self.ms(since: backgroundAt))\(endedEarly ? " endedEarly=1" : "")"
        )
    }

    private func didEnterBackground() {
        guard let attemptAt else { return }
        self.attemptAt = nil
        verdictTask?.cancel()
        verdictTask = nil
        SessionDiagnostics.log("autoReturn.result",
                               "method=\(attemptMethod) leftForeground=1 msToBackground=\(Self.ms(since: attemptAt))")
        guard audioWatch != nil else { return }
        audioWatch?.backgroundAt = Date()
        audioWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.postReturnWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reportAudio()
        }
    }

    // MARK: Private API

    enum WorkspaceOutcome {
        case returned(Bool)
        case unavailable(String)
    }

    /// `[[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:]`,
    /// resolved at run time; every step checked so a missing class or
    /// changed signature degrades to the scheme table / guide page.
    static func openWithWorkspace(_ bundleID: String) -> WorkspaceOutcome {
        #if TOTYPE_PRIVATE_HOST_RETURN
        guard let cls = NSClassFromString("LSApplicationWorkspace") else {
            return .unavailable("noClass")
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let defaultMethod = class_getClassMethod(cls, defaultSelector) else {
            return .unavailable("noDefaultWorkspace")
        }
        typealias DefaultFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let getDefault = unsafeBitCast(method_getImplementation(defaultMethod), to: DefaultFunction.self)
        guard let workspace = getDefault(cls, defaultSelector)?.takeUnretainedValue() as? NSObject else {
            return .unavailable("nilWorkspace")
        }
        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector),
              let method = class_getInstanceMethod(object_getClass(workspace), openSelector) else {
            return .unavailable("noSelector")
        }
        // Expected "B24@0:8@16": BOOL return, one object argument.
        guard let encoding = method_getTypeEncoding(method), encoding.pointee == CChar(UInt8(ascii: "B")),
              method_getNumberOfArguments(method) == 3 else {
            return .unavailable("unexpectedSignature")
        }
        typealias OpenFunction = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenFunction.self)
        return .returned(open(workspace, openSelector, bundleID as NSString))
        #else
        return .unavailable("disabled")
        #endif
    }

    nonisolated private static func ms(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}
