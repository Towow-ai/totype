import Foundation

struct AliyunWord: Equatable, Sendable {
    let text: String
    let punctuation: String
    let beginMilliseconds: Int?
    let endMilliseconds: Int?
}

enum AliyunRealtimeProtocol {
    static let model = "qwen-audio-3.0-asr-flash-streaming"

    enum ServerEvent: Equatable {
        case taskStarted(taskID: String?)
        case result(text: String, sentenceID: Int, sentenceEnd: Bool, words: [AliyunWord])
        case taskFinished(taskID: String?)
        case failure(code: String?, message: String)
        case other(String)
    }

    static func endpoint(region: AliyunRegion) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = region.webSocketHost
        components.path = "/api-ws/v1/inference"
        guard let url = components.url else {
            throw ASRProviderError.invalidState("无法生成阿里云 WebSocket 地址")
        }
        return url
    }

    static func runTaskJSON(taskID: UUID, context: ASRContext) throws -> String {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            "language_hints": Array(context.languages.prefix(4)),
            "semantic_punctuation_enabled": true
        ]

        var vocabulary: [String: Int] = [:]
        for term in context.terms.prefix(2_000) {
            let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            vocabulary[value] = min(5, max(1, context.hotwordWeight))
        }
        if !vocabulary.isEmpty {
            parameters["vocabulary"] = vocabulary
        }

        let prompt = String(context.text.prefix(400))
        let input: [String: Any]
        if prompt.isEmpty {
            input = [:]
        } else {
            input = [
                "context": [[
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": prompt
                    ]]
                ]]
            ]
        }

        return try encode([
            "header": [
                "action": "run-task",
                "task_id": taskID.uuidString.lowercased(),
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": parameters,
                "input": input
            ] as [String: Any]
        ])
    }

    static func finishTaskJSON(taskID: UUID) throws -> String {
        try encode([
            "header": [
                "action": "finish-task",
                "task_id": taskID.uuidString.lowercased(),
                "streaming": "duplex"
            ],
            "payload": ["input": [:]]
        ])
    }

    static func parseServerEvent(_ data: Data) -> ServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let header = dictionary["header"] as? [String: Any],
              let event = header["event"] as? String else { return nil }

        switch event {
        case "task-started":
            return .taskStarted(taskID: header["task_id"] as? String)
        case "result-generated":
            guard let payload = dictionary["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else {
                return nil
            }
            if sentence["heartbeat"] as? Bool == true {
                return .other("heartbeat")
            }
            let words: [AliyunWord] = (sentence["words"] as? [[String: Any]] ?? []).map {
                AliyunWord(
                    text: $0["text"] as? String ?? "",
                    punctuation: $0["punctuation"] as? String ?? "",
                    beginMilliseconds: $0["begin_time"] as? Int,
                    endMilliseconds: $0["end_time"] as? Int
                )
            }
            return .result(
                text: sentence["text"] as? String ?? "",
                sentenceID: sentence["sentence_id"] as? Int ?? 0,
                sentenceEnd: sentence["sentence_end"] as? Bool ?? false,
                words: words
            )
        case "task-finished":
            return .taskFinished(taskID: header["task_id"] as? String)
        case "task-failed":
            return .failure(
                code: header["error_code"] as? String,
                message: header["error_message"] as? String ?? "阿里云返回未知错误"
            )
        default:
            return .other(event)
        }
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ASRProviderError.invalidState("无法编码阿里云实时事件")
        }
        return string
    }
}

actor AliyunASRProvider: ASRProvider, ProviderLivenessReporting {
    nonisolated let id = "aliyun-qwen-audio-asr"
    nonisolated let displayName = "阿里云 qwen-audio-3.0-asr-flash-streaming"

    private enum State {
        case disconnected
        case starting
        case ready
        case active
        case finalizing
    }

    private let apiKeyProvider: @Sendable () throws -> String
    private let regionProvider: @Sendable () -> AliyunRegion

    /// One long-lived session for every Aliyun socket (TLS/DNS reuse).
    /// Sockets are cancelled individually; the session is never invalidated.
    /// `waitsForConnectivity` stays on (bounded by the 7 s start deadline).
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private var state: State = .disconnected
    private var socket: URLSessionWebSocketTask?
    /// Session-owned probe for the current utterance.
    private var liveness: ProviderLivenessProbe?
    private var connectStartedAt: ContinuousClock.Instant?
    private var connectionSetupLatencyMilliseconds: Int?
    private var audioBytesSent = 0
    private var audioFrameCount = 0
    private var maxSendLatencyMilliseconds = 0
    private var backpressureEventCount = 0
    private var receiveTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var finalizationTimeoutTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// A server rejection that ended the current utterance (e.g. Arrearage
    /// mid-stream). Later send/finalize calls rethrow it so the session sees
    /// the billing/auth cause instead of "not ready".
    private var terminalError: Error?
    private var finalizationContinuation: CheckedContinuation<TranscriptResult, Error>?
    private var taskID: UUID?
    private var preparedContextSignature: String?

    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var utteranceStartedAt: Date?
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var sentenceTexts: [Int: String] = [:]
    private var tokens: [ASRToken] = []

    init(
        apiKeyProvider: @escaping @Sendable () throws -> String,
        regionProvider: @escaping @Sendable () -> AliyunRegion
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.regionProvider = regionProvider
    }

    func prepare(context: ASRContext) async throws {
        _ = try resolvedAPIKey()
        let signature = contextSignature(context)
        switch state {
        case .disconnected:
            try await connectAndStart(context: context, signature: signature)
        case .ready where preparedContextSignature == signature:
            return
        case .ready:
            closeConnection()
            try await connectAndStart(context: context, signature: signature)
        case .starting, .active, .finalizing:
            throw ASRProviderError.invalidState("阿里云会话正在使用")
        }
    }

    func startUtterance(
        id utteranceID: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        _ = utteranceID
        terminalError = nil
        let signature = contextSignature(context)
        switch state {
        case .disconnected:
            try await connectAndStart(context: context, signature: signature)
        case .ready where preparedContextSignature == signature:
            break
        case .ready:
            closeConnection()
            try await connectAndStart(context: context, signature: signature)
        case .starting, .active, .finalizing:
            throw ASRProviderError.invalidState("上一段阿里云口述尚未结束")
        }

        self.eventHandler = eventHandler
        utteranceStartedAt = Date()
        firstPartialAt = nil
        finalizeRequestedAt = nil
        sentenceTexts.removeAll(keepingCapacity: true)
        tokens.removeAll(keepingCapacity: true)
        audioBytesSent = 0
        audioFrameCount = 0
        maxSendLatencyMilliseconds = 0
        backpressureEventCount = 0
        state = .active
        eventHandler(.connected(providerID: self.id))
    }

    func attachLiveness(_ probe: ProviderLivenessProbe) async {
        liveness = probe
    }

    func send(_ chunk: PCM16Chunk) async throws {
        if let terminalError { throw terminalError }
        guard state == .active, let socket else {
            throw ASRProviderError.invalidState("阿里云实时连接尚未就绪")
        }
        guard chunk.sampleRate == 16_000, chunk.channels == 1 else {
            throw ASRProviderError.invalidState("阿里云实时输入必须是 16 kHz 单声道 PCM")
        }
        guard !chunk.data.isEmpty else { return }
        let started = ContinuousClock.now
        try await socket.send(.data(chunk.data))
        let milliseconds = Int(ProviderLivenessProbe.nanoseconds(started.duration(to: .now)) / 1_000_000)
        audioBytesSent += chunk.data.count
        audioFrameCount += 1
        maxSendLatencyMilliseconds = max(maxSendLatencyMilliseconds, milliseconds)
        if milliseconds >= 240 { backpressureEventCount += 1 }
    }

    func finalize() async throws -> TranscriptResult {
        if let terminalError { throw terminalError }
        guard state == .active, let socket, let taskID else {
            throw ASRProviderError.invalidState("没有活动的阿里云实时口述")
        }
        guard finalizationContinuation == nil else {
            throw ASRProviderError.invalidState("阿里云口述已经在定稿")
        }

        state = .finalizing
        finalizeRequestedAt = Date()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<TranscriptResult, Error>) in
            finalizationContinuation = continuation
            finalizationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.finalizationTimedOut()
            }
            Task { [weak self] in
                do {
                    try await socket.send(.string(try AliyunRealtimeProtocol.finishTaskJSON(taskID: taskID)))
                } catch {
                    await self?.failActiveRequest(error)
                }
            }
        }
    }

    func cancel() async {
        liveness = nil
        terminalError = nil
        startTimeoutTask?.cancel()
        finalizationTimeoutTask?.cancel()
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let continuation = finalizationContinuation {
            finalizationContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        closeConnection()
    }

    private func connectAndStart(context: ASRContext, signature: String) async throws {
        state = .starting
        let key = try resolvedAPIKey()
        let endpoint = try AliyunRealtimeProtocol.endpoint(region: regionProvider())
        let taskID = UUID()
        self.taskID = taskID
        preparedContextSignature = signature

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let socket = Self.sharedSession.webSocketTask(with: request)
        self.socket = socket
        connectStartedAt = .now
        connectionSetupLatencyMilliseconds = nil
        socket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            startTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                await self?.startTimedOut()
            }
            Task { [weak self] in
                do {
                    try await socket.send(.string(try AliyunRealtimeProtocol.runTaskJSON(
                        taskID: taskID,
                        context: context
                    )))
                } catch {
                    await self?.failStart(error)
                }
            }
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    processServerData(Data(text.utf8))
                case .data(let data):
                    processServerData(data)
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            // DashScope rejects a bad key or an account in arrears during the
            // WebSocket handshake with an HTTP status rather than a frame.
            if let status = (socket.response as? HTTPURLResponse)?.statusCode,
               status >= 400 {
                failActiveRequest(ProviderRejection(
                    failureKind: ProviderFailureClassifier.httpStatus(status),
                    message: "阿里云拒绝连接（HTTP \(status)）：\(error.localizedDescription)"
                ))
                return
            }
            failActiveRequest(ASRProviderError.connectionFailed(error.localizedDescription))
        }
    }

    private func processServerData(_ data: Data) {
        liveness?.markServerMessage()
        guard let event = AliyunRealtimeProtocol.parseServerEvent(data) else {
            eventHandler?(.warning(providerID: id, message: "收到无法解析的阿里云响应"))
            return
        }

        switch event {
        case .taskStarted:
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            if let connectStartedAt {
                connectionSetupLatencyMilliseconds = Int(
                    ProviderLivenessProbe.nanoseconds(connectStartedAt.duration(to: .now)) / 1_000_000
                )
            }
            liveness?.markConnected(reused: false)
            state = .ready
            if let continuation = startContinuation {
                startContinuation = nil
                continuation.resume()
            }
        case .result(let text, let sentenceID, let sentenceEnd, let words):
            guard !text.isEmpty else { return }
            if firstPartialAt == nil { firstPartialAt = Date() }
            if sentenceEnd {
                sentenceTexts[sentenceID] = text
                tokens.append(contentsOf: words.map {
                    ASRToken(
                        text: $0.text + $0.punctuation,
                        startMilliseconds: $0.beginMilliseconds,
                        endMilliseconds: $0.endMilliseconds,
                        confidence: nil,
                        isFinal: true,
                        language: nil
                    )
                })
                eventHandler?(.finalized(providerID: id, text: joinedText(partial: nil)))
            } else {
                eventHandler?(.partial(providerID: id, text: joinedText(partial: (sentenceID, text))))
            }
        case .taskFinished:
            completeFinalization()
        case .failure(let code, let message):
            let detail = code.map { "\($0): \(message)" } ?? message
            // e.g. Arrearage → billing, InvalidApiKey → auth.
            failActiveRequest(ProviderRejection(
                failureKind: ProviderFailureClassifier.aliyun(code: code, message: message),
                message: detail
            ))
        case .other:
            break
        }
    }

    private func completeFinalization() {
        guard let continuation = finalizationContinuation,
              let startedAt = utteranceStartedAt else {
            closeConnection()
            return
        }

        finalizationContinuation = nil
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        let finishedAt = Date()
        let text = joinedText(partial: nil)
        let result = TranscriptResult(
            providerID: id,
            model: AliyunRealtimeProtocol.model,
            text: text,
            tokens: tokens,
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstPartialLatencyMilliseconds: firstPartialAt.map {
                Int($0.timeIntervalSince(startedAt) * 1_000)
            },
            finalizeLatencyMilliseconds: finalizeRequestedAt.map {
                Int(finishedAt.timeIntervalSince($0) * 1_000)
            },
            transportMetrics: ProviderTransportMetrics(
                audioBytesSent: audioBytesSent,
                audioFrameCount: audioFrameCount,
                maxSendLatencyMilliseconds: maxSendLatencyMilliseconds,
                backpressureEventCount: backpressureEventCount,
                connectionSetupLatencyMilliseconds: connectionSetupLatencyMilliseconds,
                reusedConnection: false,
                connectionAttemptCount: 1
            )
        )
        liveness = nil
        continuation.resume(returning: result)
        closeConnection()
    }

    private func joinedText(partial: (id: Int, text: String)?) -> String {
        var values = sentenceTexts
        if let partial { values[partial.id] = partial.text }
        return values.keys.sorted().reduce(into: "") { result, key in
            let next = values[key] ?? ""
            guard !next.isEmpty else { return }
            if let last = result.last, let first = next.first,
               last.isASCII, last.isLetter || last.isNumber,
               first.isASCII, first.isLetter || first.isNumber {
                result.append(" ")
            }
            result.append(next)
        }
    }

    private func startTimedOut() {
        guard startContinuation != nil else { return }
        failStart(ASRProviderError.timeout("阿里云未在 7 秒内启动转写任务"))
    }

    private func finalizationTimedOut() {
        guard finalizationContinuation != nil else { return }
        failActiveRequest(ASRProviderError.timeout("阿里云未在 10 秒内返回最终转写"))
    }

    private func failStart(_ error: Error) {
        liveness?.markFailed()
        if let continuation = startContinuation {
            startContinuation = nil
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            continuation.resume(throwing: error)
        }
        closeConnection()
    }

    private func failActiveRequest(_ error: Error) {
        if startContinuation != nil {
            failStart(error)
            return
        }
        if error is ClassifiedProviderError { terminalError = error }
        liveness?.markFailed()
        eventHandler?(.failed(providerID: id, message: error.localizedDescription))
        if let continuation = finalizationContinuation {
            finalizationContinuation = nil
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = nil
            continuation.resume(throwing: error)
        }
        closeConnection()
    }

    private func resolvedAPIKey() throws -> String {
        let key = try apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRProviderError.missingAPIKey("阿里云百炼") }
        return key
    }

    private func contextSignature(_ context: ASRContext) -> String {
        ([context.text, String(context.hotwordWeight)] + context.languages + context.terms)
            .joined(separator: "\u{1F}")
    }

    private func closeConnection() {
        startTimeoutTask?.cancel()
        finalizationTimeoutTask?.cancel()
        startTimeoutTask = nil
        finalizationTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connectStartedAt = nil
        eventHandler = nil
        taskID = nil
        preparedContextSignature = nil
        utteranceStartedAt = nil
        firstPartialAt = nil
        finalizeRequestedAt = nil
        sentenceTexts.removeAll(keepingCapacity: false)
        tokens.removeAll(keepingCapacity: false)
        state = .disconnected
    }
}
