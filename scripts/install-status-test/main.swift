import Foundation

@main
struct InstallStatusSelfTest {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-install-status-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reporter = InstallRuntimeStatusReporter(baseDirectory: root, startHeartbeat: false)
        let fileURL = root.appendingPathComponent(InstallRuntimeStatusReporter.fileName)
        let decoder = JSONDecoder()

        func read() throws -> InstallRuntimeStatus {
            try decoder.decode(InstallRuntimeStatus.self, from: Data(contentsOf: fileURL))
        }

        var status = try read()
        precondition(status.installProtocolVersion == 1)
        precondition(status.pid == getpid())
        precondition(status.state == .idle)
        precondition(!status.launchID.uuidString.isEmpty)

        reporter.update(dictationState: .listening)
        status = try read()
        precondition(status.state == .listening)

        reporter.update(dictationState: .finalizing)
        status = try read()
        precondition(status.state == .finalizing)

        reporter.update(dictationState: .inserting)
        status = try read()
        precondition(status.state == .inserting)

        reporter.update(dictationState: .preview)
        status = try read()
        precondition(status.state == .preview)

        reporter.update(dictationState: .failed)
        status = try read()
        precondition(status.state == .failed)

        reporter.beginCriticalPersistence()
        reporter.update(dictationState: .idle)
        status = try read()
        precondition(status.state == .criticalPersist)

        reporter.endCriticalPersistence()
        status = try read()
        precondition(status.state == .idle)

        reporter.stop()
        precondition(!FileManager.default.fileExists(atPath: fileURL.path))
        print("Install runtime status self-test passed")
    }
}
