import Foundation

@main
struct CompletionDeadlineTest {
    static func main() async {
        let quick = Task<Int, Never> { 42 }
        let quickResult = await CompletionDeadline.wait(
            for: quick,
            timeoutNanoseconds: 1_000_000_000,
            onTimeout: { quick.cancel() }
        )
        guard case .completed(42) = quickResult else {
            fputs("FAIL: 快速任务被错误判为超时\n", stderr)
            exit(1)
        }

        let hanging = Task<Int, Never> {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {}
            return 7
        }
        let started = Date()
        let timeoutResult = await CompletionDeadline.wait(
            for: hanging,
            timeoutNanoseconds: 80_000_000,
            onTimeout: {
                hanging.cancel()
                // WebSocket cancellation can itself take time. The caller's
                // deadline must not wait for cleanup to return.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        guard case .timedOut = timeoutResult, elapsed < 0.75 else {
            fputs("FAIL: 超时结果仍被慢清理阻塞\n", stderr)
            exit(1)
        }

        print("completion deadline checks passed")
    }
}
