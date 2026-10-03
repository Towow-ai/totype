#if VERBATIM_ENABLE_SPEECH_ANALYZER
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
actor AppleSpeechAnalyzerProvider: ASRProvider {
    nonisolated let id = "apple-speech-analyzer"
    nonisolated let displayName = "Apple on-device SpeechAnalyzer"

    private let model = "SpeechTranscriber.progressiveTranscription"
    private let preferredLocale = Locale(identifier: "zh-CN")

    private var selectedLocale: Locale?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var startedAt: Date?
    private var finalizeRequestedAt: Date?
    private var firstPartialAt: Date?
    private var finalText = ""
    private var volatileText = ""
    private var converter: AnalyzerInputConverter?

    func prepare(context: ASRContext) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw ASRProviderError.unavailable("Apple SpeechTranscriber 在当前 Mac 硬件上不可用")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            throw ASRProviderError.unavailable("Apple SpeechTranscriber 当前设备不支持简体中文")
        }

        // Speech assets are locale-scoped. Keep the locale reserved so the system
        // does not evict the model between personal-use sessions.
        _ = try await AssetInventory.reserve(locale: locale)
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        selectedLocale = locale
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        if selectedLocale == nil {
            try await prepare(context: context)
        }
        guard let selectedLocale else { throw ASRProviderError.notPrepared }

        await cancel()
        self.eventHandler = eventHandler
        finalText = ""
        volatileText = ""
        startedAt = Date()
        finalizeRequestedAt = nil
        firstPartialAt = nil

        let transcriber = SpeechTranscriber(locale: selectedLocale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ASRProviderError.unavailable("Apple SpeechAnalyzer 无法确定可用音频格式")
        }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await self?.consume(text: text, isFinal: result.isFinal)
                }
            } catch {
                await self?.reportFailure(error)
            }
        }

        try await analyzer.start(inputSequence: stream)
        eventHandler(.connected(providerID: self.id))
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard let inputContinuation, let converter else { throw ASRProviderError.notPrepared }
        let source = try Self.makePCMBuffer(from: chunk)
        for input in try converter.convert(source, at: nil) {
            inputContinuation.yield(input)
        }
    }

    func finalize() async throws -> TranscriptResult {
        guard let analyzer, let startedAt else { throw ASRProviderError.invalidState("Apple baseline 没有活动口述") }
        finalizeRequestedAt = Date()
        if let converter, let inputContinuation {
            for input in try converter.flush() {
                inputContinuation.yield(input)
            }
        }
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultTask?.value

        let finishedAt = Date()
        let result = TranscriptResult(
            providerID: id,
            model: model,
            text: finalText,
            tokens: [],
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstPartialLatencyMilliseconds: firstPartialAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            finalizeLatencyMilliseconds: finalizeRequestedAt.map { Int(finishedAt.timeIntervalSince($0) * 1_000) }
        )
        eventHandler?(.finalized(providerID: id, text: finalText))
        clearSession()
        return result
    }

    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        resultTask?.cancel()
        resultTask = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        clearSession()
    }

    private func consume(text: String, isFinal: Bool) {
        if firstPartialAt == nil { firstPartialAt = Date() }
        if isFinal {
            finalText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        eventHandler?(.partial(providerID: id, text: finalText + volatileText))
    }

    private func reportFailure(_ error: Error) {
        eventHandler?(.failed(providerID: id, message: error.localizedDescription))
    }

    private func clearSession() {
        transcriber = nil
        analyzer = nil
        analyzerFormat = nil
        converter = nil
        resultTask = nil
        eventHandler = nil
        startedAt = nil
        finalizeRequestedAt = nil
        firstPartialAt = nil
        volatileText = ""
    }

    private static func makePCMBuffer(from chunk: PCM16Chunk) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(chunk.sampleRate),
            channels: AVAudioChannelCount(chunk.channels),
            interleaved: false
        ) else {
            throw ASRProviderError.invalidState("无法创建 PCM16 输入格式")
        }
        let frames = chunk.data.count / MemoryLayout<Int16>.size / max(1, chunk.channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.int16ChannelData?.pointee else {
            throw ASRProviderError.invalidState("无法创建 PCM16 输入缓冲")
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
#else
import Foundation

/// Soniox-only builds remain possible with older Xcode versions. The real
/// SpeechAnalyzer implementation is compiled only for builds that explicitly
/// enable and verify the Xcode 26 SDK surface.
actor AppleSpeechAnalyzerProvider: ASRProvider {
    nonisolated let id = "apple-speech-analyzer"
    nonisolated let displayName = "Apple on-device SpeechAnalyzer"

    func prepare(context: ASRContext) async throws {
        throw ASRProviderError.unavailable("Apple 本地对照需要 Xcode 26 / Swift 6.2 工具链")
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        throw ASRProviderError.unavailable("Apple 本地对照需要 Xcode 26 / Swift 6.2 工具链")
    }

    func send(_ chunk: PCM16Chunk) async throws {
        throw ASRProviderError.notPrepared
    }

    func finalize() async throws -> TranscriptResult {
        throw ASRProviderError.notPrepared
    }

    func cancel() async {}
}
#endif
