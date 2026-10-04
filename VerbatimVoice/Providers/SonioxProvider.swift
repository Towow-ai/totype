import Foundation
import os

actor SonioxProvider: ASRProvider, ProviderLivenessReporting {
    nonisolated let id = "soniox"
    nonisolated let displayName = String(localized: "Soniox stt-rt-v5（云端）")

    private enum State {
        case disconnected
        case connecting
        case ready
        case active
        case finalizing
        case warmIdle
    }

    private struct Response: Decodable {
        let tokens: [Token]?
        let finished: Bool?
        let errorCode: Int?
        let errorType: String?
        let errorMessage: String?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case tokens, finished
            case errorCode = "error_code"
            case errorType = "error_type"
            case errorMessage = "error_message"
            case requestID = "request_id"
        }
    }

    private struct ServerResponseError: ClassifiedProviderError {
        let type: String
        let code: Int?
        let message: String
        let requestID: String?

        /// Billing/auth (e.g. `organization_balance_exhausted`) are never
        /// retried and take Soniox out of the user path; see
        /// `ProviderFailureClassifier`.
        var failureKind: ProviderFailureKind {
            ProviderFailureClassifier.soniox(errorType: type, errorCode: code)
        }

        var errorDescription: String? {
            let request = requestID.map { " request_id=\($0)" } ?? ""
            return String(localized: "服务端错误：\(type): \(message)\(request)")
        }

        var isRetryable: Bool {
            SonioxRecoveryPolicy.isRetryableServerError(type)
        }
    }

    private struct Token: Decodable {
        let text: String
        let startMilliseconds: Int?
        let endMilliseconds: Int?
        let confidence: Double?
        let isFinal: Bool
        let language: String?

        enum CodingKeys: String, CodingKey {
            case text, confidence, language
            case startMilliseconds = "start_ms"
            case endMilliseconds = "end_ms"
            case isFinal = "is_final"
        }
    }

    private let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private let model = "stt-rt-v5"
    // The app already records 120 ms after the stop press. Soniox recommends
    // approximately 200 ms of silence before manual finalization, so append
    // the remaining 80 ms as PCM silence to protect the last spoken syllable.
    private let manualFinalizePadding = Data(repeating: 0, count: 2_560)
    private let apiKeyProvider: @Sendable () throws -> String
    private let warmTTLProvider: @Sendable () async -> TimeInterval

    /// One long-lived session for every Soniox socket so TLS sessions and DNS
    /// answers are reused (a fresh ephemeral session per connection made every
    /// handshake a full one). Sockets are cancelled individually; the shared
    /// session is never invalidated. `waitsForConnectivity` stays on: a press
    /// right after wake or during a Wi-Fi roam waits for the route (bounded
    /// by the hedged five-second deadline) instead of failing at once and
    /// losing the cloud for the whole recording. A route that never returns
    /// is caught by the liveness rule (unconnected for 3 s = dead at stop).
    /// Warm-socket lifecycle (reuse hits and every close reason), so the real
    /// reuse rate and whether Soniox answers WebSocket pings can be checked
    /// with `log show --predicate 'category == "soniox-warm"'`.
    private static let warmLogger = Logger(
        subsystem: AppIdentity.bundleID,
        category: "soniox-warm"
    )

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private var state: State = .disconnected
    private var socket: URLSessionWebSocketTask?
    private var connectionEstablishedAt: ContinuousClock.Instant?
    /// Session-owned probe for the current utterance (see `attachLiveness`).
    private var liveness: ProviderLivenessProbe?
    /// macOS warm pool: only the newest session lease may drive this actor.
    private var activeLease: UUID?
    private var reusedConnection: Bool?
    private var hedgedConnection: Bool?
    private var connectionAttemptCount: Int?
    /// Per-socket facts, kept so a socket opened by `prepare` (preconnect at
    /// the key press) is reported as a fresh handshake, not as reuse.
    private var socketUtteranceCount = 0
    private var socketSetupLatencyMilliseconds: Int?
    private var socketHedged: Bool?
    private var socketAttemptCount: Int?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var warmCloseTask: Task<Void, Never>?
    private var finalizeTimeoutTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0

    private var preparedContext: ASRContext?
    private var connectedContextSignature: String?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var utteranceID: UUID?
    private var utteranceStartedAt: Date?
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var finalTokens: [ASRToken] = []
    private var seenFinalTokens: Set<String> = []
    private var provisionalText = ""
    private var queuedAudio: [Data] = []
    private var replayAudio = Data()
    private var replayAudioTruncated = false
    private var recoveryAttemptCount = 0
    private var connectionSetupLatencyMilliseconds: Int?
    private var degradedTransportError: Error?
    // Soniox's official PCM example sends 3,840 bytes every 120 ms at
    // 16 kHz mono. The audio tap produces roughly 342 bytes every 10.7 ms;
    // sending every tap as its own WebSocket message creates thousands of
    // awaits and can leave minutes of client-side backlog after a long take.
    private var audioBatcher = PCMFrameBatcher(targetFrameBytes: 3_840)
    private var audioBytesSent = 0
    private var audioFrameCount = 0
    private var maxSendLatencyMilliseconds = 0
    private var backpressureEventCount = 0
    private var finalizeContinuation: CheckedContinuation<TranscriptResult, Error>?
    private var terminalError: Error?

    init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        warmTTLProvider: @escaping @Sendable () async -> TimeInterval
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.warmTTLProvider = warmTTLProvider
    }

    func prepare(context: ASRContext) async throws {
        preparedContext = context
        _ = try apiKeyProvider()
        guard finalizeContinuation == nil, utteranceID == nil else { return }

        terminalError = nil
        let signature = Self.contextSignature(context)
        if socket != nil, connectedContextSignature != signature || !isReusableWarmSocket {
            Self.warmLogger.notice("close warm socket: \(self.connectedContextSignature != signature ? "signature-mismatch" : "not-reusable", privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            await closeConnection()
        }
        if socket == nil {
            try await connect(context: context)
        }
        state = .warmIdle
        await scheduleWarmIdle()
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        guard finalizeContinuation == nil else {
            throw ASRProviderError.invalidState(String(localized: "上一段仍在等待 finalization"))
        }

        self.eventHandler = eventHandler
        utteranceID = id
        utteranceStartedAt = Date()
        firstPartialAt = nil
        finalizeRequestedAt = nil
        finalTokens.removeAll(keepingCapacity: true)
        seenFinalTokens.removeAll(keepingCapacity: true)
        provisionalText = ""
        queuedAudio.removeAll(keepingCapacity: true)
        replayAudio.removeAll(keepingCapacity: true)
        replayAudioTruncated = false
        recoveryAttemptCount = 0
        connectionSetupLatencyMilliseconds = nil
        degradedTransportError = nil
        resetTransportState()
        terminalError = nil
        cancelWarmTimers()
        reusedConnection = nil
        hedgedConnection = nil
        connectionAttemptCount = nil

        let signature = Self.contextSignature(context)
        if socket != nil, connectedContextSignature != signature || !isReusableWarmSocket {
            Self.warmLogger.notice("close warm socket: \(self.connectedContextSignature != signature ? "signature-mismatch" : "not-reusable", privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            await closeConnection()
        }

        if socket == nil {
            reusedConnection = false
            preparedContext = context
            do {
                try await connect(context: context)
            } catch {
                guard isRetryable(error), recoveryAttemptCount < SonioxRecoveryPolicy.maximumRecoveryAttempts else {
                    throw error
                }
                recoveryAttemptCount += 1
                try await Task.sleep(nanoseconds: SonioxRecoveryPolicy.recoveryBackoffNanoseconds)
                try await connect(context: context)
            }
            socketUtteranceCount = 1
        } else if socketUtteranceCount == 0 {
            // Opened by this press's preconnect: a real handshake, just
            // started earlier. Report it as such, not as reuse.
            state = .active
            socketUtteranceCount = 1
            reusedConnection = false
            connectionSetupLatencyMilliseconds = socketSetupLatencyMilliseconds
            hedgedConnection = socketHedged
            connectionAttemptCount = socketAttemptCount
            liveness?.markConnected(reused: false, hedged: socketHedged)
            eventHandler(.connected(providerID: self.id))
        } else {
            // A socket kept from an earlier dictation whose last request
            // ended with `<fin>`. Soniox keeps
            // the stream open after manual finalization; more audio continues
            // the same stream under the same configuration.
            state = .active
            socketUtteranceCount += 1
            reusedConnection = true
            Self.warmLogger.notice("reuse warm socket: utterance #\(self.socketUtteranceCount, privacy: .public) on this socket")
            liveness?.markConnected(reused: true)
            eventHandler(.connected(providerID: self.id))
        }
    }

    /// Only an idle socket whose previous request finished cleanly, young
    /// enough to stay well inside Soniox's 300-minute stream limit.
    private var isReusableWarmSocket: Bool {
        guard state == .warmIdle, let established = connectionEstablishedAt else { return false }
        let age = ProviderLivenessProbe.nanoseconds(established.duration(to: .now))
        return age < SonioxRecoveryPolicy.warmConnectionMaximumAgeNanoseconds
    }

    func send(_ chunk: PCM16Chunk) async throws {
        if let terminalError { throw terminalError }
        guard utteranceID != nil else { return }
        guard !chunk.data.isEmpty else { return }

        retainForRecovery(chunk.data)
        if degradedTransportError != nil { return }

        guard let socket else {
            degradedTransportError = ASRProviderError.connectionFailed(String(localized: "Soniox WebSocket 已断开；结束录音时将重建并回放"))
            liveness?.markFailed()
            return
        }
        do {
            for frame in audioBatcher.append(chunk.data) {
                try await sendAudioFrame(frame, over: socket)
            }
        } catch {
            // A rejection the server sent while audio was flowing (balance,
            // key) ends the request; replaying the audio cannot fix it.
            if let classified = error as? ClassifiedProviderError, !classified.failureKind.isRetryable {
                throw error
            }
            if let terminal = terminalError as? ClassifiedProviderError, !terminal.failureKind.isRetryable {
                throw terminal
            }
            degradedTransportError = ASRProviderError.connectionFailed(error.localizedDescription)
            liveness?.markFailed()
            eventHandler?(.warning(providerID: id, message: String(localized: "Soniox 实时连接中断；已保留完整音频，结束时自动恢复一次")))
            invalidateCurrentConnection()
        }
    }

    func finalize() async throws -> TranscriptResult {
        guard utteranceStartedAt != nil else {
            throw ASRProviderError.invalidState(String(localized: "没有活动口述"))
        }
        guard finalizeContinuation == nil else {
            throw ASRProviderError.invalidState(String(localized: "已经请求 finalization"))
        }

        if let degradedTransportError {
            return try await recoverAndFinalize(after: degradedTransportError)
        }

        do {
            return try await finalizeCurrentConnection()
        } catch {
            guard isRetryable(error) else { throw error }
            return try await recoverAndFinalize(after: error)
        }
    }

    /// Install the continuation before emitting the finalize control frame.
    /// Soniox can answer with `<fin>` immediately; the old send-then-install
    /// order could drop that completion and manufacture a four-second hang.
    private func finalizeCurrentConnection() async throws -> TranscriptResult {
        if let terminalError { throw terminalError }
        guard let socket else {
            throw ASRProviderError.invalidState(String(localized: "WebSocket 尚未连接"))
        }
        guard utteranceStartedAt != nil else {
            throw ASRProviderError.invalidState(String(localized: "没有活动口述"))
        }
        guard finalizeContinuation == nil else {
            throw ASRProviderError.invalidState(String(localized: "已经请求 finalization"))
        }

        state = .finalizing
        finalizeRequestedAt = Date()
        let generation = connectionGeneration
        return try await withCheckedThrowingContinuation { continuation in
            finalizeContinuation = continuation
            finalizeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.finalizationTimedOut()
            }
            Task { [weak self] in
                await self?.sendFinalizationRequest(
                    over: socket,
                    generation: generation
                )
            }
        }
    }

    private func sendFinalizationRequest(
        over socket: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        do {
            for frame in audioBatcher.append(manualFinalizePadding) {
                try await sendAudioFrame(frame, over: socket)
            }
            if let tail = audioBatcher.flush() {
                try await sendAudioFrame(tail, over: socket)
            }
            try await sendMessage(
                .string("{\"type\":\"finalize\"}"),
                over: socket,
                generation: generation,
                timeoutNanoseconds: SonioxRecoveryPolicy.finalizeSendDeadlineNanoseconds,
                stage: "finalize"
            )
        } catch {
            // A bounded recovery may still make this request succeed. Do not
            // publish a terminal provider failure before finalize() has had
            // the chance to rebuild the socket and replay the full utterance.
            failActiveRequest(error, notify: !isRetryable(error))
        }
    }

    private func recoverAndFinalize(after error: Error) async throws -> TranscriptResult {
        guard recoveryAttemptCount < SonioxRecoveryPolicy.maximumRecoveryAttempts else {
            throw error
        }
        guard !replayAudioTruncated, !replayAudio.isEmpty else {
            throw ASRProviderError.connectionFailed(
                String(localized: "Soniox 无法安全重试：完整会话音频不可用；原错误：\(error.localizedDescription)")
            )
        }
        guard let context = preparedContext else {
            throw ASRProviderError.invalidState(String(localized: "Soniox 重试缺少会话上下文"))
        }

        recoveryAttemptCount += 1
        eventHandler?(.warning(
            providerID: id,
            message: String(localized: "Soniox 出现可恢复故障，正在用完整音频建立一次新请求")
        ))
        invalidateCurrentConnection()
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        finalizeContinuation = nil
        finalTokens.removeAll(keepingCapacity: true)
        seenFinalTokens.removeAll(keepingCapacity: true)
        provisionalText = ""
        firstPartialAt = nil
        finalizeRequestedAt = nil
        terminalError = nil
        degradedTransportError = nil
        audioBatcher.reset()

        try await Task.sleep(nanoseconds: SonioxRecoveryPolicy.recoveryBackoffNanoseconds)
        try await connect(context: context)
        guard let socket else {
            throw ASRProviderError.connectionFailed(String(localized: "Soniox 重试连接未建立"))
        }

        for offset in stride(from: 0, to: replayAudio.count, by: 3_840) {
            try Task.checkCancellation()
            let end = min(offset + 3_840, replayAudio.count)
            try await sendAudioFrame(replayAudio.subdata(in: offset..<end), over: socket)
            if end < replayAudio.count {
                try await Task.sleep(nanoseconds: SonioxRecoveryPolicy.replayPacingNanoseconds)
            }
        }
        state = .active
        return try await finalizeCurrentConnection()
    }

    func cancel() async {
        let connectionContainsUnfinalizedAudio = utteranceID != nil || state == .active || state == .finalizing
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        if let continuation = finalizeContinuation {
            finalizeContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        utteranceID = nil
        utteranceStartedAt = nil
        firstPartialAt = nil
        finalizeRequestedAt = nil
        eventHandler = nil
        liveness = nil
        finalTokens.removeAll()
        seenFinalTokens.removeAll()
        provisionalText = ""
        queuedAudio.removeAll()
        replayAudio.removeAll()
        replayAudioTruncated = false
        recoveryAttemptCount = 0
        connectionSetupLatencyMilliseconds = nil
        degradedTransportError = nil
        resetTransportState()
        terminalError = nil

        // A canceled or failed utterance cannot remain on a persistent Soniox
        // session: its unfinalized audio would leak into the next dictation.
        if connectionContainsUnfinalizedAudio {
            await closeConnection()
        } else {
            state = socket == nil ? .disconnected : .warmIdle
            await scheduleWarmIdle()
        }
    }

    private func connect(context: ASRContext) async throws {
        state = .connecting
        let key = try apiKeyProvider()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRProviderError.missingAPIKey("Soniox")
        }
        let config = try Self.configurationJSON(apiKey: key, model: model, context: context)

        // Reserve a generation for this attempt. A cancel/close while the
        // handshake runs bumps it, and the socket that wins is then dropped.
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let setupStarted = ContinuousClock.now
        let opened: SonioxOpenedSocket
        do {
            opened = try await Self.openConfiguredSocket(
                session: Self.sharedSession,
                endpoint: endpoint,
                configuration: config,
                hedgeAfterNanoseconds: SonioxRecoveryPolicy.connectionHedgeDelayNanoseconds,
                deadlineNanoseconds: SonioxRecoveryPolicy.configurationSendDeadlineNanoseconds
            )
        } catch {
            if connectionGeneration == generation { state = .disconnected }
            throw error
        }
        guard connectionGeneration == generation, socket == nil else {
            opened.socket.cancel(with: .goingAway, reason: nil)
            throw ASRProviderError.connectionFailed(String(localized: "Soniox 连接在配置期间失效"))
        }

        // The configuration is on the wire. Only now does this socket get a
        // receive loop: frames that arrived meanwhile (including a billing
        // rejection) stay buffered and are processed in order.
        let socket = opened.socket
        self.socket = socket
        connectionEstablishedAt = .now
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: generation)
        }
        Self.warmLogger.notice("new socket: hedged=\(opened.hedged, privacy: .public) attempts=\(opened.attempts, privacy: .public)")
        connectedContextSignature = Self.contextSignature(context)
        state = .active
        let elapsed = setupStarted.duration(to: .now).components
        connectionSetupLatencyMilliseconds = max(
            0,
            Int(elapsed.seconds * 1_000)
                + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        )
        hedgedConnection = opened.hedged
        connectionAttemptCount = opened.attempts
        socketUtteranceCount = 0
        socketSetupLatencyMilliseconds = connectionSetupLatencyMilliseconds
        socketHedged = opened.hedged
        socketAttemptCount = opened.attempts
        liveness?.markConnected(reused: false, hedged: opened.hedged)
        eventHandler?(.connected(providerID: id))
        do {
            try await flushQueuedAudio()
        } catch {
            invalidateConnection(generation: generation)
            if let terminalError, terminalError is ClassifiedProviderError { throw terminalError }
            throw ASRProviderError.connectionFailed(error.localizedDescription)
        }
    }

    /// Opens a socket and sends the configuration. If the first attempt has
    /// not finished after `hedgeAfterNanoseconds`, a second socket races it;
    /// the first to accept the configuration wins and the other is closed.
    /// A first attempt that fails before the hedge point fails at once (no
    /// route, refused) so the caller's single retry and the local race are
    /// not delayed. The whole call is bounded by `deadlineNanoseconds`.
    private nonisolated static func openConfiguredSocket(
        session: URLSession,
        endpoint: URL,
        configuration: String,
        hedgeAfterNanoseconds: UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SonioxOpenedSocket {
        let race = SonioxConnectRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SonioxOpenedSocket, Error>) in
                race.install(continuation)
                @Sendable func attempt() {
                    let socket = session.webSocketTask(with: endpoint)
                    guard let index = race.register(socket) else {
                        socket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    socket.resume()
                    Task {
                        do {
                            try await socket.send(.string(configuration))
                            race.succeed(socket, attempt: index)
                        } catch {
                            race.fail(ASRProviderError.connectionFailed(
                                String(localized: "Soniox 连接配置失败：\(error.localizedDescription)")
                            ))
                        }
                    }
                }
                attempt()
                Task {
                    try? await Task.sleep(nanoseconds: hedgeAfterNanoseconds)
                    if race.shouldHedge { attempt() }
                }
                Task {
                    try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                    race.fail(
                        ASRProviderError.timeout(String(localized: "Soniox 连接配置超过 \(Int(deadlineNanoseconds / 1_000_000), format: .number.grouping(.never)) ms")),
                        final: true
                    )
                }
            }
        } onCancel: {
            race.fail(CancellationError(), final: true)
        }
    }

    private func flushQueuedAudio() async throws {
        guard let socket else { return }
        let queued = queuedAudio
        queuedAudio.removeAll(keepingCapacity: true)
        for data in queued {
            for frame in audioBatcher.append(data) {
                try await sendAudioFrame(frame, over: socket)
            }
        }
    }

    private func sendAudioFrame(
        _ data: Data,
        over socket: URLSessionWebSocketTask
    ) async throws {
        let started = ContinuousClock.now
        let generation = connectionGeneration
        try await sendMessage(
            .data(data),
            over: socket,
            generation: generation,
            timeoutNanoseconds: SonioxRecoveryPolicy.audioSendDeadlineNanoseconds,
            stage: String(localized: "音频发送")
        )
        let elapsed = started.duration(to: .now)
        let components = elapsed.components
        let milliseconds = max(
            0,
            Int(components.seconds * 1_000)
                + Int(components.attoseconds / 1_000_000_000_000_000)
        )
        audioBytesSent += data.count
        audioFrameCount += 1
        maxSendLatencyMilliseconds = max(maxSendLatencyMilliseconds, milliseconds)
        if milliseconds >= 240 {
            backpressureEventCount += 1
        }
    }

    private func sendMessage(
        _ message: URLSessionWebSocketTask.Message,
        over socket: URLSessionWebSocketTask,
        generation: UInt64,
        timeoutNanoseconds: UInt64,
        stage: String
    ) async throws {
        guard connectionGeneration == generation, self.socket === socket else {
            throw ASRProviderError.connectionFailed(String(localized: "Soniox \(stage)使用了失效连接"))
        }
        let task = Task<Result<Void, Error>, Never> {
            do {
                try await socket.send(message)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        let deadline = await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: timeoutNanoseconds,
            onTimeout: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        )
        switch deadline {
        case .completed(.success):
            guard connectionGeneration == generation, self.socket === socket else {
                throw ASRProviderError.connectionFailed(String(localized: "Soniox \(stage)完成前连接已失效"))
            }
            if let terminalError { throw terminalError }
        case .completed(.failure(let error)):
            throw ASRProviderError.connectionFailed(String(localized: "Soniox \(stage)失败：\(error.localizedDescription)"))
        case .timedOut:
            throw ASRProviderError.timeout(String(localized: "Soniox \(stage)超过 \(Int(timeoutNanoseconds / 1_000_000), format: .number.grouping(.never)) ms"))
        }
    }

    private func resetTransportState() {
        audioBatcher.reset()
        audioBytesSent = 0
        audioFrameCount = 0
        maxSendLatencyMilliseconds = 0
        backpressureEventCount = 0
    }

    private func retainForRecovery(_ data: Data) {
        guard !replayAudioTruncated else { return }
        let remaining = SonioxRecoveryPolicy.maximumReplayBytes - replayAudio.count
        guard remaining > 0 else {
            replayAudioTruncated = true
            return
        }
        if data.count <= remaining {
            replayAudio.append(data)
        } else {
            replayAudio.append(data.prefix(remaining))
            replayAudioTruncated = true
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let server = error as? ServerResponseError {
            return server.isRetryable
        }
        if let classified = error as? ClassifiedProviderError {
            return classified.failureKind.isRetryable
        }
        if error is URLError { return true }
        if let provider = error as? ASRProviderError {
            switch provider {
            case .connectionFailed, .timeout:
                return true
            case .missingAPIKey, .notPrepared, .invalidState, .server, .unavailable:
                return false
            }
        }
        return false
    }

    private func receiveLoop(
        socket: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard generation == connectionGeneration, self.socket === socket else {
                    return
                }
                switch message {
                case .string(let text):
                    processResponseData(Data(text.utf8), generation: generation)
                case .data(let data):
                    processResponseData(data, generation: generation)
                @unknown default:
                    break
                }
            }
        } catch {
            guard generation == connectionGeneration, self.socket === socket else {
                return
            }
            if !Task.isCancelled, utteranceID == nil, state == .warmIdle {
                Self.warmLogger.notice("close warm socket: server-closed \(error.localizedDescription, privacy: .public)")
            }
            if !Task.isCancelled, utteranceID != nil {
                liveness?.markFailed()
                let failure = ASRProviderError.connectionFailed(error.localizedDescription)
                if state == .finalizing {
                    failActiveRequest(failure, notify: false)
                } else {
                    degradedTransportError = failure
                    eventHandler?(.warning(
                        providerID: id,
                        message: String(localized: "Soniox 连接提前关闭；完整音频已保留，结束时自动恢复一次")
                    ))
                }
            }
            invalidateConnection(generation: generation)
        }
    }

    private func processResponseData(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        liveness?.markServerMessage()
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(Response.self, from: data) else {
            eventHandler?(.warning(providerID: id, message: String(localized: "收到无法解析的 Soniox 响应")))
            return
        }

        if let errorType = response.errorType {
            let error = ServerResponseError(
                type: errorType,
                code: response.errorCode,
                message: response.errorMessage ?? "Unknown error",
                requestID: response.requestID
            )
            if error.isRetryable, state != .finalizing {
                degradedTransportError = error
                eventHandler?(.warning(
                    providerID: id,
                    message: String(localized: "Soniox 返回可恢复错误 \(errorType)；结束时自动重建请求")
                ))
            } else {
                failActiveRequest(error, notify: !error.isRetryable)
            }
            invalidateConnection(generation: generation)
            return
        }

        let tokens = response.tokens ?? []
        var currentNonFinal = ""
        var sawFinalMarker = false

        for token in tokens {
            if token.text == "<fin>" && token.isFinal {
                sawFinalMarker = true
                continue
            }

            let modelToken = ASRToken(
                text: token.text,
                startMilliseconds: token.startMilliseconds,
                endMilliseconds: token.endMilliseconds,
                confidence: token.confidence,
                isFinal: token.isFinal,
                language: token.language
            )

            if token.isFinal {
                let key = "\(token.startMilliseconds ?? -1)|\(token.endMilliseconds ?? -1)|\(token.text)|\(token.language ?? "")"
                if seenFinalTokens.insert(key).inserted {
                    finalTokens.append(modelToken)
                }
            } else {
                currentNonFinal += token.text
            }
        }

        provisionalText = currentNonFinal
        let combined = finalTokens.map(\.text).joined() + provisionalText
        if !combined.isEmpty {
            if firstPartialAt == nil { firstPartialAt = Date() }
            eventHandler?(.partial(providerID: id, text: combined))
        }

        if RealtimeCompletionPolicy.sonioxDidFinish(
            finishedFlag: response.finished,
            sawLegacyFinalMarker: sawFinalMarker
        ) {
            completeFinalization()
        }
    }

    private func completeFinalization() {
        guard let continuation = finalizeContinuation,
              let startedAt = utteranceStartedAt else { return }

        finalizeContinuation = nil
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        let finishedAt = Date()
        let text = finalTokens.map(\.text).joined()
        let firstLatency = firstPartialAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) }
        let finalizeLatency = finalizeRequestedAt.map { Int(finishedAt.timeIntervalSince($0) * 1_000) }

        let result = TranscriptResult(
            providerID: id,
            model: model,
            text: text,
            tokens: finalTokens,
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstPartialLatencyMilliseconds: firstLatency,
            finalizeLatencyMilliseconds: finalizeLatency,
            transportMetrics: ProviderTransportMetrics(
                audioBytesSent: audioBytesSent,
                audioFrameCount: audioFrameCount,
                maxSendLatencyMilliseconds: maxSendLatencyMilliseconds,
                backpressureEventCount: backpressureEventCount,
                recoveryAttemptCount: recoveryAttemptCount,
                connectionSetupLatencyMilliseconds: connectionSetupLatencyMilliseconds,
                reusedConnection: reusedConnection,
                hedgedConnection: hedgedConnection,
                connectionAttemptCount: connectionAttemptCount
            )
        )
        eventHandler?(.finalized(providerID: id, text: text))
        continuation.resume(returning: result)

        utteranceID = nil
        utteranceStartedAt = nil
        firstPartialAt = nil
        finalizeRequestedAt = nil
        eventHandler = nil
        liveness = nil
        replayAudio.removeAll(keepingCapacity: false)
        replayAudioTruncated = false
        degradedTransportError = nil
        state = .warmIdle
        Task { [weak self] in await self?.scheduleWarmIdle() }
    }

    private func finalizationTimedOut() {
        guard finalizeContinuation != nil else { return }
        failActiveRequest(
            ASRProviderError.timeout(String(localized: "Soniox 未在 4 秒内返回完成信号")),
            notify: false
        )
    }

    private func failActiveRequest(_ error: Error, notify: Bool = true) {
        terminalError = error
        liveness?.markFailed()
        if notify {
            eventHandler?(.failed(providerID: id, message: error.localizedDescription))
        }
        if let continuation = finalizeContinuation {
            finalizeContinuation = nil
            continuation.resume(throwing: error)
        }
        finalizeTimeoutTask?.cancel()
        finalizeTimeoutTask = nil
        // Keep the utterance identity, context, handler, and replay buffer
        // until finalize() decides whether this typed failure is retryable.
        // ActiveDictationSession calls cancel() after a terminal failure.
    }

    private func scheduleWarmIdle() async {
        cancelWarmTimers()
        guard socket != nil else { return }
        let ttl = await warmTTLProvider()
        guard ttl > 0 else {
            await closeConnection()
            return
        }
        guard socket != nil, state == .warmIdle, utteranceID == nil else { return }
        let generation = connectionGeneration

        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SonioxRecoveryPolicy.warmKeepaliveIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                // Soniox closes a stream that hears nothing for 20 s. The
                // WebSocket ping proves the path still answers; a socket that
                // misses its pong is dropped so the next press connects fresh
                // instead of discovering a half-open socket mid-dictation.
                guard await self.sendWarmKeepalive(generation: generation) else {
                    await self.closeIdleConnection(generation: generation, reason: "keepalive-or-pong-missed")
                    return
                }
            }
        }

        warmCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.closeIdleConnection(generation: generation, reason: "ttl")
        }
    }

    /// Returns false when the idle socket no longer answers.
    private func sendWarmKeepalive(generation: UInt64) async -> Bool {
        guard state == .warmIdle, utteranceID == nil,
              generation == connectionGeneration, let socket else { return true }
        let keepalive = Task<Bool, Never> {
            do {
                try await socket.send(.string("{\"type\":\"keepalive\"}"))
                return true
            } catch {
                return false
            }
        }
        async let answered = Self.ping(socket, deadlineNanoseconds: SonioxRecoveryPolicy.warmPongDeadlineNanoseconds)
        let sent: Bool
        switch await CompletionDeadline.wait(
            for: keepalive,
            timeoutNanoseconds: SonioxRecoveryPolicy.warmPongDeadlineNanoseconds,
            onTimeout: {}
        ) {
        case .completed(let value): sent = value
        case .timedOut: sent = false
        }
        let pong = await answered
        return sent && pong
    }

    private nonisolated static func ping(
        _ socket: URLSessionWebSocketTask,
        deadlineNanoseconds: UInt64
    ) async -> Bool {
        let task = Task<Bool, Never> {
            await withCheckedContinuation { continuation in
                socket.sendPing { error in continuation.resume(returning: error == nil) }
            }
        }
        switch await CompletionDeadline.wait(for: task, timeoutNanoseconds: deadlineNanoseconds, onTimeout: {}) {
        case .completed(let answered): return answered
        case .timedOut: return false
        }
    }

    /// TTL expiry and failed keepalives close only a still-idle socket of the
    /// same generation; a dictation that has just taken it is never touched.
    private func closeIdleConnection(generation: UInt64, reason: String) async {
        guard state == .warmIdle, utteranceID == nil, generation == connectionGeneration else { return }
        Self.warmLogger.notice("close warm socket: \(reason, privacy: .public)")
        await closeConnection()
    }

    /// The warm pool drops an instance it no longer needs.
    func closeIfIdle() async {
        guard utteranceID == nil, finalizeContinuation == nil else { return }
        if socket != nil { Self.warmLogger.notice("close warm socket: pool-drop") }
        await closeConnection()
    }

    private func cancelWarmTimers() {
        keepaliveTask?.cancel()
        warmCloseTask?.cancel()
        keepaliveTask = nil
        warmCloseTask = nil
    }

    private func closeConnection() async {
        invalidateCurrentConnection()
    }

    private func invalidateCurrentConnection() {
        invalidateConnection(generation: connectionGeneration)
    }

    private func invalidateConnection(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        cancelWarmTimers()
        connectionGeneration &+= 1
        let oldReceiveTask = receiveTask
        let oldSocket = socket
        receiveTask = nil
        socket = nil
        connectionEstablishedAt = nil
        connectedContextSignature = nil
        state = .disconnected
        oldReceiveTask?.cancel()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Liveness and session leases

    func attachLiveness(_ probe: ProviderLivenessProbe) async {
        liveness = probe
    }

    /// Lease entry points used by `LeasedSonioxProvider` (macOS warm pool).
    /// Any call that begins work claims the actor for the newest lease; a
    /// late `cancel`, `send` or `finalize` from an earlier session's handle is
    /// ignored or rejected, so it cannot reach a later dictation.
    func attachLiveness(_ probe: ProviderLivenessProbe, lease: UUID) async {
        activeLease = lease
        liveness = probe
    }

    func prepare(context: ASRContext, lease: UUID) async throws {
        activeLease = lease
        try await prepare(context: context)
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        lease: UUID,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        activeLease = lease
        try await startUtterance(id: id, context: context, eventHandler: eventHandler)
    }

    func send(_ chunk: PCM16Chunk, lease: UUID) async throws {
        guard activeLease == lease else {
            throw ASRProviderError.invalidState(String(localized: "Soniox 连接已交给新的口述"))
        }
        try await send(chunk)
    }

    func finalize(lease: UUID) async throws -> TranscriptResult {
        guard activeLease == lease else {
            throw ASRProviderError.invalidState(String(localized: "Soniox 连接已交给新的口述"))
        }
        return try await finalize()
    }

    func cancel(lease: UUID) async {
        guard activeLease == lease else { return }
        await cancel()
    }

    private static func contextSignature(_ context: ASRContext) -> String {
        let terms = context.terms.joined(separator: "\u{1F}")
        let general = context.general.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1E}")
        return context.languages.joined(separator: ",") + "|" + terms + "|" + general + "|" + context.speakerBackground + "|" + context.text
    }

    /// Soniox limits the whole context object to about 10,000 characters
    /// (8,000 tokens), not to 50 terms. The old fixed 50-term cut always
    /// dropped the tail of the built-in glossary (GitHub, ChatGPT, Sonnet,
    /// PRD, ...), which Soniox then misheard. Keep a count bound plus a
    /// character bound that leaves room for `general` and `text`.
    static let maximumContextTerms = 150
    static let maximumContextTermCharacters = 6_000

    static func boundedContextTerms(_ terms: [String]) -> [String] {
        var selected: [String] = []
        var characters = 0
        for term in terms.prefix(maximumContextTerms) {
            let cost = term.count + 3
            guard characters + cost <= maximumContextTermCharacters else { break }
            selected.append(term)
            characters += cost
        }
        return selected
    }

    private static func configurationJSON(apiKey: String, model: String, context: ASRContext) throws -> String {
        let general = context.general.sorted { $0.key < $1.key }.map { ["key": $0.key, "value": $0.value] }
        let object: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": context.languages,
            "language_hints_strict": false,
            "enable_language_identification": true,
            "enable_endpoint_detection": false,
            "context": [
                "general": general,
                // Soniox treats `context.text` as background about the audio,
                // not as an instruction; the speaker background goes first.
                "text": context.speakerBackground.isEmpty
                    ? context.text
                    : context.speakerBackground + "\n\n" + context.text,
                "terms": boundedContextTerms(context.terms)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ASRProviderError.invalidState(String(localized: "无法编码 Soniox 配置"))
        }
        return json
    }

    /// Decodes a server frame exactly as `processResponseData` does and
    /// returns the error it would end the request with (offline fixtures).
    static func serverErrorForTesting(_ data: Data) -> Error? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let errorType = response.errorType else { return nil }
        return ServerResponseError(
            type: errorType,
            code: response.errorCode,
            message: response.errorMessage ?? "Unknown error",
            requestID: response.requestID
        )
    }

    /// Offline harness entry: the hedged connect against a local server.
    static func openConfiguredSocketForTesting(
        endpoint: URL,
        configuration: String,
        hedgeAfterNanoseconds: UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SonioxOpenedSocket {
        try await openConfiguredSocket(
            session: sharedSession,
            endpoint: endpoint,
            configuration: configuration,
            hedgeAfterNanoseconds: hedgeAfterNanoseconds,
            deadlineNanoseconds: deadlineNanoseconds
        )
    }

    static func configurationJSONForTesting(context: ASRContext) throws -> String {
        try configurationJSON(apiKey: "test-key", model: "stt-rt-v5", context: context)
    }
}

struct SonioxOpenedSocket: @unchecked Sendable {
    let socket: URLSessionWebSocketTask
    /// The second (hedged) attempt won.
    let hedged: Bool
    /// Sockets opened for this connection (1 or 2).
    let attempts: Int
}

/// Resolution gate for `SonioxProvider.openConfiguredSocket`: exactly one
/// outcome; losing and late sockets are closed.
private final class SonioxConnectRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SonioxOpenedSocket, Error>?
    private var resolved = false
    private var sockets: [URLSessionWebSocketTask] = []
    private var failures = 0

    func install(_ continuation: CheckedContinuation<SonioxOpenedSocket, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns the 1-based attempt number, or nil once resolved.
    func register(_ socket: URLSessionWebSocketTask) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return nil }
        sockets.append(socket)
        return sockets.count
    }

    /// Only one hedge, and only while the first attempt is still running.
    var shouldHedge: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !resolved && sockets.count == 1 && failures == 0
    }

    func succeed(_ socket: URLSessionWebSocketTask, attempt: Int) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        resolved = true
        self.continuation = nil
        let losers = sockets.filter { $0 !== socket }
        let attempts = sockets.count
        lock.unlock()
        for loser in losers { loser.cancel(with: .goingAway, reason: nil) }
        continuation.resume(returning: SonioxOpenedSocket(socket: socket, hedged: attempt > 1, attempts: attempts))
    }

    /// A failed attempt ends the race only when no other attempt is still
    /// running (and, for the first attempt, before any hedge was opened).
    /// `final` (deadline, cancellation) ends it regardless.
    func fail(_ error: Error, final: Bool = false) {
        lock.lock()
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        failures += 1
        guard final || failures >= sockets.count else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        let open = sockets
        lock.unlock()
        for socket in open { socket.cancel(with: .goingAway, reason: nil) }
        continuation.resume(throwing: error)
    }
}

/// macOS warm pool handle: one per dictation, wrapping a possibly reused
/// `SonioxProvider`. The lease makes stale calls from an earlier session's
/// handle harmless once a newer session has claimed the actor.
final class LeasedSonioxProvider: ASRProvider, ProviderLivenessReporting, @unchecked Sendable {
    let base: SonioxProvider
    private let lease = UUID()

    init(base: SonioxProvider) {
        self.base = base
    }

    var id: String { base.id }
    var displayName: String { base.displayName }

    func attachLiveness(_ probe: ProviderLivenessProbe) async {
        await base.attachLiveness(probe, lease: lease)
    }

    func prepare(context: ASRContext) async throws {
        try await base.prepare(context: context, lease: lease)
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        try await base.startUtterance(id: id, context: context, lease: lease, eventHandler: eventHandler)
    }

    func send(_ chunk: PCM16Chunk) async throws {
        try await base.send(chunk, lease: lease)
    }

    func finalize() async throws -> TranscriptResult {
        try await base.finalize(lease: lease)
    }

    func cancel() async {
        await base.cancel(lease: lease)
    }
}

/// macOS: keeps at most one Soniox actor whose last utterance ended with a
/// clean `<fin>`, so the next press within the warm TTL skips the handshake.
/// Instances that timed out, failed or were cancelled are never offered back;
/// that is what the old "never return to a warm pool" rule protected against.
@MainActor
final class SonioxWarmPool {
    private var idle: SonioxProvider?

    func take() -> SonioxProvider? {
        defer { idle = nil }
        return idle
    }

    func offer(_ provider: SonioxProvider) {
        if let old = idle, old !== provider {
            Task { await old.closeIfIdle() }
        }
        idle = provider
    }

    func drain() {
        if let old = idle {
            Task { await old.closeIfIdle() }
        }
        idle = nil
    }
}
