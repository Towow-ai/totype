import Foundation

@main
struct AliyunProtocolTest {
    static func main() throws {
        try testEndpoints()
        try testRunTask()
        try testFinishTask()
        try testServerEvents()
        print("ok  Aliyun qwen-audio 3.0 streaming protocol")
    }

    private static func testEndpoints() throws {
        let beijing = try AliyunRealtimeProtocol.endpoint(region: .beijing)
        let singapore = try AliyunRealtimeProtocol.endpoint(region: .singapore)
        try expect(beijing.host == "dashscope.aliyuncs.com", "unexpected Beijing host")
        try expect(singapore.host == "dashscope-intl.aliyuncs.com", "unexpected Singapore host")
        try expect(beijing.path == "/api-ws/v1/inference", "wrong WebSocket path")
        try expect(URLComponents(url: beijing, resolvingAgainstBaseURL: false)?.query == nil, "endpoint must not carry the legacy model query")
    }

    private static func testRunTask() throws {
        let context = ASRContext.personal(
            terms: ["Claude Code", "Codex"],
            instructions: String(repeating: "甲", count: 450),
            hotwordWeight: 4
        )
        let object = try jsonObject(AliyunRealtimeProtocol.runTaskJSON(taskID: UUID(), context: context))
        let header = try dictionary(object["header"], "header")
        let payload = try dictionary(object["payload"], "payload")
        let parameters = try dictionary(payload["parameters"], "parameters")
        try expect(header["action"] as? String == "run-task", "wrong run action")
        try expect(header["streaming"] as? String == "duplex", "wrong streaming mode")
        try expect(payload["model"] as? String == "qwen-audio-3.0-asr-flash-streaming", "wrong model")
        try expect(parameters["format"] as? String == "pcm", "wrong audio format")
        try expect(parameters["sample_rate"] as? Int == 16_000, "wrong sample rate")
        try expect(parameters["semantic_punctuation_enabled"] as? Bool == true, "semantic punctuation is off")
        try expect(parameters["language_hints"] as? [String] == ["zh", "en"], "language hints changed")
        let vocabulary = try dictionary(parameters["vocabulary"], "vocabulary")
        try expect(vocabulary["Claude Code"] as? Int == 4, "hotword weight changed")

        let input = try dictionary(payload["input"], "input")
        let messages = try array(input["context"], "context")
        let first = try dictionary(messages.first, "message")
        let content = try array(first["content"], "content")
        let item = try dictionary(content.first, "content item")
        try expect((item["text"] as? String)?.count == 400, "context was not capped at 400 characters")
    }

    private static func testFinishTask() throws {
        let id = UUID()
        let object = try jsonObject(AliyunRealtimeProtocol.finishTaskJSON(taskID: id))
        let header = try dictionary(object["header"], "header")
        try expect(header["action"] as? String == "finish-task", "wrong finish action")
        try expect(header["task_id"] as? String == id.uuidString.lowercased(), "finish task id changed")
    }

    private static func testServerEvents() throws {
        let started = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"task-started","task_id":"task-1"},"payload":{}}"#.utf8))
        try expect(started == .taskStarted(taskID: "task-1"), "task-started changed")

        let partial = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你好","sentence_id":1,"sentence_end":false,"words":[]}}}}"#.utf8))
        try expect(partial == .result(text: "你好", sentenceID: 1, sentenceEnd: false, words: []), "partial result changed")

        let final = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"Claude Code。","sentence_id":2,"sentence_end":true,"words":[{"text":"Claude Code","punctuation":"。","begin_time":10,"end_time":200}]}}}}"#.utf8))
        try expect(final == .result(
            text: "Claude Code。",
            sentenceID: 2,
            sentenceEnd: true,
            words: [AliyunWord(text: "Claude Code", punctuation: "。", beginMilliseconds: 10, endMilliseconds: 200)]
        ), "final words changed")

        let failure = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"task-failed","error_code":"CLIENT_ERROR","error_message":"bad request"},"payload":{}}"#.utf8))
        try expect(failure == .failure(code: "CLIENT_ERROR", message: "bad request"), "server error changed")

        // Offline fixture: account in arrears (2026-10-01 docs wording).
        let arrears = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"task-failed","error_code":"Arrearage","error_message":"Access denied, please make sure your account is in good standing."},"payload":{}}"#.utf8))
        guard case .failure(let code, let message)? = arrears else { throw TestError("Arrearage frame not parsed") }
        try expect(ProviderFailureClassifier.aliyun(code: code, message: message) == .billing, "Arrearage must classify as billing")
        let rejection = ProviderRejection(failureKind: .billing, message: "Arrearage: \(message)")
        try expect(ProviderFailureKind.of(rejection) == .billing, "classified rejection keeps its kind")
        let badKey = AliyunRealtimeProtocol.parseServerEvent(Data(#"{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"Invalid API-key provided."},"payload":{}}"#.utf8))
        guard case .failure(let keyCode, let keyMessage)? = badKey else { throw TestError("InvalidApiKey frame not parsed") }
        try expect(ProviderFailureClassifier.aliyun(code: keyCode, message: keyMessage) == .auth, "InvalidApiKey must classify as auth")
    }

    private static func jsonObject(_ string: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try dictionary(object, "root")
    }

    private static func dictionary(_ value: Any?, _ name: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw TestError("missing dictionary: \(name)")
        }
        return value
    }

    private static func array(_ value: Any?, _ name: String) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw TestError("missing array: \(name)")
        }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestError(message) }
    }

    private struct TestError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
