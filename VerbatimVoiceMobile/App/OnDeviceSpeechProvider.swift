import AVFoundation
import Foundation
import Speech

/// Apple's own speech recognition on the phone, used when no cloud key is
/// saved. Audio never leaves the device. Two engines, picked per dictation:
///
/// 1. iOS 26+: `SpeechAnalyzer` + `SpeechTranscriber`, once its Chinese model
///    is installed (`OnDeviceSpeech.prepareAnalyzerModel()` downloads it in
///    the foreground; until then engine 2 runs).
/// 2. `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, which needs the
///    speech recognition permission and a phone that supports offline
///    Chinese. Server-side Apple recognition is never used.
///
/// Both are less accurate than the cloud engines, especially for names,
/// terms and mixed Chinese/English. Personal terms go to engine 2 as
/// `contextualStrings`; engine 1 has no hint list here.
actor OnDeviceSpeechProvider: ASRProvider {
    nonisolated static let providerID = "apple-on-device"
    nonisolated let id = OnDeviceSpeechProvider.providerID
    nonisolated let displayName = "本机识别"

    private let terms: [String]
    private var engine: (any ASRProvider)?

    init(terms: [String] = []) {
        self.terms = terms
    }

    func prepare(context: ASRContext) async throws {}

    func startUtterance(
        id utteranceID: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        await engine?.cancel()
        engine = nil
        if #available(iOS 26.0, *), await OnDeviceSpeech.analyzerModelInstalled() {
            let analyzer = AnalyzerEngine(providerID: id, locale: OnDeviceSpeech.locale)
            do {
                try await analyzer.startUtterance(id: utteranceID, context: context, eventHandler: eventHandler)
                engine = analyzer
                return
            } catch {
                // Fall through to the older engine with the same audio.
                await analyzer.cancel()
                eventHandler(.warning(providerID: id, message: "SpeechAnalyzer 未能启动，改用系统听写：\(error.localizedDescription)"))
            }
        }
        let recognizer = RecognizerEngine(providerID: id, locale: OnDeviceSpeech.locale, terms: terms)
        try await recognizer.startUtterance(id: utteranceID, context: context, eventHandler: eventHandler)
        engine = recognizer
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard let engine else { throw ASRProviderError.notPrepared }
        try await engine.send(chunk)
    }

    func finalize() async throws -> TranscriptResult {
        guard let engine else { throw ASRProviderError.invalidState("本机识别没有进行中的听写") }
        defer { self.engine = nil }
        return try await engine.finalize()
    }

    func cancel() async {
        await engine?.cancel()
        engine = nil
    }
}

/// Permission and model state shared by the provider, settings and onboarding.
enum OnDeviceSpeech {
    static let locale = Locale(identifier: "zh-CN")

    static var authorization: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Shows the system prompt the first time; call only in the foreground.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Whether `SFSpeechRecognizer` can run zh-CN without a network.
    static var recognizerSupportsOnDevice: Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// iOS 26+ and the SpeechTranscriber model for zh-CN is on the phone.
    static func analyzerModelInstalled() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Starts the SpeechTranscriber model download if it is missing (iOS 26+).
    /// Returns once it is installed, or at once when nothing can be done.
    /// The system keeps downloading after the app leaves the foreground.
    @discardableResult
    static func prepareAnalyzerModel() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            SessionDiagnostics.log("onDevice.model.failed", "error=\(error.localizedDescription)")
            return false
        }
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    /// Why local recognition cannot start, or nil when it can. The analyzer
    /// path needs no speech permission; the recognizer path does.
    static func unavailableReason() async -> String? {
        if await analyzerModelInstalled() { return nil }
        switch authorization {
        case .authorized:
            break
        case .notDetermined:
            return "本机识别需要语音识别权限：请打开 \(MobileIdentity.displayName) 后再试，或在 设置 里填写云端 Key"
        default:
            return "本机识别需要语音识别权限：请到 系统设置 → \(MobileIdentity.displayName) 打开语音识别，或在 设置 里填写云端 Key"
        }
        guard recognizerSupportsOnDevice else {
            return "这台 iPhone 不支持离线中文识别，请在 设置 里填写 Soniox 或百炼 Key"
        }
        return nil
    }

    static func pcmBuffer(from chunk: PCM16Chunk) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(chunk.sampleRate),
            channels: AVAudioChannelCount(chunk.channels),
            interleaved: false
        ) else {
            throw ASRProviderError.invalidState("无法创建 PCM16 输入格式")
        }
        let frames = chunk.data.count / MemoryLayout<Int16>.size / max(1, chunk.channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))),
              let destination = buffer.int16ChannelData?.pointee else {
            throw ASRProviderError.invalidState("无法创建 PCM16 输入缓冲")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        chunk.data.withUnsafeBytes { raw in
            if let source = raw.baseAddress { memcpy(destination, source, frames * MemoryLayout<Int16>.size) }
        }
        return buffer
    }

    static func result(
        providerID: String, model: String, text: String,
        startedAt: Date, firstPartialAt: Date?, finalizeRequestedAt: Date?
    ) -> TranscriptResult {
        let finished = Date()
        return TranscriptResult(
            providerID: providerID,
            model: model,
            text: text,
            tokens: [],
            startedAt: startedAt,
            finishedAt: finished,
            firstPartialLatencyMilliseconds: firstPartialAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            finalizeLatencyMilliseconds: finalizeRequestedAt.map { Int(finished.timeIntervalSince($0) * 1_000) }
        )
    }
}

// MARK: - SFSpeechRecognizer

/// `SFSpeechRecognizer` restricted to on-device recognition. Ported from the
/// macOS `AppleSpeechRecognizerProvider`.
private actor RecognizerEngine: ASRProvider {
    nonisolated let id: String
    nonisolated let displayName = "SFSpeechRecognizer"
    private let locale: Locale
    private let terms: [String]

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var startedAt: Date?
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var latestText = ""
    private var latestIsFinal = false
    /// The task ended with an error while audio was still coming: no
    /// further callback will arrive, so `finalize` must not wait for one.
    private var endedWithError: String?
    private var continuation: CheckedContinuation<TranscriptResult, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(providerID: String, locale: Locale, terms: [String]) {
        id = providerID
        self.locale = locale
        self.terms = terms
    }

    func prepare(context: ASRContext) async throws {}

    func startUtterance(
        id utteranceID: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw ASRProviderError.unavailable("本机识别需要语音识别权限")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ASRProviderError.unavailable("无法创建简体中文语音识别器")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ASRProviderError.unavailable("这台 iPhone 不支持离线中文识别")
        }
        guard recognizer.isAvailable else {
            throw ASRProviderError.unavailable("系统语音识别当前不可用")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // The documented guidance is at most 100 phrases.
        request.contextualStrings = Array(terms.prefix(100))

        self.request = request
        self.eventHandler = eventHandler
        startedAt = Date()
        firstPartialAt = nil
        finalizeRequestedAt = nil
        latestText = ""
        latestIsFinal = false
        endedWithError = nil
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { await self?.consume(text: text, isFinal: isFinal, error: message) }
        }
        eventHandler(.connected(providerID: id))
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard let request else { throw ASRProviderError.notPrepared }
        request.append(try OnDeviceSpeech.pcmBuffer(from: chunk))
    }

    func finalize() async throws -> TranscriptResult {
        guard startedAt != nil else { throw ASRProviderError.invalidState("系统听写没有进行中的听写") }
        finalizeRequestedAt = Date()
        request?.endAudio()
        request = nil
        if latestIsFinal { return finish() }
        if let endedWithError {
            if latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reset()
                throw ASRProviderError.server(endedWithError)
            }
            return finish()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await self?.timedOut()
            }
        }
    }

    func cancel() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        startedAt = nil
        eventHandler = nil
    }

    private func consume(text: String?, isFinal: Bool, error: String?) {
        guard startedAt != nil else { return }
        if let text {
            latestText = text
            latestIsFinal = isFinal
            if firstPartialAt == nil, !text.isEmpty { firstPartialAt = Date() }
            if !text.isEmpty { eventHandler?(.partial(providerID: id, text: text)) }
            if isFinal, let continuation {
                self.continuation = nil
                continuation.resume(returning: finish())
                return
            }
        }
        guard let error, !latestIsFinal else { return }
        eventHandler?(.failed(providerID: id, message: error))
        guard let continuation else {
            endedWithError = error
            return
        }
        self.continuation = nil
        if latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reset()
            continuation.resume(throwing: ASRProviderError.server(error))
        } else {
            continuation.resume(returning: finish())
        }
    }

    private func timedOut() {
        guard let continuation else { return }
        self.continuation = nil
        if latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reset()
            continuation.resume(throwing: ASRProviderError.timeout("系统听写没有在 6 秒内给出结果"))
        } else {
            eventHandler?(.warning(providerID: id, message: "系统听写定稿超时，保留最后一版"))
            continuation.resume(returning: finish())
        }
    }

    private func finish() -> TranscriptResult {
        let result = OnDeviceSpeech.result(
            providerID: id, model: "SFSpeechRecognizer.on-device.\(locale.identifier)", text: latestText,
            startedAt: startedAt ?? Date(), firstPartialAt: firstPartialAt, finalizeRequestedAt: finalizeRequestedAt
        )
        eventHandler?(.finalized(providerID: id, text: latestText))
        reset()
        return result
    }

    private func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        task = nil
        request = nil
        startedAt = nil
        eventHandler = nil
    }
}

// MARK: - SpeechAnalyzer

@available(iOS 26.0, *)
private actor AnalyzerEngine: ASRProvider {
    nonisolated let id: String
    nonisolated let displayName = "SpeechAnalyzer"
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var startedAt: Date?
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var finalText = ""
    private var volatileText = ""
    private var failure: String?

    init(providerID: String, locale: Locale) {
        id = providerID
        self.locale = locale
    }

    func prepare(context: ASRContext) async throws {}

    func startUtterance(
        id utteranceID: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ASRProviderError.unavailable("SpeechTranscriber 不支持简体中文")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ASRProviderError.unavailable("SpeechAnalyzer 没有可用的音频格式")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        self.eventHandler = eventHandler
        startedAt = Date()
        firstPartialAt = nil
        finalizeRequestedAt = nil
        finalText = ""
        volatileText = ""
        failure = nil
        analyzerFormat = format
        converter = nil

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.consume(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                await self?.fail(error.localizedDescription)
            }
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        eventHandler(.connected(providerID: id))
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard let input, let analyzerFormat else { throw ASRProviderError.notPrepared }
        let source = try OnDeviceSpeech.pcmBuffer(from: chunk)
        input.yield(AnalyzerInput(buffer: try convert(source, to: analyzerFormat)))
    }

    func finalize() async throws -> TranscriptResult {
        guard let analyzer, let startedAt else { throw ASRProviderError.invalidState("SpeechAnalyzer 没有进行中的听写") }
        finalizeRequestedAt = Date()
        input?.finish()
        input = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultTask?.value
        let text = finalText + volatileText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let failure {
            reset()
            throw ASRProviderError.server(failure)
        }
        let result = OnDeviceSpeech.result(
            providerID: id, model: "SpeechTranscriber.\(locale.identifier)", text: text,
            startedAt: startedAt, firstPartialAt: firstPartialAt, finalizeRequestedAt: finalizeRequestedAt
        )
        eventHandler?(.finalized(providerID: id, text: text))
        reset()
        return result
    }

    func cancel() async {
        input?.finish()
        input = nil
        resultTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        reset()
    }

    private func consume(text: String, isFinal: Bool) {
        if firstPartialAt == nil, !text.isEmpty { firstPartialAt = Date() }
        if isFinal {
            finalText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        eventHandler?(.partial(providerID: id, text: finalText + volatileText))
    }

    private func fail(_ message: String) {
        failure = message
        eventHandler?(.failed(providerID: id, message: message))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            guard let made = AVAudioConverter(from: buffer.format, to: format) else {
                throw ASRProviderError.invalidState("无法创建 SpeechAnalyzer 音频转换器")
            }
            converter = made
        }
        guard let converter else { throw ASRProviderError.notPrepared }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ASRProviderError.invalidState("无法创建 SpeechAnalyzer 输入缓冲")
        }
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw ASRProviderError.invalidState("音频转换失败：\(conversionError?.localizedDescription ?? "未知错误")")
        }
        return output
    }

    private func reset() {
        resultTask = nil
        analyzer = nil
        analyzerFormat = nil
        converter = nil
        eventHandler = nil
        startedAt = nil
    }
}
