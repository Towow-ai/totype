import Foundation

/// One provider's end state for a session. iOS counterpart of the macOS
/// `ProviderRunOutcome` (that file also pulls in AppKit-only types).
struct ProviderOutcome: Sendable {
    let providerID: String
    let model: String
    let result: TranscriptResult?
    let errorMessage: String?
    let terminationReason: ProviderTerminationReason
    /// Why the provider failed; nil on success and on user cancellation.
    var failureKind: ProviderFailureKind? = nil

    static func success(_ result: TranscriptResult) -> ProviderOutcome {
        ProviderOutcome(
            providerID: result.providerID,
            model: result.model,
            result: result,
            errorMessage: nil,
            terminationReason: .completed
        )
    }

    static func failure(
        providerID: String,
        model: String,
        error: Error,
        terminationReason: ProviderTerminationReason = .failed
    ) -> ProviderOutcome {
        ProviderOutcome(
            providerID: providerID,
            model: model,
            result: nil,
            errorMessage: error.localizedDescription,
            terminationReason: terminationReason,
            failureKind: error is CancellationError ? nil : ProviderFailureKind.of(error)
        )
    }

    var isUsable: Bool {
        guard let text = result?.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summary: ProviderSummary {
        ProviderSummary(
            providerID: providerID,
            model: result?.model ?? model,
            text: result?.text ?? "",
            firstPartialLatencyMilliseconds: result?.firstPartialLatencyMilliseconds,
            finalizeLatencyMilliseconds: result?.finalizeLatencyMilliseconds,
            error: errorMessage,
            transportMetrics: result?.transportMetrics,
            terminationReason: terminationReason,
            failureKind: failureKind
        )
    }
}

struct CloudSelection: Sendable {
    let chosen: ProviderOutcome
    let primary: ProviderOutcome
    let standby: ProviderOutcome?
    let reason: String
}

/// Fans one microphone stream out to the primary provider, the optional
/// hot-standby provider and the audio archive. Stream handling, race and
/// deadline logic are ported from macOS `ActiveDictationSession` without the
/// pre-roll, Apple baseline and local-fallback parts.
final class MobileTranscriptionSession: @unchecked Sendable {
    let token: SessionGenerationToken
    let timeline: SessionTimelineRecorder
    let startedAt = Date()
    let primaryProviderID: String
    let standbyProviderID: String?
    let receipts: [ProviderContextReceipt]
    let archiveTask: Task<URL?, Never>

    var id: UUID { token.sessionID }

    private typealias PCMStream = AsyncThrowingStream<PCM16Chunk, Error>
    private struct StreamTarget {
        let name: String
        let isCritical: Bool
        let continuation: PCMStream.Continuation
    }

    private let primaryProvider: any ASRProvider
    private let standbyProvider: (any ASRProvider)?
    private let primaryTask: Task<ProviderOutcome, Never>
    private let standbyTask: Task<ProviderOutcome, Never>?
    private let eventHandler: @Sendable (ASREvent) -> Void
    /// Primary transport liveness; a silent primary skips the preference
    /// window (`CloudSelectionPolicy.preferenceWindowNanoseconds`, as on Mac).
    private let primaryLiveness = ProviderLivenessProbe()
    private let lock = NSLock()
    private var targets: [StreamTarget]
    private var finished = false

    init(
        token: SessionGenerationToken,
        timeline: SessionTimelineRecorder,
        primary: any ASRProvider,
        standby: (any ASRProvider)?,
        contexts: [String: ASRContext],
        receipts: [ProviderContextReceipt],
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) {
        self.token = token
        self.timeline = timeline
        self.receipts = receipts
        self.eventHandler = eventHandler
        primaryProvider = primary
        standbyProvider = standby
        primaryProviderID = primary.id
        standbyProviderID = standby?.id

        var built: [StreamTarget] = []
        let primaryPair = Self.makeStream()
        built.append(StreamTarget(name: primary.id, isCritical: true, continuation: primaryPair.continuation))
        primaryTask = Self.run(
            provider: primary,
            utteranceID: token.sessionID,
            context: contexts[primary.id] ?? .personal(terms: []),
            stream: primaryPair.stream,
            liveness: primaryLiveness,
            timeline: timeline,
            eventHandler: eventHandler
        )
        if let standby {
            let pair = Self.makeStream()
            built.append(StreamTarget(name: standby.id, isCritical: false, continuation: pair.continuation))
            standbyTask = Self.run(
                provider: standby,
                utteranceID: token.sessionID,
                context: contexts[standby.id] ?? .personal(terms: []),
                stream: pair.stream,
                liveness: nil,
                timeline: timeline,
                eventHandler: eventHandler
            )
        } else {
            standbyTask = nil
        }
        let archivePair = Self.makeStream()
        built.append(StreamTarget(name: "audio-archive", isCritical: false, continuation: archivePair.continuation))
        archiveTask = Self.runArchive(sessionID: token.sessionID, stream: archivePair.stream)
        targets = built
    }

    func yield(_ chunk: PCM16Chunk) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let current = targets
        lock.unlock()
        timeline.mark(.firstAudioChunk)

        var dropped: [StreamTarget] = []
        for target in current {
            if case .dropped = target.continuation.yield(chunk) {
                if target.isCritical {
                    failPipelineOverflow()
                    return
                }
                dropped.append(target)
            }
        }
        guard !dropped.isEmpty else { return }
        lock.lock()
        targets.removeAll { candidate in dropped.contains { $0.name == candidate.name } }
        lock.unlock()
        for target in dropped {
            let error = ASRProviderError.unavailable("\(target.name) 处理速度跟不上录音，已停止该路；主转写继续")
            target.continuation.finish(throwing: error)
            eventHandler(.warning(providerID: target.name, message: error.localizedDescription))
        }
    }

    /// Closes every stream. Providers then finalize; the archive is sealed.
    func finishInput() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let current = targets
        targets.removeAll()
        lock.unlock()
        for target in current { target.continuation.finish() }
        timeline.mark(.inputClosed)
    }

    /// Same rules as macOS `AppModel.finish()`, both driven by
    /// `CloudSelectionPolicy`: the primary gets the preference window; one
    /// that already failed with billing/auth is passed over at once and the
    /// standby is taken (or waited for alone); otherwise an already-finished
    /// standby wins at the soft deadline and then the first usable final wins
    /// inside the shared eight-second cloud deadline measured from stop.
    func selectResult(cloudDeadlineNanoseconds: UInt64 = 8_000_000_000) async -> CloudSelection {
        let stop = DispatchTime.now().uptimeNanoseconds
        let cloudDeadline = stop &+ cloudDeadlineNanoseconds
        func remaining() -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            return cloudDeadline > now ? cloudDeadline - now : 1_000_000
        }
        func state(_ outcome: ProviderOutcome?) -> CloudCandidateState {
            guard let outcome else { return .pending }
            return outcome.isUsable ? .usable : .failed(outcome.failureKind)
        }

        let primarySilent = ProviderLivenessPolicy.isSilent(primaryLiveness.view())
        var primary = await observe(
            primaryTask,
            timeoutNanoseconds: max(1_000_000, CloudSelectionPolicy.preferenceWindowNanoseconds(primarySilent: primarySilent))
        )
        var standby: ProviderOutcome?
        if let standbyTask {
            standby = await observe(standbyTask, timeoutNanoseconds: 1_000_000)
        }
        func standbyState() -> CloudCandidateState? {
            standbyTask == nil ? nil : state(standby)
        }

        var decision = CloudSelectionPolicy.decide(
            primary: state(primary),
            standby: standbyState(),
            stage: .softDeadline,
            primarySilent: primarySilent
        )
        switch decision {
        case .waitForPrimary:
            primary = await resolve(primaryTask, provider: primaryProvider, timeoutNanoseconds: remaining())
            decision = CloudSelectionPolicy.decide(primary: state(primary), standby: standbyState(), stage: .softDeadline)
        case .waitForStandby, .waitForFirstUsable:
            if let standbyTask,
               let winner = await raceCloudFinals(standbyTask: standbyTask, timeoutNanoseconds: remaining()) {
                if winner.isPrimary { primary = winner.outcome } else { standby = winner.outcome }
                decision = CloudSelectionPolicy.decide(primary: state(primary), standby: standbyState(), stage: .race)
            } else {
                decision = .noUsableResult
            }
        case .takePrimary, .takeStandby, .noUsableResult:
            break
        }

        switch decision {
        case .takePrimary(let reason) where primary != nil:
            return CloudSelection(chosen: primary!, primary: primary!, standby: standby, reason: reason)
        case .takeStandby(let reason) where standby != nil:
            quarantinePrimary()
            return CloudSelection(
                chosen: standby!,
                primary: primary ?? quarantined("主云未在热备结果前完成"),
                standby: standby,
                reason: reason
            )
        default:
            let resolvedPrimary: ProviderOutcome
            if let primary {
                resolvedPrimary = primary
            } else {
                resolvedPrimary = await resolve(primaryTask, provider: primaryProvider, timeoutNanoseconds: 1_000_000)
            }
            var resolvedStandby = standby
            if resolvedStandby == nil, let standbyTask, let standbyProvider {
                resolvedStandby = await resolve(standbyTask, provider: standbyProvider, timeoutNanoseconds: 1_000_000)
            }
            return CloudSelection(
                chosen: resolvedPrimary,
                primary: resolvedPrimary,
                standby: resolvedStandby,
                reason: "all_providers_failed"
            )
        }
    }

    /// The standby's own final, for the history record only. Never on the
    /// user path.
    func resolveStandby(timeoutNanoseconds: UInt64) async -> ProviderOutcome? {
        guard let standbyTask, let standbyProvider else { return nil }
        return await resolve(standbyTask, provider: standbyProvider, timeoutNanoseconds: timeoutNanoseconds)
    }

    /// User cancel: stop listening and drop the providers, but seal and keep
    /// the audio so the dictation stays recoverable from history.
    func cancelKeepingAudio() async -> URL? {
        finishInput()
        primaryTask.cancel()
        standbyTask?.cancel()
        await primaryProvider.cancel()
        await standbyProvider?.cancel()
        return await archiveTask.value
    }

    func cancel() async {
        finishInput()
        primaryTask.cancel()
        standbyTask?.cancel()
        archiveTask.cancel()
        await primaryProvider.cancel()
        await standbyProvider?.cancel()
    }

    private func quarantined(_ message: String) -> ProviderOutcome {
        .failure(
            providerID: primaryProviderID,
            model: primaryProvider.displayName,
            error: ASRProviderError.timeout(message),
            terminationReason: .quarantined
        )
    }

    private func quarantinePrimary() {
        primaryTask.cancel()
        let provider = primaryProvider
        Task { await provider.cancel() }
    }

    private func failPipelineOverflow() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let current = targets
        targets.removeAll()
        lock.unlock()
        let error = ASRProviderError.unavailable("音频处理速度跟不上录音，已停止本次口述以避免静默丢字")
        for target in current {
            // Keep the archive: the audio captured so far is still the truth.
            if target.name == "audio-archive" {
                target.continuation.finish()
            } else {
                target.continuation.finish(throwing: error)
            }
        }
        eventHandler(.failed(providerID: "audio-pipeline", message: error.localizedDescription))
    }

    private func raceCloudFinals(
        standbyTask: Task<ProviderOutcome, Never>,
        timeoutNanoseconds: UInt64
    ) async -> (outcome: ProviderOutcome, isPrimary: Bool)? {
        let primaryTask = self.primaryTask
        return await withCheckedContinuation { continuation in
            let gate = CloudRaceGate(continuation)
            Task { gate.report(await primaryTask.value, isPrimary: true) }
            Task { gate.report(await standbyTask.value, isPrimary: false) }
            Task {
                try? await Task.sleep(nanoseconds: max(1_000_000, timeoutNanoseconds))
                gate.timeout()
            }
        }
    }

    private func resolve(
        _ task: Task<ProviderOutcome, Never>,
        provider: any ASRProvider,
        timeoutNanoseconds: UInt64
    ) async -> ProviderOutcome {
        let providerID = provider.id
        let model = provider.displayName
        switch await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: timeoutNanoseconds,
            onTimeout: {
                task.cancel()
                await provider.cancel()
            }
        ) {
        case .completed(let outcome):
            return outcome
        case .timedOut:
            return .failure(
                providerID: providerID,
                model: model,
                error: ASRProviderError.timeout("\(providerID) 在录音结束后仍未完成发送和定稿，已停止该路转写"),
                terminationReason: .quarantined
            )
        }
    }

    private func observe(
        _ task: Task<ProviderOutcome, Never>,
        timeoutNanoseconds: UInt64
    ) async -> ProviderOutcome? {
        switch await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: max(1_000_000, timeoutNanoseconds),
            onTimeout: {}
        ) {
        case .completed(let outcome): return outcome
        case .timedOut: return nil
        }
    }

    private static func makeStream() -> (stream: PCMStream, continuation: PCMStream.Continuation) {
        var continuation: PCMStream.Continuation!
        let stream = PCMStream(bufferingPolicy: .bufferingNewest(1_024)) { continuation = $0 }
        return (stream, continuation)
    }

    private static func run(
        provider: any ASRProvider,
        utteranceID: UUID,
        context: ASRContext,
        stream: PCMStream,
        liveness: ProviderLivenessProbe?,
        timeline: SessionTimelineRecorder,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) -> Task<ProviderOutcome, Never> {
        let providerID = provider.id
        let model = provider.displayName
        liveness?.markStarted()
        return Task(priority: .userInitiated) {
            do {
                if let liveness, let reporting = provider as? any ProviderLivenessReporting {
                    await reporting.attachLiveness(liveness)
                }
                try await provider.startUtterance(id: utteranceID, context: context, eventHandler: eventHandler)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    try await provider.send(chunk)
                }
                try Task.checkCancellation()
                let result = try await provider.finalize()
                switch providerID {
                case MobileEnvironment.sonioxProviderID: timeline.mark(.sonioxFinal, providerID: providerID)
                case MobileEnvironment.aliyunProviderID: timeline.mark(.aliyunFinal, providerID: providerID)
                default: break
                }
                return .success(result)
            } catch is CancellationError {
                return .failure(providerID: providerID, model: model, error: CancellationError(), terminationReason: .cancelled)
            } catch {
                liveness?.markFinished(usable: false)
                await provider.cancel()
                return .failure(providerID: providerID, model: model, error: error)
            }
        }
    }

    /// Writes the session WAV (then FLAC) into `HistoryStore`'s audio folder.
    /// Audio is the source of truth: a failed transcription can be redone
    /// from history.
    private static func runArchive(sessionID: UUID, stream: PCMStream) -> Task<URL?, Never> {
        Task(priority: .utility) {
            let archive = SessionAudioArchive()
            do {
                let directory = try await HistoryStore.shared.audioDirectory()
                try await archive.start(sessionID: sessionID, preRoll: Data(), directory: directory)
                do {
                    for try await chunk in stream {
                        try await archive.append(chunk.data)
                    }
                } catch {
                    // Stream ended abnormally; keep what was written.
                }
                return await archive.finishAndCompress()
            } catch {
                await archive.cancel()
                return nil
            }
        }
    }
}

private final class CloudRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private var resolved = false
    private let continuation: CheckedContinuation<(outcome: ProviderOutcome, isPrimary: Bool)?, Never>

    init(_ continuation: CheckedContinuation<(outcome: ProviderOutcome, isPrimary: Bool)?, Never>) {
        self.continuation = continuation
    }

    func report(_ outcome: ProviderOutcome, isPrimary: Bool) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        if outcome.isUsable {
            resolved = true
            lock.unlock()
            continuation.resume(returning: (outcome: outcome, isPrimary: isPrimary))
            return
        }
        remaining -= 1
        guard remaining == 0 else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        continuation.resume(returning: nil)
    }

    func timeout() {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        lock.unlock()
        continuation.resume(returning: nil)
    }
}
