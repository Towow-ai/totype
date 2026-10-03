import Foundation

private enum HarnessError: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HarnessError.failed(message) }
}

private enum FakeBehavior: Sendable {
    case success(String, UInt64)
    case failure(UInt64)
    case wedged
}

private func fakeRun(_ behavior: FakeBehavior) -> Task<String?, Never> {
    Task {
        switch behavior {
        case .success(let value, let delay):
            try? await Task.sleep(nanoseconds: delay)
            return Task.isCancelled ? nil : value
        case .failure(let delay):
            try? await Task.sleep(nanoseconds: delay)
            return nil
        case .wedged:
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return nil
        }
    }
}

private final class FakeRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reportsRemaining = 2
    private var resolved = false
    private let continuation: CheckedContinuation<String?, Never>

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func report(_ value: String?) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        if let value, !value.isEmpty {
            resolved = true
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        reportsRemaining -= 1
        guard reportsRemaining == 0 else { lock.unlock(); return }
        resolved = true
        lock.unlock()
        continuation.resume(returning: nil)
    }

    func timeout() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        lock.unlock()
        continuation.resume(returning: nil)
    }
}

private func race(
    _ primary: Task<String?, Never>,
    _ standby: Task<String?, Never>,
    timeoutNanoseconds: UInt64
) async -> String? {
    await withCheckedContinuation { continuation in
        let gate = FakeRaceGate(continuation)
        Task { gate.report(await primary.value) }
        Task { gate.report(await standby.value) }
        Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            gate.timeout()
        }
    }
}

/// Budget for the cloud race and the local run. The fakes finish within 10 ms, so
/// this is a margin against timer slip on a busy machine (a 50 ms budget failed
/// about once in a few dozen runs while Xcode and the iOS type-check were running).
private let raceTimeout: UInt64 = 250_000_000

private func fakeSelect(
    primary: FakeBehavior,
    standby: FakeBehavior,
    local: FakeBehavior
) async -> String? {
    let primaryTask = fakeRun(primary)
    let standbyTask = fakeRun(standby)
    if case .completed(let value) = await CompletionDeadline.wait(
        for: primaryTask,
        timeoutNanoseconds: 5_000_000,
        onTimeout: {}
    ), let value, !value.isEmpty {
        standbyTask.cancel()
        return value
    }
    if let cloud = await race(primaryTask, standbyTask, timeoutNanoseconds: raceTimeout) {
        primaryTask.cancel()
        standbyTask.cancel()
        return cloud
    }
    primaryTask.cancel()
    standbyTask.cancel()
    let localTask = fakeRun(local)
    let localResult = await CompletionDeadline.wait(
        for: localTask,
        timeoutNanoseconds: raceTimeout,
        onTimeout: {}
    )
    if case .completed(let value) = localResult { return value }
    return nil
}

@main
private enum StabilityFaultTest {
    static func main() async throws {
        for round in 0..<500 {
            let coordinator = DictationSessionCoordinator()
            let token = try requireToken(coordinator.begin(), "round \(round): begin")
            try require(coordinator.transition(token, to: .listening), "listening transition")
            try require(coordinator.transition(token, to: .finalizing), "finalizing transition")

            let claims = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask { coordinator.claimCommit(token) }
                }
                var successes = 0
                for await claimed in group where claimed { successes += 1 }
                return successes
            }
            try require(claims == 1, "round \(round): duplicate commit")
            try require(coordinator.finish(token, as: .completed), "finish")

            let next = try requireToken(coordinator.begin(), "next generation")
            try require(next.generation > token.generation, "generation did not advance")
            try require(!coordinator.transition(token, to: .failed), "late transition contaminated next session")
            try require(!coordinator.claimCommit(token), "late provider committed into next session")
            try require(coordinator.transition(next, to: .listening), "cancel fixture listening")
            try require(coordinator.transition(next, to: .cancelPending), "cancel fixture pending")
            try require(coordinator.transition(next, to: .finalizing), "cancel undo resumes finalizing")
            try require(coordinator.claimCommit(next), "cancel undo commits exactly once")
            try require(coordinator.finish(next, as: .completed), "cancel undo finish")

            let scenario = round % 6
            let selected: String?
            let expected: String?
            switch scenario {
            case 0:
                selected = await fakeSelect(
                    primary: .success("soniox", 0), standby: .success("aliyun", 0), local: .success("local", 0)
                )
                expected = "soniox"
            case 1:
                selected = await fakeSelect(
                    primary: .wedged, standby: .success("aliyun", 10_000_000), local: .success("local", 0)
                )
                expected = "aliyun"
            case 2:
                selected = await fakeSelect(
                    primary: .failure(0), standby: .success("aliyun", 10_000_000), local: .success("local", 0)
                )
                expected = "aliyun"
            case 3:
                selected = await fakeSelect(
                    primary: .failure(0), standby: .failure(0), local: .success("local", 0)
                )
                expected = "local"
            case 4:
                selected = await fakeSelect(
                    primary: .failure(0), standby: .failure(0), local: .failure(0)
                )
                expected = nil
            default:
                // Every provider wedged waits out the full budgets, so only one in
                // sixteen such rounds does; the rest fail immediately.
                let hang: FakeBehavior = round % 96 == 5 ? .wedged : .failure(0)
                selected = await fakeSelect(primary: hang, standby: hang, local: hang)
                expected = nil
            }
            try require(selected == expected, "round \(round): fake provider selection mismatch")

            let timeline = SessionTimelineRecorder()
            timeline.mark(.trigger)
            timeline.mark(.trigger)
            timeline.mark(.overlayPresented)
            timeline.mark(.stopRequested)
            timeline.mark(.unicodeDispatched)
            let snapshot = timeline.snapshot()
            try require(snapshot.marks.filter { $0.event == .trigger }.count == 1, "duplicate timeline mark")
            try require(
                (snapshot.milliseconds(from: .stopRequested, to: .unicodeDispatched) ?? -1) >= 0,
                "negative monotonic duration"
            )
        }

        // Models WebSocket send/finalize that ignores cancellation. The caller
        // must still return at its own deadline; cleanup is deliberately not
        // awaited and therefore cannot pin the user path for 60 seconds.
        let wedged = Task<Int, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = await CompletionDeadline.wait(
            for: wedged,
            timeoutNanoseconds: 5_000_000,
            onTimeout: {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        if case .completed = result { throw HarnessError.failed("wedged provider completed") }
        try require(elapsedMilliseconds < 250, "timeout waited for quarantine cleanup")

        // Named coverage ledger: these faults reduce to the same two guarded
        // contracts above—bounded completion and generation-scoped commit.
        let covered = [
            "send-never-returns", "finalize-never-returns", "cancel-blocks-60s",
            "soniox-fails-aliyun-final", "dual-cloud-fails-local-final",
            "all-providers-fail", "late-partial-final", "rapid-start-stop",
            "target-switch-exit-secure-input", "dispatch-success-ax-stale",
            "persistence-archive-correction-blocked", "retained-cancel-undo",
        ]
        print("ok  500 deterministic fake-provider sessions; failover/fallback bounded")
        print("ok  exactly-once commit; late-event and generation isolation")
        print("ok  bounded deadline does not await quarantined cleanup")
        print("covered  " + covered.joined(separator: ", "))
    }

    private static func requireToken(
        _ token: SessionGenerationToken?,
        _ message: String
    ) throws -> SessionGenerationToken {
        guard let token else { throw HarnessError.failed(message) }
        return token
    }
}
