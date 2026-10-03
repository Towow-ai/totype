import AVFoundation
import Darwin
import Foundation

@main
struct HistoryRetranscriptionProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("history probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 3,
              let sessionID = UUID(uuidString: CommandLine.arguments[2]) else {
            throw ProbeError("usage: history-retranscription-probe <audio.flac> <session-uuid>")
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let chunks = try ArchivedAudioReader.pcm16Chunks(from: audioURL)
        let totalPCMBytes = chunks.reduce(into: 0) { $0 += $1.data.count }
        guard totalPCMBytes > 0 else { throw ProbeError("history audio is empty") }

        let secrets = PersonalSecretStore()
        guard let key = try secrets.get(account: "soniox-api-key"), !key.isEmpty else {
            throw ProbeError("Soniox key is missing")
        }
        let lexicon = try await PersonalLexiconStore().load()
        let terms = lexicon
            .filter { $0.state == .confirmed }
            .flatMap { [$0.canonical] + $0.aliases }
        let context = ASRContext.personal(terms: terms)
        let provider = SonioxProvider(apiKeyProvider: { key }, warmTTLProvider: { 0 })

        try await provider.prepare(context: context)
        try await provider.startUtterance(id: UUID(), context: context) { event in
            if case .warning(_, let message) = event {
                fputs("warning: \(message)\n", stderr)
            }
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        var replayedPCMBytes = 0
        let progressStride = max(1, chunks.count / 20)
        for (index, chunk) in chunks.enumerated() {
            try await provider.send(chunk)
            replayedPCMBytes += chunk.data.count
            let completed = index + 1
            if completed == chunks.count || completed.isMultiple(of: progressStride) {
                let percent = HistoryRetranscriptionPolicy.progressPercent(
                    completedChunks: completed,
                    totalChunks: chunks.count
                )
                print("history_replay_progress=\(percent)")
            }
            guard completed < chunks.count else { continue }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now >= startedAt ? now - startedAt : UInt64.max
            let pacing = HistoryRetranscriptionPolicy.cloudReplayPacingNanoseconds(
                cumulativePCMByteCount: replayedPCMBytes,
                elapsedNanoseconds: elapsed
            )
            if pacing > 0 { try await Task.sleep(nanoseconds: pacing) }
        }

        let result = try await provider.finalize()
        await provider.cancel()
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProbeError("Soniox returned an empty transcript")
        }
        try await HistoryStore.shared.appendRevision(
            sessionID: sessionID,
            revision: TranscriptRevision(
                id: UUID(),
                createdAt: Date(),
                source: .retranscription,
                providerID: provider.id,
                model: result.model,
                text: result.text,
                error: nil
            )
        )
        print("history_revision_appended session=\(sessionID.uuidString) text_length=\(result.text.count)")
    }
}

private struct ProbeError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
