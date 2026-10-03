import Foundation

public enum CompletionDeadlineResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

private final class CompletionDeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private let continuation: CheckedContinuation<CompletionDeadlineResult<Value>, Never>

    init(_ continuation: CheckedContinuation<CompletionDeadlineResult<Value>, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: CompletionDeadlineResult<Value>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        lock.unlock()
        continuation.resume(returning: result)
        return true
    }
}

/// Adds an end-to-end deadline around an existing unstructured task.
///
/// Timeout cleanup is deliberately detached from the caller-facing result.
/// Closing a wedged WebSocket can itself stall, so a deadline must not wait for
/// the operation it is trying to bound. The gate guarantees that a late task
/// result cannot resume the caller or replace the selected fallback.
public enum CompletionDeadline {
    public static func wait<Value: Sendable>(
        for task: Task<Value, Never>,
        timeoutNanoseconds: UInt64,
        onTimeout: @escaping @Sendable () async -> Void
    ) async -> CompletionDeadlineResult<Value> {
        await withCheckedContinuation { continuation in
            let gate = CompletionDeadlineGate<Value>(continuation)

            Task {
                let value = await task.value
                gate.resolve(.completed(value))
            }

            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard gate.resolve(.timedOut) else { return }

                // Cancellation is synchronous, but provider/socket cleanup is
                // intentionally unstructured so it cannot hold the UI in the
                // finalizing state past the declared deadline.
                task.cancel()
                Task {
                    await onTimeout()
                }
            }
        }
    }
}
