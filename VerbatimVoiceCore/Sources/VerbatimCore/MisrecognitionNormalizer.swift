import Foundation

/// A personal term's `aliases` are the ways ASR has been observed to mishear
/// it (星河 → Zephyr, Sonnet → Sonet). Rewriting those spans back to the
/// canonical term is not paraphrase: it restores a word the speaker actually
/// said. Because an alias can also be a real word ("不是 SKU，是 skill"),
/// a rewrite needs a second, independent engine that heard the canonical
/// term at the same position. No corroboration means no rewrite.
public struct MisrecognitionRule: Equatable, Sendable {
    public let alias: String
    public let canonical: String

    public init(alias: String, canonical: String) {
        self.alias = alias
        self.canonical = canonical
    }
}

public struct MisrecognitionResult: Equatable, Sendable {
    public let text: String
    public let applied: [MisrecognitionRule]
    /// Alias matches left untouched because the other engine did not hear
    /// the canonical term there.
    public let uncorroborated: [MisrecognitionRule]
}

public enum MisrecognitionNormalizer {
    public static func rules(from terms: [PersonalTerm]) -> [MisrecognitionRule] {
        terms
            .filter { $0.state == .confirmed }
            .flatMap { term in
                term.aliases.compactMap { alias -> MisrecognitionRule? in
                    let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard alias.count >= 2,
                          alias.compare(term.canonical, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame
                    else { return nil }
                    return MisrecognitionRule(alias: alias, canonical: term.canonical)
                }
            }
            .sorted { $0.alias.count > $1.alias.count }
    }

    /// - Parameter corroboration: the other engine's final text for the same
    ///   audio. `nil` or empty disables every rewrite.
    public static func apply(
        _ text: String,
        rules: [MisrecognitionRule],
        corroboration: String?
    ) -> MisrecognitionResult {
        let unchanged = MisrecognitionResult(text: text, applied: [], uncorroborated: [])
        guard !text.isEmpty, !rules.isEmpty,
              let corroboration,
              !corroboration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return unchanged }

        // All matches are found on the original text and must not overlap, so
        // a replacement can never be re-matched by another rule.
        var matches: [(range: Range<String.Index>, rule: MisrecognitionRule)] = []
        let whole = NSRange(text.startIndex..., in: text)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern(for: rule.alias), options: [.caseInsensitive])
            else { continue }
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                matches.append((range, rule))
            }
        }
        guard !matches.isEmpty else { return unchanged }
        matches.sort {
            let left = text.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
            let right = text.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
            return left != right ? left > right : $0.range.lowerBound < $1.range.lowerBound
        }
        var accepted: [(range: Range<String.Index>, rule: MisrecognitionRule)] = []
        for match in matches where !accepted.contains(where: { $0.range.overlaps(match.range) }) {
            accepted.append(match)
        }

        let alignment = Alignment(primary: text, other: corroboration)
        var applied: [(range: Range<String.Index>, rule: MisrecognitionRule)] = []
        var uncorroborated: [MisrecognitionRule] = []
        for match in accepted {
            let window = alignment.counterpart(of: match.range, in: text)
            if squashed(window).contains(squashed(match.rule.canonical)) {
                applied.append(match)
            } else {
                uncorroborated.append(match.rule)
            }
        }
        guard !applied.isEmpty else {
            return MisrecognitionResult(text: text, applied: [], uncorroborated: uncorroborated)
        }

        var output = text
        for match in applied.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(match.range, with: match.rule.canonical)
        }
        return MisrecognitionResult(
            text: output,
            applied: applied.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.rule),
            uncorroborated: uncorroborated
        )
    }

    /// ASR renders spelled-out Latin letters with or without spaces
    /// ("GEV", "G E V", "J 加加"), so whitespace between alias characters is
    /// optional. A Latin edge must not touch another Latin letter, otherwise
    /// "fighting" would also rewrite inside "prizefighting".
    static func pattern(for alias: String) -> String {
        let characters = alias.filter { !$0.isWhitespace }
        let body = characters.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        let leading = characters.first.map(isLatinLetter) == true ? "(?<![A-Za-z])" : ""
        let trailing = characters.last.map(isLatinLetter) == true ? "(?![A-Za-z])" : ""
        return leading + body + trailing
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func squashed(_ value: String) -> String {
        value.filter { !$0.isWhitespace }.lowercased()
    }

    /// Character alignment between two transcripts of the same audio. The
    /// counterpart of a primary span is the other text between the nearest
    /// characters both engines agree on just outside that span.
    struct Alignment {
        private let otherCharacters: [Character]
        private let primaryToOther: [Int?]

        init(primary: String, other: String) {
            let primaryCharacters = Array(primary)
            otherCharacters = Array(other)
            let difference = otherCharacters.difference(from: primaryCharacters)
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in difference {
                switch change {
                case let .remove(offset, _, _): removed.insert(offset)
                case let .insert(offset, _, _): inserted.insert(offset)
                }
            }
            var map = [Int?](repeating: nil, count: primaryCharacters.count)
            var otherIndex = 0
            for primaryIndex in primaryCharacters.indices where !removed.contains(primaryIndex) {
                while inserted.contains(otherIndex) { otherIndex += 1 }
                map[primaryIndex] = otherIndex
                otherIndex += 1
            }
            primaryToOther = map
        }

        func counterpart(of range: Range<String.Index>, in primary: String) -> String {
            let start = primary.distance(from: primary.startIndex, to: range.lowerBound)
            let end = primary.distance(from: primary.startIndex, to: range.upperBound)
            var lower = 0
            if start > 0 {
                for index in stride(from: start - 1, through: 0, by: -1) {
                    if let mapped = primaryToOther[index] { lower = mapped + 1; break }
                }
            }
            var upper = otherCharacters.count
            if end < primaryToOther.count {
                for index in end..<primaryToOther.count {
                    if let mapped = primaryToOther[index] { upper = mapped; break }
                }
            }
            guard lower < upper else { return "" }
            return String(otherCharacters[lower..<upper])
        }
    }
}
