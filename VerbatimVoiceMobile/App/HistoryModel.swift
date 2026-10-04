import AVFoundation
import Foundation

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var retranscribing: Set<UUID> = []
    @Published private(set) var playingID: UUID?
    @Published var status: String?

    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .verbatimHistoryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    /// Newest first.
    func reload() async {
        let loaded = (try? await HistoryStore.shared.recent(limit: 1_000)) ?? []
        records = loaded.reversed()
    }

    /// The text shown for a record: the original transcript, or the newest
    /// successful re-transcription when the original failed.
    static func displayText(_ record: HistoryRecord) -> String {
        if !record.insertedText.isEmpty { return record.insertedText }
        return record.transcriptRevisions?.last { !$0.text.isEmpty }?.text ?? ""
    }

    func togglePlayback(_ record: HistoryRecord) {
        if playingID == record.id {
            stopPlayback()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = try? await HistoryStore.shared.audioURL(for: record) else {
                status = "这条记录没有可播放的音频"
                return
            }
            do {
                // An armed session already holds playAndRecord, which can
                // play; switching category would stop its engine.
                let dictation = DictationController.shared
                if dictation.phase == .idle, !dictation.sessionActive, !dictation.sessionPaused {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                }
                let player = try AVAudioPlayer(contentsOf: url)
                player.play()
                self.player = player
                playingID = record.id
                let duration = player.duration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((duration + 0.2) * 1_000_000_000))
                    guard let self, self.player === player else { return }
                    self.stopPlayback()
                }
            } catch {
                status = "播放失败：\(error.localizedDescription)"
            }
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        if DictationController.shared.phase == .idle, !DictationController.shared.sessionActive,
           !DictationController.shared.sessionPaused {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Replays the archived audio through the same provider that produced
    /// the original (falling back to whichever key exists) and appends the
    /// result as a new revision. The original is never overwritten.
    func retranscribe(_ record: HistoryRecord) {
        guard !retranscribing.contains(record.id) else { return }
        guard let provider = Self.provider(for: record) else {
            status = "请先在 设置 里填写 Soniox 或百炼 API Key"
            return
        }
        retranscribing.insert(record.id)
        status = "正在重新转写…"
        let contexts = DictationController.shared.compileContexts(sessionID: UUID(), providerIDs: [provider.id])
        let context = contexts.contexts[provider.id] ?? .personal(terms: [])

        Task { @MainActor in
            defer { retranscribing.remove(record.id) }
            guard let audioURL = try? await HistoryStore.shared.audioURL(for: record) else {
                status = "音频文件已不存在，无法重新转写"
                return
            }
            let outcome = await Self.replay(audioURL: audioURL, provider: provider, context: context)
            let revision = TranscriptRevision(
                id: UUID(),
                createdAt: Date(),
                source: .retranscription,
                providerID: outcome.providerID,
                model: outcome.result?.model ?? outcome.model,
                text: outcome.result?.text ?? "",
                error: outcome.errorMessage
            )
            do {
                try await HistoryStore.shared.appendRevision(sessionID: record.id, revision: revision)
                await reload()
                status = outcome.result == nil
                    ? "重新转写失败：\(outcome.errorMessage ?? "未知错误")"
                    : "已新增一个转写版本"
            } catch {
                status = "转写完成，但版本保存失败：\(error.localizedDescription)"
            }
        }
    }

    private static func provider(for record: HistoryRecord) -> (any ASRProvider)? {
        let keychain = MobileEnvironment.keychain
        let preferred = record.effectiveProviderID ?? record.primary?.providerID
        let candidates = [preferred, MobileEnvironment.sonioxProviderID, MobileEnvironment.aliyunProviderID]
            .compactMap { $0 }
        for id in candidates {
            switch id {
            case MobileEnvironment.sonioxProviderID where keychain.contains(.soniox):
                return MobileEnvironment.makeSonioxProvider()
            case MobileEnvironment.aliyunProviderID where keychain.contains(.aliyun):
                return MobileEnvironment.makeAliyunProvider()
            default:
                continue
            }
        }
        return MobileEnvironment.hasCloudKey ? nil : MobileEnvironment.makeLocalProvider()
    }

    /// Ported from macOS `AppModel.retranscribeHistory`: archived audio is
    /// paced like live capture, under a deadline proportional to its length.
    nonisolated static func replay(
        audioURL: URL,
        provider: any ASRProvider,
        context: ASRContext
    ) async -> ProviderOutcome {
        let providerID = provider.id
        let model = provider.displayName
        let chunks: [PCM16Chunk]
        do {
            chunks = try ArchivedAudioReader.pcm16Chunks(from: audioURL)
        } catch {
            return .failure(providerID: providerID, model: model, error: error)
        }
        let totalBytes = chunks.reduce(0) { $0 + $1.data.count }
        let deadline = HistoryRetranscriptionPolicy.deadlineNanoseconds(pcmByteCount: totalBytes, isRealtimeCloud: true)

        let task = Task<ProviderOutcome, Never>(priority: .userInitiated) {
            do {
                try await provider.prepare(context: context)
                try await provider.startUtterance(id: UUID(), context: context, eventHandler: { _ in })
                let startedAt = DispatchTime.now().uptimeNanoseconds
                var sent = 0
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    try await provider.send(chunk)
                    sent += chunk.data.count
                    if index + 1 < chunks.count {
                        let now = DispatchTime.now().uptimeNanoseconds
                        let elapsed = now >= startedAt ? now - startedAt : UInt64.max
                        let pacing = HistoryRetranscriptionPolicy.cloudReplayPacingNanoseconds(
                            cumulativePCMByteCount: sent,
                            elapsedNanoseconds: elapsed
                        )
                        if pacing > 0 { try await Task.sleep(nanoseconds: pacing) }
                    }
                }
                return .success(try await provider.finalize())
            } catch is CancellationError {
                return .failure(providerID: providerID, model: model, error: CancellationError(), terminationReason: .cancelled)
            } catch {
                await provider.cancel()
                return .failure(providerID: providerID, model: model, error: error)
            }
        }
        switch await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: deadline,
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
                error: ASRProviderError.timeout("重新转写超过 \(deadline / 1_000_000_000) 秒截止"),
                terminationReason: .timedOut
            )
        }
    }
}

enum ConnectionTester {
    /// Sends half a second of silence and waits for the final. A wrong key
    /// or region fails here with the provider's own error message.
    static func test(providerID: String) async -> String {
        guard let provider = MobileEnvironment.makeProvider(id: providerID) else { return "未知服务" }
        let silence = PCM16Chunk(
            sequence: 1,
            data: Data(count: 16_000),
            capturedAt: Date(),
            sampleRate: 16_000,
            channels: 1
        )
        let context = ASRContext.personal(terms: [])
        let task = Task<String, Never> {
            do {
                try await provider.startUtterance(id: UUID(), context: context, eventHandler: { _ in })
                try await provider.send(silence)
                _ = try await provider.finalize()
                await provider.cancel()
                return "连接正常"
            } catch {
                await provider.cancel()
                return error.localizedDescription
            }
        }
        switch await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: 15_000_000_000,
            onTimeout: { await provider.cancel() }
        ) {
        case .completed(let message): return message
        case .timedOut: return "15 秒内没有响应"
        }
    }
}
