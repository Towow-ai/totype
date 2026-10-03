import Foundation

@main
struct LocalProviderIntegrationTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw TestError("usage: provider-test <runtime-dir> <fixture.wav>")
        }

        let runtime = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let pcm = try extractPCM16(fromWAV: Data(contentsOf: fixture))
        let provider = LocalSenseVoiceProvider(runtimeDirectory: runtime)
        let context = ASRContext.personal(terms: ["Claude Code", "Codex"])

        try await provider.startUtterance(id: UUID(), context: context) { _ in }
        try await provider.send(PCM16Chunk(
            sequence: 1,
            data: pcm,
            capturedAt: Date(),
            sampleRate: 16_000,
            channels: 1
        ))
        let result = try await provider.finalize()

        for literal in ["我我", "不对不对", "不要改我的原话"] {
            guard result.text.contains(literal) else {
                throw TestError("provider result did not preserve \(literal): \(result.text)")
            }
        }
        guard result.providerID == "local-sensevoice" else {
            throw TestError("unexpected provider id: \(result.providerID)")
        }

        print("ok  LocalSenseVoiceProvider end-to-end")
        print("    \(result.text)")
        print("    finalize=\(result.finalizeLatencyMilliseconds ?? -1)ms")
    }

    private static func extractPCM16(fromWAV wav: Data) throws -> Data {
        let marker = Data("data".utf8)
        guard wav.count >= 12,
              String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF",
              let markerRange = wav.range(of: marker, options: [], in: 12..<min(wav.count, 8_192)),
              markerRange.upperBound + 4 <= wav.count else {
            throw TestError("invalid WAV fixture")
        }

        let sizeOffset = markerRange.upperBound
        let declaredSize = Int(wav[sizeOffset])
            | (Int(wav[sizeOffset + 1]) << 8)
            | (Int(wav[sizeOffset + 2]) << 16)
            | (Int(wav[sizeOffset + 3]) << 24)
        let audioStart = sizeOffset + 4
        let audioEnd = min(wav.count, audioStart + declaredSize)
        guard audioEnd > audioStart else { throw TestError("empty WAV fixture") }
        return wav.subdata(in: audioStart..<audioEnd)
    }

    private struct TestError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
