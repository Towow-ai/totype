import AVFoundation
import Darwin
import Foundation

@main
struct CloudLiveProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count >= 2 else {
            throw ProbeError("usage: cloud-live-probe <soniox|aliyun> [fixture.wav]")
        }

        let providerName = CommandLine.arguments[1]
        // The production app migrated credentials out of Keychain so repeated
        // local diagnostics cannot trigger another authorization prompt.
        let secrets = PersonalSecretStore()

        switch providerName {
        case "soniox":
            guard let key = try secrets.get(account: "soniox-api-key"), !key.isEmpty else {
                throw ProbeError("Soniox key is missing")
            }
            let provider = SonioxProvider(apiKeyProvider: { key }, warmTTLProvider: { 0 })
            trace("soniox prepare begin")
            try await provider.prepare(context: ASRContext.personal(terms: ["Codex"]))
            trace("soniox prepare end")
            try await provider.startUtterance(
                id: UUID(),
                context: ASRContext.personal(terms: ["Codex"]),
                eventHandler: { event in printEvent(event) }
            )
            trace("soniox start end")
            if CommandLine.arguments.count >= 3 {
                let pcm = try loadPCM16(URL(fileURLWithPath: CommandLine.arguments[2]))
                try await streamLikeMicrophone(pcm, to: provider)
            } else {
                try await provider.send(silence(milliseconds: 500))
                try await Task.sleep(for: .milliseconds(500))
            }
            trace("soniox audio sent")
            trace("soniox finalize begin")
            let finalizeStarted = Date()
            let result = try await provider.finalize()
            let metrics = result.transportMetrics
            print(
                "result provider=soniox text_length=\(result.text.count) "
                    + "finalize_wall_ms=\(Int(Date().timeIntervalSince(finalizeStarted) * 1_000)) "
                    + "frames=\(metrics?.audioFrameCount ?? -1) "
                    + "bytes=\(metrics?.audioBytesSent ?? -1) "
                    + "max_send_ms=\(metrics?.maxSendLatencyMilliseconds ?? -1) "
                    + "backpressure=\(metrics?.backpressureEventCount ?? -1) "
                    + "recoveries=\(metrics?.recoveryAttemptCount ?? -1) "
                    + "connect_ms=\(metrics?.connectionSetupLatencyMilliseconds ?? -1)"
            )
            await provider.cancel()

        case "aliyun":
            guard let key = try secrets.get(account: "aliyun-bailian-api-key"), !key.isEmpty else {
                throw ProbeError("Aliyun key is missing")
            }
            let region = AliyunRegion(
                rawValue: UserDefaults.standard.string(forKey: "aliyunRegion") ?? ""
            ) ?? .beijing
            let provider = AliyunASRProvider(apiKeyProvider: { key }, regionProvider: { region })
            guard CommandLine.arguments.count >= 3 else {
                throw ProbeError("Aliyun probe requires a WAV fixture")
            }
            let pcm = try loadPCM16(URL(fileURLWithPath: CommandLine.arguments[2]))
            try await provider.prepare(context: ASRContext.personal(terms: []))
            try await provider.startUtterance(
                id: UUID(),
                context: ASRContext.personal(terms: []),
                eventHandler: { event in printEvent(event) }
            )
            var sequence: Int64 = 0
            let chunkBytes = 3_200
            for offset in stride(from: 0, to: pcm.count, by: chunkBytes) {
                sequence += 1
                let end = min(offset + chunkBytes, pcm.count)
                try await provider.send(PCM16Chunk(
                    sequence: sequence,
                    data: pcm.subdata(in: offset..<end),
                    capturedAt: Date(),
                    sampleRate: 16_000,
                    channels: 1
                ))
                try await Task.sleep(for: .milliseconds(20))
            }
            let result = try await provider.finalize()
            print("result provider=aliyun region=\(region.rawValue) text=\(result.text)")
            await provider.cancel()

        default:
            throw ProbeError("unknown provider: \(providerName)")
        }
    }

    private static func silence(milliseconds: Int) -> PCM16Chunk {
        PCM16Chunk(
            sequence: 1,
            data: Data(repeating: 0, count: 16_000 * 2 * milliseconds / 1_000),
            capturedAt: Date(),
            sampleRate: 16_000,
            channels: 1
        )
    }

    private static func streamLikeMicrophone(
        _ pcm: Data,
        to provider: SonioxProvider
    ) async throws {
        // The app's 512-frame 48 kHz tap becomes roughly 342 bytes after the
        // 16 kHz mono conversion. Replaying at the same cadence exercises the
        // exact high-message-count path that previously accumulated backlog.
        let chunkBytes = 342
        var sequence: Int64 = 0
        for offset in stride(from: 0, to: pcm.count, by: chunkBytes) {
            sequence += 1
            let end = min(offset + chunkBytes, pcm.count)
            let data = pcm.subdata(in: offset..<end)
            try await provider.send(PCM16Chunk(
                sequence: sequence,
                data: data,
                capturedAt: Date(),
                sampleRate: 16_000,
                channels: 1
            ))
            let durationNanoseconds = UInt64(data.count) * 1_000_000_000 / 32_000
            try await Task.sleep(nanoseconds: durationNanoseconds)
        }
    }

    private static func extractPCM16(fromWAV wav: Data) throws -> Data {
        let marker = Data("data".utf8)
        guard wav.count >= 12,
              String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF",
              let markerRange = wav.range(of: marker, options: [], in: 12..<min(wav.count, 8_192)),
              markerRange.upperBound + 4 <= wav.count else {
            throw ProbeError("invalid WAV fixture")
        }
        let sizeOffset = markerRange.upperBound
        let declaredSize = Int(wav[sizeOffset])
            | (Int(wav[sizeOffset + 1]) << 8)
            | (Int(wav[sizeOffset + 2]) << 16)
            | (Int(wav[sizeOffset + 3]) << 24)
        let audioStart = sizeOffset + 4
        let audioEnd = min(wav.count, audioStart + declaredSize)
        guard audioEnd > audioStart else { throw ProbeError("empty WAV fixture") }
        return wav.subdata(in: audioStart..<audioEnd)
    }

    private static func loadPCM16(_ url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "wav" {
            return try extractPCM16(fromWAV: Data(contentsOf: url))
        }

        let input = try AVAudioFile(forReading: url)
        let converter = PCMConverter()
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: 8_192
        ) else {
            throw ProbeError("cannot allocate audio decode buffer")
        }
        var pcm = Data()
        while input.framePosition < input.length {
            let remaining = AVAudioFrameCount(
                min(Int64(buffer.frameCapacity), input.length - input.framePosition)
            )
            try input.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            pcm.append(try converter.convert(buffer))
        }
        return pcm
    }

    private static func printEvent(_ event: ASREvent) {
        switch event {
        case .connected(let providerID):
            print("event connected provider=\(providerID)")
        case .partial(let providerID, let text):
            print("event partial provider=\(providerID) text_length=\(text.count)")
        case .finalized(let providerID, let text):
            print("event finalized provider=\(providerID) text_length=\(text.count)")
        case .warning(let providerID, let message):
            print("event warning provider=\(providerID) message=\(message)")
        case .failed(let providerID, let message):
            print("event failed provider=\(providerID) message=\(message)")
        }
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data("trace \(message)\n".utf8))
    }

    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
