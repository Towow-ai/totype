import Foundation

// Runs inside a copy of a lite app bundle (scripts/local_model_download_test.sh):
// downloads the local model into a temporary data directory, checks it, then
// transcribes the fixture with the downloaded runtime.
//
//   main <fixture.wav> <expected phrase> [--cancel-first]
//
// A non-bundled `models` directory is injected, so nothing under the real
// ~/Library/Application Support is read or written.

@main
struct LocalModelDownloadTest {
    static func main() async {
        do {
            try await run()
            print("ok  local model download, verification and transcription")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw Failure("usage: main <fixture.wav> <phrase> [--cancel-first]") }
        let fixture = URL(fileURLWithPath: args[1])
        let phrase = args[2]
        let cancelFirst = args.contains("--cancel-first")

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-model-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let models = LocalModelFiles.downloadedDirectory(supportDirectory: support)
        print("identity: \(AppIdentity.bundleID) / \(AppIdentity.dataDirectoryName)")
        print("models directory: \(models.path)")

        // Without a bundled copy and before the download nothing is available.
        let bundled = LocalModelFiles.bundledDirectory()
        guard LocalModelFiles.current(bundled: bundled, downloaded: models) == nil else {
            throw Failure("expected a lite bundle with no runtime")
        }
        let store = LocalModelStore(modelsDirectory: models, bundledDirectory: bundled)
        guard store.status == .notInstalled else { throw Failure("initial status \(store.status)") }

        if cancelFirst {
            store.startDownload()
            let begin = Date()
            while true {
                try await Task.sleep(nanoseconds: 200_000_000)
                if case .downloading(let progress) = store.status, progress.fraction > 0.03 { break }
                if Date().timeIntervalSince(begin) > 120 { throw Failure("no progress within 120 s: \(store.status)") }
            }
            store.cancelDownload()
            guard store.status == .notInstalled else { throw Failure("status after cancel \(store.status)") }
            print("cancelled mid-download; status \(store.status)")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        store.startDownload()
        var lastDecile = -1
        let started = Date()
        while true {
            try await Task.sleep(nanoseconds: 250_000_000)
            switch store.status {
            case .downloading(let progress):
                let decile = Int(progress.fraction * 10)
                if decile != lastDecile {
                    lastDecile = decile
                    print("downloading \(Int(progress.fraction * 100))%  \(LocalModelFiles.megabytes(progress.receivedBytes)) / \(LocalModelFiles.megabytes(progress.totalBytes))")
                }
            case .verifying:
                break
            case .installed:
                print("installed after \(Int(Date().timeIntervalSince(started))) s")
                try await verifyInstalled(models: models, bundled: bundled, fixture: fixture, phrase: phrase)
                return
            case .failed(let kind, let message):
                throw Failure("download failed (\(kind)): \(message)")
            case .bundled, .notInstalled:
                throw Failure("unexpected status \(store.status)")
            }
            if Date().timeIntervalSince(started) > 1_200 { throw Failure("timed out: \(store.status)") }
        }
    }

    @MainActor
    static func verifyInstalled(models: URL, bundled: URL?, fixture: URL, phrase: String) async throws {
        let expected: [(String, String)] = [
            (LocalModelFiles.executableName, LocalModelFiles.executableSHA256),
            (LocalModelFiles.modelName, LocalModelFiles.model.sha256),
            (LocalModelFiles.vadName, LocalModelFiles.vad.sha256)
        ]
        for (name, digest) in expected {
            let path = models.appendingPathComponent(name)
            guard try LocalModelStore.sha256(of: path) == digest else { throw Failure("hash mismatch: \(name)") }
        }
        let executable = models.appendingPathComponent(LocalModelFiles.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure("runtime is not executable") }
        let quarantine = getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard quarantine < 0 else { throw Failure("runtime still has the quarantine attribute") }
        guard let current = LocalModelFiles.current(bundled: bundled, downloaded: models), current.source == .downloaded else {
            throw Failure("resolution did not pick the downloaded copy")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: models.path).filter { $0.hasPrefix(".") }
        guard leftovers.isEmpty else { throw Failure("temporary files left behind: \(leftovers)") }
        print("files verified; runtime executable, no quarantine, no leftovers")

        // The same provider the app uses, pointed at the downloaded copy.
        let wav = try Data(contentsOf: fixture)
        guard let dataRange = wav.range(of: Data("data".utf8)) else { throw Failure("fixture has no data chunk") }
        let pcm = wav.subdata(in: (dataRange.upperBound + 4)..<wav.count)
        let provider = LocalSenseVoiceProvider(runtimeDirectory: current.directory)
        let context = ASRContext.personal(terms: [])
        try await provider.startUtterance(id: UUID(), context: context, eventHandler: { _ in })
        try await provider.send(PCM16Chunk(sequence: 0, data: pcm, capturedAt: Date(), sampleRate: 16_000, channels: 1))
        let result = try await provider.finalize()
        print("transcript: \(result.text)")
        guard result.text.contains(phrase) else { throw Failure("transcript lacks \"\(phrase)\"") }
    }
}
