import Foundation
import Network
import UIKit

/// Re-transcribes failed dictations from the keyboard, without the user
/// going back to the app (README "键盘里重试").
///
/// A failed dictation is one mailbox entry (`Mailbox.postFailure`). A retry
/// moves that entry failed → retrying → pending (text) or back to failed
/// with the latest reason, and appends one revision to the same history
/// record (successful attempts only), so however many retries it takes the
/// user sees one result. The
/// archived audio is replayed through the existing history re-transcription
/// path (`HistoryModel.replay`, paced like live capture).
///
/// Triggers: the keyboard's `retry` request or URL; and once each, for
/// entries still waiting (failed or "稍后再试"), the network coming back
/// (NWPathMonitor → satisfied) and the next session starting.
@MainActor
final class RetryCoordinator {
    enum Origin: String {
        case keyboard
        case url
        case network
        case sessionStart
    }

    /// Automatic retries per entry per process, so a broken key does not
    /// loop on every network change.
    static let maximumAutomaticAttempts = 2
    /// Older failures are not retried automatically.
    static let automaticWindow: TimeInterval = 24 * 3_600
    /// The failure is posted before the history record and its audio are
    /// saved; a quick retry waits for them this long.
    static let recordWait: TimeInterval = 10

    /// True while a dictation runs: automatic retries wait for idle so a
    /// replay never competes with the live connection.
    var isBusy: @MainActor () -> Bool = { false }
    private var waitingOrigin: Origin?
    private var running: Set<UUID> = []
    private var automaticAttempts: [UUID: Int] = [:]
    private let monitor = NWPathMonitor()
    private var pathSatisfied: Bool?
    /// The path monitor has reported no usable network.
    var isOffline: Bool { pathSatisfied == false }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: MobileIdentity.label("retry-path"), qos: .utility))
    }

    /// A previous process died mid-retry: those entries are failed again.
    func recoverAfterLaunch() {
        guard let count = try? MobileEnvironment.mailbox.resetInterruptedRetries(reason: "上次重试被中断"),
              count > 0 else { return }
        SessionDiagnostics.log("retry.recovered", "count=\(count)")
        DarwinNotifier.post(.mailboxChanged)
    }

    /// Starts a retry of `sessionID`. False when there is nothing to retry
    /// (no failed entry, or one is already running).
    @discardableResult
    func retry(sessionID: UUID, origin: Origin) -> Bool {
        guard !running.contains(sessionID) else {
            SessionDiagnostics.log("retry.skip", "origin=\(origin.rawValue) reason=running")
            return false
        }
        let entry: MailboxEntry?
        do {
            entry = try MobileEnvironment.mailbox.beginRetry(sessionID: sessionID)
        } catch {
            SessionDiagnostics.log("retry.skip", "origin=\(origin.rawValue) reason=mailboxError error=\(AudioCapture.describe(error))")
            return false
        }
        guard let entry else {
            SessionDiagnostics.log("retry.skip", "origin=\(origin.rawValue) reason=notWaiting")
            return false
        }
        running.insert(sessionID)
        DarwinNotifier.post(.mailboxChanged)
        SessionDiagnostics.log("retry.start", "origin=\(origin.rawValue) attempt=\(entry.retryCount ?? 1)")
        Task { await run(sessionID: sessionID, origin: origin) }
        return true
    }

    /// One automatic attempt for every entry still waiting; deferred to
    /// `becameIdle()` while a dictation runs.
    func retryWaiting(origin: Origin) {
        if isBusy() {
            waitingOrigin = origin
            return
        }
        let now = Date()
        let waiting = MobileEnvironment.mailbox.read().entries.filter {
            $0.awaitsRetry && now.timeIntervalSince($0.createdAt) < Self.automaticWindow
        }
        for entry in waiting where (automaticAttempts[entry.sessionID] ?? 0) < Self.maximumAutomaticAttempts {
            automaticAttempts[entry.sessionID, default: 0] += 1
            retry(sessionID: entry.sessionID, origin: origin)
        }
    }

    /// The dictation ended: run an automatic retry that waited for it.
    func becameIdle() {
        guard let origin = waitingOrigin else { return }
        waitingOrigin = nil
        retryWaiting(origin: origin)
    }

    private func pathChanged(satisfied: Bool) {
        let previous = pathSatisfied
        pathSatisfied = satisfied
        guard satisfied, previous == false else { return }
        SessionDiagnostics.log("retry.networkBack")
        retryWaiting(origin: .network)
    }

    private func run(sessionID: UUID, origin: Origin) async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VerbatimRetry")
        defer {
            running.remove(sessionID)
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        let started = Date()
        let result = await transcribe(sessionID: sessionID)
        let ms = Int((Date().timeIntervalSince(started) * 1_000).rounded())
        do {
            switch result {
            case .success(let text, let providerID):
                try MobileEnvironment.mailbox.finishRetry(sessionID: sessionID, text: text)
                SessionDiagnostics.log("retry.result", "ok=1 origin=\(origin.rawValue) provider=\(providerID) chars=\(text.count) ms=\(ms)")
            case .failure(let reason):
                try MobileEnvironment.mailbox.failRetry(sessionID: sessionID, reason: reason)
                SessionDiagnostics.log("retry.result", "ok=0 origin=\(origin.rawValue) ms=\(ms) reason=\(reason.prefix(80))")
            }
        } catch {
            SessionDiagnostics.log("retry.mailbox.failed", "error=\(AudioCapture.describe(error))")
        }
        DarwinNotifier.post(.mailboxChanged)
        NotificationCenter.default.post(name: .verbatimHistoryChanged, object: nil)
    }

    private enum Result {
        case success(text: String, providerID: String)
        case failure(String)
    }

    private func transcribe(sessionID: UUID) async -> Result {
        guard let record = await waitForRecord(sessionID) else {
            return .failure("找不到这次录音")
        }
        guard let audioURL = try? await HistoryStore.shared.audioURL(for: record) else {
            return .failure("这次录音没有保存音频")
        }
        guard let provider = DictationController.shared.retryProvider(for: record) else {
            return .failure("请先在 设置 里填写 Soniox 或百炼 API Key")
        }
        let contexts = DictationController.shared.compileContexts(sessionID: UUID(), providerIDs: [provider.id])
        let context = contexts.contexts[provider.id] ?? .personal(terms: [])
        let outcome = await HistoryModel.replay(audioURL: audioURL, provider: provider, context: context)
        let text = outcome.result?.text ?? ""
        guard outcome.result != nil, !text.isEmpty else {
            // Failed attempts stay out of history (one record, no stack of
            // error versions); `retry.result` logs them.
            SessionDiagnostics.log("retry.failure", "details=\((outcome.errorMessage ?? "-").prefix(240))")
            return .failure(FailureCopy.short([outcome], offline: isOffline))
        }
        let revision = TranscriptRevision(
            id: UUID(),
            createdAt: Date(),
            source: .retranscription,
            providerID: outcome.providerID,
            model: outcome.result?.model ?? outcome.model,
            text: text,
            error: nil
        )
        do {
            try await HistoryStore.shared.appendRevision(sessionID: sessionID, revision: revision)
        } catch {
            SessionDiagnostics.log("retry.history.failed", "error=\(AudioCapture.describe(error))")
        }
        return .success(text: text, providerID: outcome.providerID)
    }

    private func waitForRecord(_ sessionID: UUID) async -> HistoryRecord? {
        let deadline = Date().addingTimeInterval(Self.recordWait)
        while true {
            // The record is appended once the audio archive is final.
            if let record = try? await HistoryStore.shared.recent(limit: 200).first(where: { $0.id == sessionID }) {
                return record
            }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
