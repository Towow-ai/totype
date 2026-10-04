import Foundation

/// The one-line reason the keyboard shows next to "没插入" / "仍未成功".
/// Provider messages ("等待超时：Soniox 连接配置超过 5000 ms", Aliyun's
/// English errors) stay in the session log and the in-app notice; the
/// keyboard only says what the user can act on.
enum FailureCopy {
    static func short(_ outcomes: [ProviderOutcome?], offline: Bool) -> String {
        if offline { return "没有网络" }
        let failed = outcomes.compactMap { $0 }.filter { !$0.isUsable }
        let kinds = failed.compactMap(\.failureKind)
        if kinds.contains(.transient) { return "网络不稳，识别服务没响应" }
        if kinds.contains(.billing) { return "识别服务余额不足" }
        if kinds.contains(.auth) { return "API Key 无效" }
        if failed.contains(where: { $0.errorMessage != nil }) { return "识别服务出错" }
        return "没有识别出文字"
    }
}
