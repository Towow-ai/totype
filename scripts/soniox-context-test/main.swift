import Foundation

@main
enum SonioxContextTest {
    static func main() throws {
        try testServerErrorFixtures()
        let builtInTerms = (1...56).map { "built-in-\($0)" }
        let personalTerms = (1...20).map { "personal-term-\($0)" }
        let negativeTerms = (1...20).map { "absent-term-\($0)" }
        let ranked = ContextBudgeter.select(
            candidates: builtInTerms + personalTerms,
            builtInTerms: builtInTerms,
            capacity: 2_000
        )
        let context = ASRContext.personal(
            terms: ranked.selectedTerms,
            instructions: "逐字听写，不要改写。"
        )
        let json = try SonioxProvider.configurationJSONForTesting(context: context)
        let data = try require(json.data(using: .utf8), "Soniox 配置不是 UTF-8")
        let root = try require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Soniox 配置不是 JSON 对象"
        )
        let contextObject = try require(root["context"] as? [String: Any], "缺少 context 对象")
        let sentTerms = try require(contextObject["terms"] as? [String], "缺少 context.terms")

        let expectedCount = personalTerms.count + builtInTerms.count
        try check(sentTerms.count == expectedCount, "Soniox 应发送全部 76 个术语，不再固定截到 50")
        try check(Array(sentTerms.prefix(personalTerms.count)) == personalTerms, "20 个人术语应全部优先发送")
        try check(Set(personalTerms).isSubset(of: Set(sentTerms)), "正样本个人术语不得丢失")
        try check(Set(negativeTerms).isDisjoint(with: Set(sentTerms)), "负样本不得被凭空注入")
        try check(Array(sentTerms.dropFirst(personalTerms.count)) == builtInTerms, "内置术语应按稳定顺序完整发送")
        let oversized = (1...400).map { "overflow-term-\($0)" }
        let bounded = SonioxProvider.boundedContextTerms(oversized)
        try check(bounded.count == SonioxProvider.maximumContextTerms, "超长术语表应按数量上限截断")
        try check(bounded == Array(oversized.prefix(bounded.count)), "截断必须保持原有优先顺序")
        let longTerms = (1...150).map { _ in String(repeating: "长", count: 80) }
        let boundedLong = SonioxProvider.boundedContextTerms(longTerms)
        try check(boundedLong.reduce(0) { $0 + $1.count + 3 } <= SonioxProvider.maximumContextTermCharacters, "术语总字符数必须留在 Soniox context 上限内")
        try check(Set(sentTerms).count == sentTerms.count, "Soniox 术语不得重复")

        print("soniox context test: 20 positive and 20 negative routing fixtures passed")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message: message) }
        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    /// Offline fixtures shaped like the 2026-10-01 incident frame (the
    /// request_id is synthetic). Never calls the paid API.
    private static func testServerErrorFixtures() throws {
        let balance = Data(#"{"error_code":402,"error_type":"organization_balance_exhausted","error_message":"Organization balance exhausted. Please either add funds manually or enable autopay.","more_info":"https://soniox.com/docs/api-reference/errors#organization-balance-exhausted","request_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        let balanceError = try require(SonioxProvider.serverErrorForTesting(balance), "余额错误帧未被识别")
        try check(ProviderFailureKind.of(balanceError) == .billing, "organization_balance_exhausted 帧归为 billing")
        try check(balanceError.localizedDescription.contains("organization_balance_exhausted"), "错误描述保留 error_type")
        try check(ProviderFailureClassifier.classify(message: balanceError.localizedDescription) == .billing, "落入历史的文本仍可归为 billing")

        let key = Data(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Incorrect API key provided.","request_id":"r"}"#.utf8)
        let keyError = try require(SonioxProvider.serverErrorForTesting(key), "鉴权错误帧未被识别")
        try check(ProviderFailureKind.of(keyError) == .auth, "unauthenticated 帧归为 auth")

        let busy = Data(#"{"error_code":503,"error_type":"service_unavailable","error_message":"Cannot continue request (code 1). Please restart the request.","request_id":"r"}"#.utf8)
        let busyError = try require(SonioxProvider.serverErrorForTesting(busy), "503 帧未被识别")
        try check(ProviderFailureKind.of(busyError) == .transient, "service_unavailable 帧仍是 transient")

        try check(SonioxProvider.serverErrorForTesting(Data(#"{"tokens":[],"finished":true}"#.utf8)) == nil, "正常结果帧不是错误")
        try check(ProviderFailureKind.of(ASRProviderError.timeout("x")) == .transient, "会话截止超时归为 transient")
        try check(ProviderFailureKind.of(ASRProviderError.missingAPIKey("Soniox")) == .auth, "缺少 Key 归为 auth")
        print("ok  Soniox error frames classify billing/auth/transient offline")
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
