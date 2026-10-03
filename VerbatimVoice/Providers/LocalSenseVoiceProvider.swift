import Foundation

/// Fully local, literal-first transcription backed by the official
/// SenseVoiceSmall GGUF runtime. Audio stays on this Mac and no account or API
/// key is required. The provider intentionally emits only a final result: it
/// never invents partial text while the utterance is still being recorded.
actor LocalSenseVoiceProvider: ASRProvider {
    nonisolated let id = "local-sensevoice"
    nonisolated let displayName = "SenseVoiceSmall q8（本地）"

    private static let maximumPCMBytes = 32_000 * 900

    private var utteranceID: UUID?
    private var startedAt: Date?
    private var pcm = Data()
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var runningProcess: Process?
    private let runtimeDirectory: URL?

    init(runtimeDirectory: URL? = nil) {
        self.runtimeDirectory = runtimeDirectory
    }

    /// True when the runtime and both models are in the app bundle or in the
    /// downloaded models folder (see `LocalModelFiles`).
    nonisolated static var isRuntimeAvailable: Bool { LocalModelFiles.current() != nil }

    func prepare(context: ASRContext) async throws {
        _ = context
        let urls = try resolvedRuntimeURLs()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: urls.executable.path) else {
            throw ASRProviderError.unavailable("本地 SenseVoice 运行程序缺失或不可执行")
        }
        guard fm.fileExists(atPath: urls.model.path), fm.fileExists(atPath: urls.vad.path) else {
            throw ASRProviderError.unavailable("本地 SenseVoice 模型不完整；请在设置里重新下载")
        }
    }

    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws {
        guard utteranceID == nil, runningProcess == nil else {
            throw ASRProviderError.invalidState("上一段本地转写尚未结束")
        }
        try await prepare(context: context)
        utteranceID = id
        startedAt = Date()
        pcm.removeAll(keepingCapacity: true)
        self.eventHandler = eventHandler
        eventHandler(.connected(providerID: self.id))
    }

    func send(_ chunk: PCM16Chunk) async throws {
        guard utteranceID != nil else { throw ASRProviderError.notPrepared }
        guard chunk.sampleRate == 16_000, chunk.channels == 1 else {
            throw ASRProviderError.invalidState("本地模型只接受 16 kHz 单声道 PCM16")
        }
        guard pcm.count + chunk.data.count <= Self.maximumPCMBytes else {
            throw ASRProviderError.unavailable("本地转写音频超过 15 分钟安全上限")
        }
        pcm.append(chunk.data)
    }

    func finalize() async throws -> TranscriptResult {
        guard let utteranceID, let startedAt else {
            throw ASRProviderError.notPrepared
        }
        guard pcm.count >= 640 else {
            reset()
            throw ASRProviderError.unavailable("录音太短，没有足够的语音可识别")
        }

        let finalizeStartedAt = Date()
        let runtime = try resolvedRuntimeURLs()
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-sensevoice-\(utteranceID.uuidString).wav")
        try Self.makeWAV(fromPCM16Mono: pcm, sampleRate: 16_000).write(to: wavURL, options: .atomic)

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            reset()
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = runtime.executable
        process.arguments = [
            "-m", runtime.model.path,
            "--vad", runtime.vad.path,
            "-a", wavURL.path
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        runningProcess = process

        do {
            try process.run()
        } catch {
            runningProcess = nil
            throw ASRProviderError.unavailable("无法启动本地 SenseVoice：\(error.localizedDescription)")
        }

        let status = await Task.detached(priority: .userInitiated) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        runningProcess = nil

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnosticData = stderr.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(decoding: diagnosticData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0 else {
            let detail = diagnostic.isEmpty ? "退出状态 \(status)" : diagnostic
            throw ASRProviderError.unavailable("本地 SenseVoice 识别失败：\(detail)")
        }

        let text = Self.literalTranscript(from: String(decoding: outputData, as: UTF8.self))
        guard !text.isEmpty else {
            throw ASRProviderError.unavailable("本地 SenseVoice 没有识别到语音")
        }

        let finishedAt = Date()
        eventHandler?(.finalized(providerID: id, text: text))
        return TranscriptResult(
            providerID: id,
            model: displayName,
            text: text,
            tokens: [],
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstPartialLatencyMilliseconds: nil,
            finalizeLatencyMilliseconds: Int(finishedAt.timeIntervalSince(finalizeStartedAt) * 1_000)
        )
    }

    func cancel() async {
        if let process = runningProcess, process.isRunning {
            process.terminate()
        }
        reset()
    }

    private func reset() {
        utteranceID = nil
        startedAt = nil
        pcm.removeAll(keepingCapacity: true)
        eventHandler = nil
        runningProcess = nil
    }

    private static func urls(in directory: URL) -> (executable: URL, model: URL, vad: URL) {
        (
            directory.appendingPathComponent(LocalModelFiles.executableName),
            directory.appendingPathComponent(LocalModelFiles.modelName),
            directory.appendingPathComponent(LocalModelFiles.vadName)
        )
    }

    private func resolvedRuntimeURLs() throws -> (executable: URL, model: URL, vad: URL) {
        if let runtimeDirectory { return Self.urls(in: runtimeDirectory) }
        guard let location = LocalModelFiles.current() else {
            throw ASRProviderError.unavailable("本地 SenseVoice 模型未安装；请在设置里下载，或改用云端识别")
        }
        return Self.urls(in: location.directory)
    }

    private nonisolated static func literalTranscript(from output: String) -> String {
        output
            .replacingOccurrences(of: #"<\|[^|>]+\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func makeWAV(fromPCM16Mono pcm: Data, sampleRate: UInt32) -> Data {
        var wav = Data(capacity: 44 + pcm.count)
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(sampleRate, to: &wav)
        append(sampleRate * 2, to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count), to: &wav)
        wav.append(pcm)
        return wav
    }

    private nonisolated static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
