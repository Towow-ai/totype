import XCTest
@testable import VerbatimCore

final class TextJoinPolicyTests: XCTestCase {
    func testRemovesOneChatPeriod() {
        let output = TextJoinPolicy.prepare(
            transcript: "今天就这样。",
            precedingCharacter: nil,
            appKind: .chat,
            configuration: .init(removeTerminalPeriodInChat: true)
        )
        XCTAssertEqual(output, "今天就这样")
    }

    func testKeepsQuestionMarkAndEllipsis() {
        let config = TextJoinConfiguration(removeTerminalPeriodInChat: true)
        XCTAssertEqual(TextJoinPolicy.prepare(transcript: "真的吗？", precedingCharacter: nil, appKind: .chat, configuration: config), "真的吗？")
        XCTAssertEqual(TextJoinPolicy.prepare(transcript: "等等...", precedingCharacter: nil, appKind: .chat, configuration: config), "等等...")
    }

    func testKeepsVersionPeriod() {
        let output = TextJoinPolicy.prepare(
            transcript: "版本是 1.0.",
            precedingCharacter: nil,
            appKind: .chat,
            configuration: .init(removeTerminalPeriodInChat: true)
        )
        XCTAssertEqual(output, "版本是 1.0.")
    }

    func testAddsSpaceBetweenLatinRuns() {
        let output = TextJoinPolicy.prepare(
            transcript: "Code is ready",
            precedingCharacter: "e",
            appKind: .document,
            configuration: .init(addSpaceBetweenLatinRuns: true)
        )
        XCTAssertEqual(output, " Code is ready")
    }

    func testLiteralDefaultsDoNotChangePunctuationOrJoinSpacing() {
        let output = TextJoinPolicy.prepare(
            transcript: "Code is ready。",
            precedingCharacter: "e",
            appKind: .chat,
            configuration: .init()
        )
        XCTAssertEqual(output, "Code is ready。")
    }

    func testDoesNotAddSpaceAfterCJK() {
        let output = TextJoinPolicy.prepare(
            transcript: "Claude Code",
            precedingCharacter: "是",
            appKind: .document,
            configuration: .init()
        )
        XCTAssertEqual(output, "Claude Code")
    }

    func testAppendsTrailingSpaceAfterEnglishWhenEnabled() {
        let output = TextJoinPolicy.prepare(
            transcript: "Claude Code",
            precedingCharacter: nil,
            appKind: .chat,
            configuration: .init(appendTrailingSpaceAfterLatin: true)
        )
        XCTAssertEqual(output, "Claude Code ")
    }

    func testDoesNotAppendTrailingSpaceAfterChineseOrPunctuation() {
        let config = TextJoinConfiguration(appendTrailingSpaceAfterLatin: true)
        XCTAssertEqual(TextJoinPolicy.prepare(transcript: "你好", precedingCharacter: nil, appKind: .chat, configuration: config), "你好")
        XCTAssertEqual(TextJoinPolicy.prepare(transcript: "Hello?", precedingCharacter: nil, appKind: .chat, configuration: config), "Hello?")
    }

    func testConfirmsTextReplacingAnElectronPlaceholder() {
        XCTAssertTrue(InsertionTextEvidence.containsNewOccurrence(
            insertedText: "保留我的原话",
            originalText: "使用 ChatGPT",
            currentText: "保留我的原话"
        ))
    }

    func testConfirmsNewOccurrenceInsideACompositeAXValue() {
        XCTAssertTrue(InsertionTextEvidence.containsNewOccurrence(
            insertedText: "新增内容",
            originalText: "当前人设：逐字",
            currentText: "当前人设：逐字\n新增内容"
        ))
    }

    func testDoesNotConfirmAnOccurrenceThatAlreadyExisted() {
        XCTAssertFalse(InsertionTextEvidence.containsNewOccurrence(
            insertedText: "同一句",
            originalText: "同一句",
            currentText: "同一句"
        ))
    }
}
