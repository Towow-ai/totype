import AVFoundation
import Foundation
import Speech

/// An optional comparison provider that works on the app's macOS 15 deployment
/// target. It is disabled by default and its output is never inserted or used
/// as a fallback for the primary high-quality provider.
actor AppleSpeechRecognizerProvider: ASRProvider {
    nonisolated let id = "apple-speech-recognizer"
    nonisolated let displayName = "Apple system dictation"

    private let model = "SFSpeechRecognizer.zh-CN"
    private let locale = Locale(identifier: "zh-CN")

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var startedAt: Date?
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var latestText = ""
    private var latestResultWasFinal = false
    private var finalizeContinuation: CheckedContinuation<TranscriptResult, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var prefersOnDeviceRecognition = false

    func prepare(context: ASRContext) async throws {
        let authorization = await Self.requestAuthorizationIfNeeded()
        guard authorization == .authorized else {
            throw ASRProviderError.unavailable("Apple 语音识别权限未授予")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ASRProviderError.unavailable("当前 Mac 无法创建简体中文语音识别器")
        }
        guard recognizer.isAvailable else {
            throw ASRProviderError.unavailable("Apple 语音识别当前不可用")
        }
        self.recognizer = recognizer
        prefersOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        await cancel()
        try await prepare(context: context)
        guard let recognizer else { throw ASRProviderError.notPrepared }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if prefersOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.request = request
        self.eventHandler = eventHandler
        startedAt = Date()
        firstPartialAt = nil
        finalizeRequestedAt = nil
        latestText = ""
        latestResultWasFinal = false

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { await self?.consume(result: result, error: error) }
        }
        eventHandler(.connected(providerID: self.id))
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard let request else { throw ASRProviderError.notPrepared }
        request.append(try Self.makePCMBuffer(from: chunk))
    }

    func finalize() async throws -> TranscriptResult {
        guard request != nil, startedAt != nil else {
            throw ASRProviderError.invalidState("Apple 语音识别没有活动口述")
        }
        guard finalizeContinuation == nil else {
            throw ASRProviderError.invalidState("Apple 语音识别已经在定稿")
        }

        finalizeRequestedAt = Date()
        request?.endAudio()
        request = nil

        if latestResultWasFinal {
            return finishSuccessfully()
        }

        return try await withCheckedThrowingContinuation { continuation in
            finalizeContinuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.finalizationTimedOut()
            }
        }
    }

    func cancel() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        request?.endAudio()
        request = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if let continuation = finalizeContinuation {
            finalizeContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        clearSession()
    }

    private func consume(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            latestText = result.bestTranscription.formattedString
            latestResultWasFinal = result.isFinal
            if firstPartialAt == nil, !latestText.isEmpty { firstPartialAt = Date() }
            if !latestText.isEmpty {
                eventHandler?(.partial(providerID: id, text: latestText))
            }
            if result.isFinal, let continuation = finalizeContinuation {
                finalizeContinuation = nil
                timeoutTask?.cancel()
                timeoutTask = nil
                let transcript = finishSuccessfully()
                eventHandler?(.finalized(providerID: id, text: transcript.text))
                continuation.resume(returning: transcript)
            }
        }

        if let error, !latestResultWasFinal {
            finishWithError(error)
        }
    }

    private func finalizationTimedOut() {
        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        timeoutTask = nil
        if !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let transcript = finishSuccessfully()
            eventHandler?(.warning(providerID: id, message: "Apple 定稿超时，已保留最后一版转写"))
            continuation.resume(returning: transcript)
        } else {
            let error = ASRProviderError.timeout("Apple 语音识别未在 8 秒内返回结果")
            eventHandler?(.failed(providerID: id, message: error.localizedDescription))
            clearSession()
            continuation.resume(throwing: error)
        }
    }

    private func finishWithError(_ error: Error) {
        eventHandler?(.failed(providerID: id, message: error.localizedDescription))
        guard let continuation = finalizeContinuation else { return }
        finalizeContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continuation.resume(returning: finishSuccessfully())
        } else {
            clearSession()
            continuation.resume(throwing: error)
        }
    }

    private func finishSuccessfully() -> TranscriptResult {
        let began = startedAt ?? Date()
        let finished = Date()
        let transcript = TranscriptResult(
            providerID: id,
            model: prefersOnDeviceRecognition ? "\(model).on-device" : model,
            text: latestText,
            tokens: [],
            startedAt: began,
            finishedAt: finished,
            firstPartialLatencyMilliseconds: firstPartialAt.map { Int($0.timeIntervalSince(began) * 1_000) },
            finalizeLatencyMilliseconds: finalizeRequestedAt.map { Int(finished.timeIntervalSince($0) * 1_000) }
        )
        clearSession()
        return transcript
    }

    private func clearSession() {
        request = nil
        recognitionTask = nil
        eventHandler = nil
        startedAt = nil
        firstPartialAt = nil
        finalizeRequestedAt = nil
        latestResultWasFinal = false
    }

    private static func requestAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func makePCMBuffer(from chunk: PCM16Chunk) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(chunk.sampleRate),
            channels: AVAudioChannelCount(chunk.channels),
            interleaved: false
        ) else {
            throw ASRProviderError.invalidState("无法创建 Apple Speech PCM16 输入格式")
        }
        let frames = chunk.data.count / MemoryLayout<Int16>.size / max(1, chunk.channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.int16ChannelData?.pointee else {
            throw ASRProviderError.invalidState("无法创建 Apple Speech PCM16 输入缓冲")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        chunk.data.withUnsafeBytes { raw in
            if let source = raw.baseAddress {
                memcpy(destination, source, chunk.data.count)
            }
        }
        return buffer
    }
}
