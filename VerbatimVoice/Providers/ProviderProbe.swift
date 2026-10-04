import Foundation

/// Lightweight health check of a provider that is in outage (balance, key).
///
/// Opens one request on a probe-owned provider instance, sends 300 ms of
/// silence and finalizes. Billing and key checks happen before audio is
/// processed, so a rejected account answers at once; a healthy one finalizes
/// an empty transcript for a fraction of a second of billed audio. Never on
/// the user path: callers fire it off and only read the result.
enum ProviderProbe {
    static let silenceBytes = 9_600
    static let deadlineNanoseconds: UInt64 = 8_000_000_000

    static func run(
        _ provider: any ASRProvider,
        context: ASRContext,
        timeoutNanoseconds: UInt64 = deadlineNanoseconds
    ) async -> ProviderProbeResult {
        let task = Task<ProviderProbeResult, Never>(priority: .utility) {
            do {
                try await provider.startUtterance(id: UUID(), context: context, eventHandler: { _ in })
                try await provider.send(PCM16Chunk(
                    sequence: 1,
                    data: Data(repeating: 0, count: silenceBytes),
                    capturedAt: Date(),
                    sampleRate: 16_000,
                    channels: 1
                ))
                _ = try await provider.finalize()
                return .available
            } catch {
                let kind: ProviderFailureKind = error is CancellationError ? .other : .of(error)
                return .failed(kind: kind, message: error.localizedDescription)
            }
        }
        let result: ProviderProbeResult
        switch await CompletionDeadline.wait(
            for: task,
            timeoutNanoseconds: timeoutNanoseconds,
            onTimeout: {
                task.cancel()
                await provider.cancel()
            }
        ) {
        case .completed(let outcome):
            result = outcome
        case .timedOut:
            result = .failed(kind: .transient, message: String(localized: "探测超时"))
        }
        await provider.cancel()
        return result
    }
}
