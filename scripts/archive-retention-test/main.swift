import Foundation

private enum ArchiveTestError: Error {
    case failed(String)
}

@main
private enum ArchiveRetentionTest {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-archive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = SessionAudioArchive()
        let first = Data(repeating: 0x11, count: 3_200)
        let second = Data(repeating: 0x22, count: 6_400)
        try await archive.start(sessionID: UUID(), preRoll: first, directory: root)
        try await archive.append(second)
        guard let url = await archive.finishAndCompress() else {
            throw ArchiveTestError.failed("archive did not finish")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveTestError.failed("archive file missing")
        }

        let chunks = try ArchivedAudioReader.pcm16Chunks(from: url)
        let bytes = chunks.reduce(0) { $0 + $1.data.count }
        guard bytes == first.count + second.count else {
            throw ArchiveTestError.failed("round trip bytes \(bytes), expected \(first.count + second.count)")
        }
        guard chunks.allSatisfy({ $0.sampleRate == 16_000 && $0.channels == 1 }) else {
            throw ArchiveTestError.failed("decoded format changed")
        }
        print("archive retention round trip passed: \(bytes) PCM bytes")
    }
}
