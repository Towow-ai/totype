import Foundation

public enum AppKind: String, Codable, Sendable {
    case chat
    case document
    case coding
    case terminal
    case unknown
}

public struct TextJoinConfiguration: Codable, Sendable, Equatable {
    public var removeTerminalPeriodInChat: Bool
    public var addSpaceBetweenLatinRuns: Bool
    public var appendTrailingSpaceAfterLatin: Bool
    public var stripTrailingNewlineInTerminal: Bool

    public init(
        removeTerminalPeriodInChat: Bool = false,
        addSpaceBetweenLatinRuns: Bool = false,
        appendTrailingSpaceAfterLatin: Bool = false,
        stripTrailingNewlineInTerminal: Bool = true
    ) {
        self.removeTerminalPeriodInChat = removeTerminalPeriodInChat
        self.addSpaceBetweenLatinRuns = addSpaceBetweenLatinRuns
        self.appendTrailingSpaceAfterLatin = appendTrailingSpaceAfterLatin
        self.stripTrailingNewlineInTerminal = stripTrailingNewlineInTerminal
    }
}

public enum TextJoinPolicy {
    public static func prepare(
        transcript: String,
        precedingCharacter: Character?,
        appKind: AppKind,
        configuration: TextJoinConfiguration
    ) -> String {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if appKind == .chat, configuration.removeTerminalPeriodInChat {
            text = removingOneTerminalPeriod(from: text)
        }

        if appKind == .terminal, configuration.stripTrailingNewlineInTerminal {
            text = text.trimmingCharacters(in: .newlines)
        }

        if configuration.addSpaceBetweenLatinRuns,
           let previous = precedingCharacter,
           let first = text.first,
           isLatinWordCharacter(previous),
           isLatinWordCharacter(first) {
            text = " " + text
        }

        if configuration.appendTrailingSpaceAfterLatin,
           let last = text.last,
           isLatinWordCharacter(last) {
            text.append(" ")
        }

        return text
    }

    private static func removingOneTerminalPeriod(from text: String) -> String {
        guard let last = text.last else { return text }
        guard last == "。" || last == "." else { return text }

        let without = text.dropLast()
        guard let newLast = without.last else { return String(without) }

        // Keep ellipses and numeric/version punctuation intact.
        if newLast == "." || newLast == "。" || newLast.isNumber {
            return text
        }
        return String(without)
    }

    public static func isLatinWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && !isCJK(scalar)
        }
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

public enum InsertionTextEvidence {
    /// Returns true only when the inserted text occurs more often in the
    /// current editor value than it did in the original value.  This handles
    /// editors that expose placeholder text as their empty AXValue while
    /// avoiding a false confirmation when the same phrase already existed.
    public static func containsNewOccurrence(
        insertedText: String,
        originalText: String,
        currentText: String
    ) -> Bool {
        let needle = normalize(insertedText)
        guard !needle.isEmpty else { return false }
        return occurrenceCount(of: needle, in: normalize(currentText))
            > occurrenceCount(of: needle, in: normalize(originalText))
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

public struct TextMutation: Equatable, Sendable {
    public let oldRange: NSRange
    public let newRange: NSRange
    public let replacementText: String

    public init(oldRange: NSRange, newRange: NSRange, replacementText: String) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.replacementText = replacementText
    }
}

public struct TrackedTextCorrection: Equatable, Sendable {
    public let updatedInsertedRange: NSRange
    public let correctedText: String?

    public init(updatedInsertedRange: NSRange, correctedText: String?) {
        self.updatedInsertedRange = updatedInsertedRange
        self.correctedText = correctedText
    }
}

/// Infers one contiguous editor mutation and maps it against the exact range
/// inserted by Verbatim Voice. This intentionally does not behave like a
/// keylogger: edits before/after the tracked range only move or preserve the
/// range, while only edits contained inside that range become corrections.
public enum CorrectionInference {
    public static func mutation(from oldText: String, to newText: String) -> TextMutation? {
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        guard oldUnits != newUnits else { return nil }

        var prefix = 0
        let sharedCount = min(oldUnits.count, newUnits.count)
        while prefix < sharedCount, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldUnits.count - prefix,
              suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] {
            suffix += 1
        }

        let oldRange = NSRange(location: prefix, length: oldUnits.count - prefix - suffix)
        let newRange = NSRange(location: prefix, length: newUnits.count - prefix - suffix)
        let replacement = (newText as NSString).substring(with: newRange)
        return TextMutation(oldRange: oldRange, newRange: newRange, replacementText: replacement)
    }

    public static func track(
        mutation: TextMutation,
        oldWholeText: String,
        newWholeText: String,
        insertedRange: NSRange
    ) -> TrackedTextCorrection? {
        let oldLength = (oldWholeText as NSString).length
        let newLength = (newWholeText as NSString).length
        guard NSMaxRange(mutation.oldRange) <= oldLength,
              NSMaxRange(mutation.newRange) <= newLength,
              NSMaxRange(insertedRange) <= oldLength else { return nil }

        let delta = mutation.newRange.length - mutation.oldRange.length
        let insertedEnd = NSMaxRange(insertedRange)

        // An edit entirely before the dictated text only shifts its location.
        if NSMaxRange(mutation.oldRange) <= insertedRange.location {
            return TrackedTextCorrection(
                updatedInsertedRange: NSRange(
                    location: max(0, insertedRange.location + delta),
                    length: insertedRange.length
                ),
                correctedText: nil
            )
        }

        // An edit entirely after the dictated text is unrelated. A punctuation
        // insertion exactly at the end is the one useful exception: users
        // often fix a missing comma/question mark by typing it at the boundary.
        if mutation.oldRange.location >= insertedEnd {
            if mutation.oldRange.location == insertedEnd,
               mutation.oldRange.length == 0,
               isPunctuationOrWhitespaceOnly(mutation.replacementText),
               !mutation.replacementText.isEmpty {
                let correctedRange = NSRange(
                    location: insertedRange.location,
                    length: insertedRange.length + delta
                )
                guard NSMaxRange(correctedRange) <= newLength else { return nil }
                return TrackedTextCorrection(
                    updatedInsertedRange: correctedRange,
                    correctedText: (newWholeText as NSString).substring(with: correctedRange)
                )
            }
            return TrackedTextCorrection(updatedInsertedRange: insertedRange, correctedText: nil)
        }

        // A correction must be fully contained in the text we inserted. If a
        // single diff spans outside context and dictated text, attribution is
        // ambiguous and we deliberately learn nothing.
        guard mutation.oldRange.location >= insertedRange.location,
              NSMaxRange(mutation.oldRange) <= insertedEnd else { return nil }

        let correctedRange = NSRange(
            location: insertedRange.location,
            length: insertedRange.length + delta
        )
        guard correctedRange.length > 0, NSMaxRange(correctedRange) <= newLength else { return nil }
        let corrected = (newWholeText as NSString).substring(with: correctedRange)
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TrackedTextCorrection(updatedInsertedRange: correctedRange, correctedText: corrected)
    }

    public static func replacement(
        from original: String,
        to corrected: String
    ) -> (original: String, corrected: String, punctuationOnly: Bool)? {
        guard let change = mutation(from: original, to: corrected) else { return nil }
        let old = (original as NSString).substring(with: change.oldRange)
        let new = change.replacementText
        guard old != new else { return nil }
        let punctuationOnly = isPunctuationOrWhitespaceOnly(old + new)
        return (old, new, punctuationOnly)
    }

    private static func isPunctuationOrWhitespaceOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }
}
