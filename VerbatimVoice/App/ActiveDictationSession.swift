import Foundation

struct ProviderRunOutcome: Sendable {
    let providerID: String
    let model: String
    let result: TranscriptResult?
    let errorMessage: String?
    let terminationReason: ProviderTerminationReason
    /// Why the provider failed; nil on success and on user cancellation.
    var failureKind: ProviderFailureKind? = nil

    static func success(_ result: TranscriptResult) -> ProviderRunOutcome {
        ProviderRunOutcome(
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
    ) -> ProviderRunOutcome {
        ProviderRunOutcome(
            providerID: providerID,
            model: model,
            result: nil,
            errorMessage: error.localizedDescription,
            terminationReason: terminationReason,
            failureKind: error is CancellationError ? nil : ProviderFailureKind.of(error)
        )
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

private final class ProviderRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private var resolved = false
    private let continuation: CheckedContinuation<(outcome: ProviderRunOutcome, isPrimary: Bool)?, Never>

    init(_ continuation: CheckedContinuation<(outcome: ProviderRunOutcome, isPrimary: Bool)?, Never>) {
        self.continuation = continuation
    }

    func report(_ outcome: ProviderRunOutcome, isPrimary: Bool) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        if Self.isUsable(outcome) {
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

    private static func isUsable(_ outcome: ProviderRunOutcome) -> Bool {
        guard let text = outcome.result?.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class ActiveDictationSession: @unchecked Sendable {
    let id: UUID
    let token: SessionGenerationToken
    let timeline: SessionTimelineRecorder
    let startedAt: Date
    let target: TargetSnapshot?
    let targetApplicationPID: pid_t?
    let targetBundleIdentifier: String?
    let targetApplicationName: String?
    let profile: AppProfile
    let preRollMilliseconds: Int
    let primaryProviderID: String
    let providerContextReceipts: [ProviderContextReceipt]
    /// Network path at the start of recording and the observer generation
    /// then (set by AppModel; a later generation means the path changed).
    var networkPath: NetworkPathSnapshot?
    var networkPathGeneration: UInt64?

    let primaryTask: Task<ProviderRunOutcome, Never>
    let comparisonTasks: [String: Task<ProviderRunOutcome, Never>]
    let appleTask: Task<ProviderRunOutcome, Never>?
    let archiveTask: Task<URL?, Never>?

    private let primaryProvider: any ASRProvider
    private let comparisonProviders: [any ASRProvider]
    private let appleProvider: (any ASRProvider)?
    private let primaryPreparationTask: Task<Void, Error>?
    /// One liveness probe per cloud provider, owned by this session.
    private let livenessProbes: [String: ProviderLivenessProbe]
    private let lock = NSLock()
    private typealias PCMStream = AsyncThrowingStream<PCM16Chunk, Error>
    private struct StreamTarget {
        let id: UUID
        let providerID: String
        let isCritical: Bool
        let continuation: PCMStream.Continuation
    }
    private var streamTargets: [StreamTarget]
    private let eventHandler: @Sendable (ASREvent) -> Void
    private var pendingBeforeActivation: [PCM16Chunk] = []
    private var fallbackPCM = Data()
    private let retainLocalFallbackAudio: Bool
    private var activated = false
    private var finished = false

    init(
        token: SessionGenerationToken,
        timeline: SessionTimelineRecorder,
        startedAt: Date = Date(),
        target: TargetSnapshot?,
        targetApplicationPID: pid_t?,
        targetBundleIdentifier: String?,
        targetApplicationName: String?,
        profile: AppProfile,
        contextsByProviderID: [String: ASRContext],
        providerContextReceipts: [ProviderContextReceipt],
        preRollMilliseconds: Int,
        primaryProvider: any ASRProvider,
        primaryPreparationTask: Task<Void, Error>?,
        comparisonProviders: [any ASRProvider],
        appleProvider: (any ASRProvider)?,
        saveAudio: Bool,
        retainLocalFallbackAudio: Bool,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) {
        id = token.sessionID
        self.token = token
        self.timeline = timeline
        self.startedAt = startedAt
        self.target = target
        self.targetApplicationPID = targetApplicationPID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetApplicationName = targetApplicationName
        self.profile = profile
        self.preRollMilliseconds = preRollMilliseconds
        primaryProviderID = primaryProvider.id
        self.providerContextReceipts = providerContextReceipts
        self.primaryProvider = primaryProvider
        self.primaryPreparationTask = primaryPreparationTask
        self.comparisonProviders = comparisonProviders
        self.appleProvider = appleProvider
        self.eventHandler = eventHandler
        self.retainLocalFallbackAudio = retainLocalFallbackAudio
        var probes: [String: ProviderLivenessProbe] = [:]
        for provider in [primaryProvider] + comparisonProviders {
            probes[provider.id] = ProviderLivenessProbe()
        }
        livenessProbes = probes

        let primaryPair = Self.makeStream()
        var builtStreamTargets = [StreamTarget(
            id: UUID(),
            providerID: primaryProvider.id,
            isCritical: true,
            continuation: primaryPair.continuation
        )]
        primaryTask = Self.run(
            provider: primaryProvider,
            utteranceID: token.sessionID,
            context: contextsByProviderID[primaryProvider.id] ?? .personal(terms: []),
            stream: primaryPair.stream,
            preparationTask: primaryPreparationTask,
            liveness: probes[primaryProvider.id],
            timeline: timeline,
            eventHandler: eventHandler
        )

        var builtComparisonTasks: [String: Task<ProviderRunOutcome, Never>] = [:]
        for provider in comparisonProviders {
            let pair = Self.makeStream()
            builtStreamTargets.append(StreamTarget(
                id: UUID(),
                providerID: provider.id,
                isCritical: false,
                continuation: pair.continuation
            ))
            builtComparisonTasks[provider.id] = Self.run(
                provider: provider,
                utteranceID: token.sessionID,
                context: contextsByProviderID[provider.id] ?? .personal(terms: []),
                stream: pair.stream,
                preparationTask: nil,
                liveness: probes[provider.id],
                timeline: timeline,
                eventHandler: eventHandler
            )
        }
        comparisonTasks = builtComparisonTasks

        if let appleProvider {
            let applePair = Self.makeStream()
            builtStreamTargets.append(StreamTarget(
                id: UUID(),
                providerID: appleProvider.id,
                isCritical: false,
                continuation: applePair.continuation
            ))
            appleTask = Self.run(
                provider: appleProvider,
                utteranceID: token.sessionID,
                context: contextsByProviderID[appleProvider.id] ?? .personal(terms: []),
                stream: applePair.stream,
                preparationTask: nil,
                liveness: nil,
                timeline: timeline,
                eventHandler: eventHandler
            )
        } else {
            appleTask = nil
        }

        if saveAudio {
            let archivePair = Self.makeStream()
            builtStreamTargets.append(StreamTarget(
                id: UUID(),
                providerID: "audio-archive",
                isCritical: false,
                continuation: archivePair.continuation
            ))
            archiveTask = Self.runArchive(
                sessionID: token.sessionID,
                stream: archivePair.stream
            )
        } else {
            archiveTask = nil
        }

        streamTargets = builtStreamTargets
    }

    /// Establishes the exact boundary between the session startup buffer and
    /// live chunks. Chunks that arrived after the session was installed but
    /// are already represented by the pre-roll snapshot are discarded once;
    /// newer chunks are emitted immediately after the pre-roll.
    func activate(preRoll snapshot: WarmPreRollSnapshot) {
        lock.lock()
        guard !finished, !activated else {
            lock.unlock()
            return
        }

        let targets = streamTargets
        let liveAfterSnapshot = pendingBeforeActivation
            .filter { $0.sequence > snapshot.throughSequence }
            .sorted { $0.sequence < $1.sequence }
        pendingBeforeActivation.removeAll(keepingCapacity: false)

        var chunks: [PCM16Chunk] = []
        if !snapshot.data.isEmpty {
            let chunk = PCM16Chunk(
                sequence: snapshot.throughSequence,
                data: snapshot.data,
                capturedAt: startedAt,
                sampleRate: 16_000,
                channels: 1
            )
            chunks.append(chunk)
        }
        chunks.append(contentsOf: liveAfterSnapshot)
        if retainLocalFallbackAudio {
            for chunk in chunks { fallbackPCM.append(chunk.data) }
        }
        activated = true
        lock.unlock()

        if !chunks.isEmpty { timeline.mark(.firstAudioChunk) }
        timeline.mark(.sessionActivated)
        emit(chunks, to: targets)
    }

    func yield(_ chunk: PCM16Chunk) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        guard activated else {
            pendingBeforeActivation.append(chunk)
            lock.unlock()
            return
        }
        if retainLocalFallbackAudio { fallbackPCM.append(chunk.data) }
        let targets = streamTargets
        lock.unlock()

        timeline.mark(.firstAudioChunk)
        emit([chunk], to: targets)
    }

    func finishInput() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pendingBeforeActivation.removeAll(keepingCapacity: false)
        let targets = streamTargets
        streamTargets.removeAll()
        lock.unlock()

        for target in targets {
            target.continuation.finish()
        }
        timeline.mark(.inputClosed)
    }

    func observePrimary(timeoutNanoseconds: UInt64) async -> ProviderRunOutcome? {
        await observe(task: primaryTask, timeoutNanoseconds: timeoutNanoseconds)
    }

    func observeComparison(
        providerID: String,
        timeoutNanoseconds: UInt64
    ) async -> ProviderRunOutcome? {
        guard let task = comparisonTasks[providerID] else { return nil }
        return await observe(task: task, timeoutNanoseconds: timeoutNanoseconds)
    }

    /// After the primary's soft preference window, select the first usable
    /// cloud final. A failed result does not end the race while the other
    /// provider can still complete inside the shared cloud deadline.
    func raceCloudFinals(
        standbyProviderID: String,
        timeoutNanoseconds: UInt64
    ) async -> (outcome: ProviderRunOutcome, isPrimary: Bool)? {
        guard let standbyTask = comparisonTasks[standbyProviderID] else { return nil }
        let primaryTask = self.primaryTask
        return await withCheckedContinuation { continuation in
            let gate = ProviderRaceGate(continuation)
            Task {
                gate.report(await primaryTask.value, isPrimary: true)
            }
            Task {
                gate.report(await standbyTask.value, isPrimary: false)
            }
            Task {
                try? await Task.sleep(nanoseconds: max(1_000_000, timeoutNanoseconds))
                gate.timeout()
            }
        }
    }

    /// Resolves a provider task after the microphone has stopped, with a hard
    /// end-to-end deadline that also covers audio still queued in `send(_:)`.
    /// Provider-specific `finalize()` timeouts are not enough: a stalled
    /// WebSocket send can otherwise prevent finalization from ever starting.
    func resolvePrimary(timeoutNanoseconds: UInt64) async -> ProviderRunOutcome {
        await resolve(
            task: primaryTask,
            provider: primaryProvider,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func resolveComparison(
        providerID: String,
        timeoutNanoseconds: UInt64
    ) async -> ProviderRunOutcome? {
        guard let task = comparisonTasks[providerID],
              let provider = comparisonProviders.first(where: { $0.id == providerID }) else {
            return nil
        }
        return await resolve(
            task: task,
            provider: provider,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func cancel() async {
        finishInput()
        primaryTask.cancel()
        primaryPreparationTask?.cancel()
        for task in comparisonTasks.values { task.cancel() }
        appleTask?.cancel()
        archiveTask?.cancel()
        await primaryProvider.cancel()
        for provider in comparisonProviders {
            await provider.cancel()
        }
        if let appleProvider {
            await appleProvider.cancel()
        }
    }

    /// Stops transcription work without touching the archive stream/task.
    /// A user cancellation is a retained draft, not a destructive operation.
    func cancelTranscriptionPreservingArchive() async {
        finishInput()
        primaryTask.cancel()
        primaryPreparationTask?.cancel()
        for task in comparisonTasks.values { task.cancel() }
        appleTask?.cancel()
        await primaryProvider.cancel()
        for provider in comparisonProviders {
            await provider.cancel()
        }
        if let appleProvider {
            await appleProvider.cancel()
        }
    }

    /// Removes a timed-out provider from the user path immediately. Cleanup is
    /// intentionally unstructured and the instance is session-owned, so a
    /// wedged actor cannot delay or contaminate the next dictation.
    func quarantinePrimary() {
        primaryTask.cancel()
        let provider = primaryProvider
        Task { await provider.cancel() }
    }

    /// Stops the standby cloud run, e.g. after the local engine won the race.
    func quarantineComparison(providerID: String) {
        comparisonTasks[providerID]?.cancel()
        guard let provider = comparisonProviders.first(where: { $0.id == providerID }) else { return }
        Task { await provider.cancel() }
    }

    /// The cloud provider instance this session runs (for the warm pool).
    func cloudProvider(id providerID: String) -> (any ASRProvider)? {
        if primaryProvider.id == providerID { return primaryProvider }
        return comparisonProviders.first { $0.id == providerID }
    }

    func providerTask(id providerID: String) -> Task<ProviderRunOutcome, Never>? {
        primaryProviderID == providerID ? primaryTask : comparisonTasks[providerID]
    }

    /// What the server side of one cloud provider has done so far.
    func livenessView(providerID: String) -> ProviderLivenessView? {
        livenessProbes[providerID]?.view()
    }

    /// History form, offsets from the session timeline origin.
    func livenessRecord(providerID: String) -> ProviderLivenessRecord? {
        livenessProbes[providerID]?.record(origin: timeline.originInstant)
    }

    /// Starts the local engine on the retained PCM without waiting for it.
    /// The returned run can be cancelled when a cloud result wins the race.
    func startLocalFallback(
        context: ASRContext,
        timeoutNanoseconds: UInt64
    ) -> LocalFallbackRun {
        let pcm = snapshotFallbackPCM()
        let timeoutNanoseconds = max(
            timeoutNanoseconds,
            LocalFallbackPolicy.minimumBudgetNanoseconds(pcmByteCount: pcm.count)
        )

        let provider = LocalSenseVoiceProvider()
        let providerID = provider.id
        let model = provider.displayName
        guard pcm.count >= 640 else {
            return LocalFallbackRun(
                task: Task {
                    .failure(
                        providerID: providerID,
                        model: model,
                        error: ASRProviderError.unavailable("没有完整的本地兜底音频")
                    )
                },
                provider: nil
            )
        }
        timeline.mark(.localFallbackStarted, providerID: providerID)

        let work = Task<ProviderRunOutcome, Never>(priority: .userInitiated) {
            do {
                try await provider.startUtterance(
                    id: self.id,
                    context: context,
                    eventHandler: self.eventHandler
                )
                var sequence: Int64 = 0
                for offset in stride(from: 0, to: pcm.count, by: 3_840) {
                    try Task.checkCancellation()
                    sequence += 1
                    let end = min(offset + 3_840, pcm.count)
                    try await provider.send(PCM16Chunk(
                        sequence: sequence,
                        data: pcm.subdata(in: offset..<end),
                        capturedAt: self.startedAt,
                        sampleRate: 16_000,
                        channels: 1
                    ))
                }
                try Task.checkCancellation()
                let result = try await provider.finalize()
                self.timeline.mark(.localFinal, providerID: providerID)
                return .success(result)
            } catch is CancellationError {
                return .failure(
                    providerID: providerID,
                    model: model,
                    error: CancellationError(),
                    terminationReason: .cancelled
                )
            } catch {
                return .failure(providerID: providerID, model: model, error: error)
            }
        }

        let bounded = Task<ProviderRunOutcome, Never>(priority: .userInitiated) {
            let deadline = await CompletionDeadline.wait(
                for: work,
                timeoutNanoseconds: timeoutNanoseconds,
                onTimeout: {
                    work.cancel()
                    await provider.cancel()
                }
            )
            switch deadline {
            case .completed(let outcome):
                return outcome
            case .timedOut:
                return .failure(
                    providerID: providerID,
                    model: model,
                    error: ASRProviderError.timeout("本地兜底超过 \(timeoutNanoseconds / 1_000_000_000) 秒上限"),
                    terminationReason: .quarantined
                )
            }
        }
        return LocalFallbackRun(task: bounded, work: work, provider: provider)
    }

    func runLocalFallback(
        context: ASRContext,
        timeoutNanoseconds: UInt64
    ) async -> ProviderRunOutcome {
        await startLocalFallback(context: context, timeoutNanoseconds: timeoutNanoseconds).task.value
    }

    private func snapshotFallbackPCM() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return fallbackPCM
    }

    private func resolve(
        task: Task<ProviderRunOutcome, Never>,
        provider: any ASRProvider,
        timeoutNanoseconds: UInt64
    ) async -> ProviderRunOutcome {
        let providerID = provider.id
        let modelFallback = provider.displayName
        let result = await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: timeoutNanoseconds,
            onTimeout: {
                // Cancelling the task alone is not guaranteed to wake
                // URLSessionWebSocketTask.send. Closing the provider socket
                // makes a blocked send return and leaves the next utterance
                // on a clean connection.
                task.cancel()
                await provider.cancel()
            }
        )
        switch result {
        case .completed(let outcome):
            return outcome
        case .timedOut:
            return .failure(
                providerID: providerID,
                model: modelFallback,
                error: ASRProviderError.timeout(
                    "\(providerID) 在录音结束后仍未完成发送和定稿，已停止该路转写"
                ),
                terminationReason: .quarantined
            )
        }
    }

    private func observe(
        task: Task<ProviderRunOutcome, Never>,
        timeoutNanoseconds: UInt64
    ) async -> ProviderRunOutcome? {
        let result = await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: max(1_000_000, timeoutNanoseconds),
            onTimeout: {}
        )
        switch result {
        case .completed(let outcome): return outcome
        case .timedOut: return nil
        }
    }

    private static func makeStream() -> (
        stream: PCMStream,
        continuation: PCMStream.Continuation
    ) {
        var continuation: PCMStream.Continuation!
        let stream = PCMStream(bufferingPolicy: .bufferingNewest(1_024)) {
            continuation = $0
        }
        return (stream, continuation)
    }

    private static func run(
        provider: any ASRProvider,
        utteranceID: UUID,
        context: ASRContext,
        stream: PCMStream,
        preparationTask: Task<Void, Error>?,
        liveness: ProviderLivenessProbe?,
        timeline: SessionTimelineRecorder,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) -> Task<ProviderRunOutcome, Never> {
        let providerID = provider.id
        let modelFallback = provider.displayName
        liveness?.markStarted()
        let task = Task<ProviderRunOutcome, Never>(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try await preparationTask?.value
                try Task.checkCancellation()
                if let liveness, let reporting = provider as? any ProviderLivenessReporting {
                    await reporting.attachLiveness(liveness)
                }
                try await provider.startUtterance(
                    id: utteranceID,
                    context: context,
                    eventHandler: eventHandler
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    try await provider.send(chunk)
                }
                try Task.checkCancellation()
                let result = try await provider.finalize()
                switch providerID {
                case "soniox": timeline.mark(.sonioxFinal, providerID: providerID)
                case "aliyun-qwen-audio-asr": timeline.mark(.aliyunFinal, providerID: providerID)
                case "local-sensevoice": timeline.mark(.localFinal, providerID: providerID)
                default: break
                }
                return .success(result)
            } catch is CancellationError {
                return .failure(
                    providerID: providerID,
                    model: modelFallback,
                    error: CancellationError(),
                    terminationReason: .cancelled
                )
            } catch {
                await provider.cancel()
                return .failure(providerID: providerID, model: modelFallback, error: error)
            }
        }
        guard let liveness else { return task }
        // Record the end of the run for "dead at stop" decisions.
        return Task(priority: .userInitiated) {
            // Cancelling this wrapper must still cancel the provider run.
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            let usable = outcome.result.map {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            liveness.markFinished(usable: usable)
            return outcome
        }
    }

    private static func runArchive(
        sessionID: UUID,
        stream: PCMStream
    ) -> Task<URL?, Never> {
        Task(priority: .utility) {
            let archive = SessionAudioArchive()
            do {
                let directory = try await HistoryStore.shared.audioDirectory()
                try await archive.start(sessionID: sessionID, preRoll: Data(), directory: directory)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    try await archive.append(chunk.data)
                }
                return await archive.finishAndCompress()
            } catch {
                await archive.cancel()
                return nil
            }
        }
    }

    private func emit(_ chunks: [PCM16Chunk], to targets: [StreamTarget]) {
        var droppedNoncritical: Set<UUID> = []
        var primaryOverflowed = false

        chunkLoop: for chunk in chunks {
            for target in targets where !droppedNoncritical.contains(target.id) {
                if case .dropped = target.continuation.yield(chunk) {
                    if target.isCritical {
                        primaryOverflowed = true
                        break chunkLoop
                    }
                    droppedNoncritical.insert(target.id)
                }
            }
        }

        if primaryOverflowed {
            failAudioPipelineOverflow()
            return
        }

        guard !droppedNoncritical.isEmpty else { return }
        lock.lock()
        let droppedTargets = streamTargets.filter { droppedNoncritical.contains($0.id) }
        streamTargets.removeAll { droppedNoncritical.contains($0.id) }
        lock.unlock()

        for target in droppedTargets {
            let error = ASRProviderError.unavailable(
                "后台 \(target.providerID) 处理速度跟不上录音，已停止该路对比；主转写继续"
            )
            target.continuation.finish(throwing: error)
            eventHandler(.warning(providerID: target.providerID, message: error.localizedDescription))
        }
    }

    private func failAudioPipelineOverflow() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pendingBeforeActivation.removeAll(keepingCapacity: false)
        let targets = streamTargets
        streamTargets.removeAll()
        lock.unlock()

        let error = ASRProviderError.unavailable("音频处理速度跟不上录音，已停止本次口述以避免静默丢字")
        for target in targets {
            target.continuation.finish(throwing: error)
        }
        eventHandler(.failed(providerID: "audio-pipeline", message: error.localizedDescription))
    }
}

/// A local SenseVoice run racing the cloud. `cancel()` terminates the
/// SenseVoice process so a cloud win does not leave it burning CPU into the
/// next dictation.
final class LocalFallbackRun: @unchecked Sendable {
    let task: Task<ProviderRunOutcome, Never>
    private let work: Task<ProviderRunOutcome, Never>?
    private let provider: LocalSenseVoiceProvider?

    init(
        task: Task<ProviderRunOutcome, Never>,
        work: Task<ProviderRunOutcome, Never>? = nil,
        provider: LocalSenseVoiceProvider?
    ) {
        self.task = task
        self.work = work
        self.provider = provider
    }

    func cancel() {
        work?.cancel()
        task.cancel()
        if let provider {
            Task { await provider.cancel() }
        }
    }
}

final class ActiveSessionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ActiveDictationSession?
    private var pending = SequencedCaptureBuffer<PCM16Chunk>()

    /// Starts retaining live chunks before on-demand audio startup, target
    /// discovery, or provider setup can complete. The startup ring covers
    /// audio up to the boundary snapshot; this queue covers everything after.
    func beginPendingCapture() {
        lock.lock()
        session = nil
        pending.begin()
        lock.unlock()
    }

    /// Stops accepting new chunks while preserving those already captured.
    /// Used when Option is released before slow target discovery completes.
    func endPendingCapture() {
        lock.lock()
        pending.end()
        lock.unlock()
    }

    /// Atomically installs the real session and drains only chunks newer than
    /// the ring-buffer snapshot.  Filtering by sequence makes the hand-off
    /// lossless without duplicating the tail already present in pre-roll.
    @discardableResult
    func install(_ session: ActiveDictationSession, afterSequence sequence: Int64) -> Int {
        lock.lock()
        self.session = session
        let buffered = pending.drain(after: sequence)
        lock.unlock()

        for chunk in buffered {
            session.yield(chunk)
        }
        return buffered.count
    }

    func cancelPendingCapture() {
        lock.lock()
        pending.cancel()
        lock.unlock()
    }

    func drainPending(afterSequence sequence: Int64) -> [PCM16Chunk] {
        lock.lock()
        pending.end()
        let buffered = pending.drain(after: sequence)
        lock.unlock()
        return buffered
    }

    func clear(_ expected: ActiveDictationSession? = nil) {
        lock.lock()
        if let expected {
            if session === expected { session = nil }
        } else {
            session = nil
        }
        pending.cancel()
        lock.unlock()
    }

    func yield(_ chunk: PCM16Chunk) {
        lock.lock()
        let current = session
        if current == nil {
            pending.append(chunk, sequence: chunk.sequence)
        }
        lock.unlock()
        current?.yield(chunk)
    }
}
