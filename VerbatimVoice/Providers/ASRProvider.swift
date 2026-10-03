import Foundation

protocol ASRProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }

    func prepare(context: ASRContext) async throws
    func startUtterance(
        id: UUID,
        context: ASRContext,
        eventHandler: @escaping @Sendable (ASREvent) -> Void
    ) async throws
    func send(_ chunk: PCM16Chunk) async throws
    func finalize() async throws -> TranscriptResult
    func cancel() async
}

/// A cloud provider that reports transport liveness (connected, first/last
/// server frame, failures) into a probe owned by the current session. The
/// session attaches its probe before `startUtterance`; a provider detaches it
/// when the utterance ends so a reused instance never writes into an older
/// session's record.
protocol ProviderLivenessReporting: ASRProvider {
    func attachLiveness(_ probe: ProviderLivenessProbe) async
}

enum ASRProviderError: LocalizedError {
    case missingAPIKey(String)
    case notPrepared
    case invalidState(String)
    case connectionFailed(String)
    case server(String)
    case timeout(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): return "尚未设置\(provider) API Key"
        case .notPrepared: return "转写 Provider 尚未准备完成"
        case .invalidState(let message): return "Provider 状态错误：\(message)"
        case .connectionFailed(let message): return "连接失败：\(message)"
        case .server(let message): return "服务端错误：\(message)"
        case .timeout(let message): return "等待超时：\(message)"
        case .unavailable(let message): return message
        }
    }
}

/// An error that already knows whether retrying can help. Providers throw
/// these for server rejections they can identify (Soniox `error_type`,
/// Aliyun `error_code`, a rejected WebSocket handshake).
protocol ClassifiedProviderError: LocalizedError {
    var failureKind: ProviderFailureKind { get }
}

struct ProviderRejection: ClassifiedProviderError {
    let failureKind: ProviderFailureKind
    let message: String

    var errorDescription: String? { "服务端错误：\(message)" }
}

extension ProviderFailureKind {
    /// Classifies any error a provider task can end with. Session-level
    /// deadlines and dropped connections are transient; a missing key is auth.
    static func of(_ error: Error) -> ProviderFailureKind {
        if let classified = error as? ClassifiedProviderError { return classified.failureKind }
        if error is CancellationError { return .other }
        if error is URLError { return .transient }
        if let provider = error as? ASRProviderError {
            switch provider {
            case .missingAPIKey: return .auth
            case .connectionFailed, .timeout: return .transient
            case .server(let message): return ProviderFailureClassifier.classify(message: message)
            case .notPrepared, .invalidState, .unavailable: return .other
            }
        }
        return ProviderFailureClassifier.classify(message: error.localizedDescription)
    }
}
