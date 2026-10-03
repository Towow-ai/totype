import Foundation

public struct ContextBudgetSelection: Equatable, Sendable {
    public let selectedTerms: [String]
    public let candidateCount: Int
    public let selectedUserTermCount: Int
    public let selectedBuiltInTermCount: Int
    public let droppedCount: Int
    public let capacity: Int

    public init(
        selectedTerms: [String],
        candidateCount: Int,
        selectedUserTermCount: Int,
        selectedBuiltInTermCount: Int,
        droppedCount: Int,
        capacity: Int
    ) {
        self.selectedTerms = selectedTerms
        self.candidateCount = candidateCount
        self.selectedUserTermCount = selectedUserTermCount
        self.selectedBuiltInTermCount = selectedBuiltInTermCount
        self.droppedCount = droppedCount
        self.capacity = capacity
    }
}

public enum ContextBudgeter {
    public static func select(
        candidates: [String],
        builtInTerms: [String],
        capacity: Int
    ) -> ContextBudgetSelection {
        let boundedCapacity = max(0, capacity)
        let uniqueCandidates = uniqueTerms(candidates)
        let uniqueBuiltIns = uniqueTerms(builtInTerms)
        let builtInKeys = Set(uniqueBuiltIns.map(normalizedKey))
        let candidateByKey = Dictionary(
            uniqueKeysWithValues: uniqueCandidates.map { (normalizedKey($0), $0) }
        )

        let userTerms = uniqueCandidates.filter { !builtInKeys.contains(normalizedKey($0)) }
        let presentBuiltIns = uniqueBuiltIns.compactMap { candidateByKey[normalizedKey($0)] }
        let ordered = userTerms + presentBuiltIns
        let selected = Array(ordered.prefix(boundedCapacity))
        let selectedUserCount = min(userTerms.count, selected.count)

        return ContextBudgetSelection(
            selectedTerms: selected,
            candidateCount: uniqueCandidates.count,
            selectedUserTermCount: selectedUserCount,
            selectedBuiltInTermCount: selected.count - selectedUserCount,
            droppedCount: max(0, uniqueCandidates.count - selected.count),
            capacity: boundedCapacity
        )
    }

    public static func select(
        personalTerms: [PersonalTerm],
        builtInTerms: [String],
        targetBundleIdentifier: String?,
        profile: String?,
        capacity: Int,
        referenceDate: Date
    ) -> RankedContextSelection {
        struct RankedPersonal {
            let term: PersonalTerm
            let score: Int
        }

        let boundedCapacity = max(0, capacity)
        var droppedReasons: [String: Int] = [:]
        var eligible: [RankedPersonal] = []

        for term in personalTerms {
            guard term.state == .confirmed else {
                droppedReasons[term.state.rawValue, default: 0] += 1
                continue
            }
            guard scopeMatches(
                term.scopes,
                targetBundleIdentifier: targetBundleIdentifier,
                profile: profile
            ) else {
                droppedReasons["scope_mismatch", default: 0] += 1
                continue
            }
            let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else {
                droppedReasons["empty", default: 0] += 1
                continue
            }
            eligible.append(RankedPersonal(
                term: term,
                score: score(
                    term,
                    targetBundleIdentifier: targetBundleIdentifier,
                    profile: profile,
                    referenceDate: referenceDate
                )
            ))
        }

        eligible.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.term.confirmedAt != $1.term.confirmedAt {
                return $0.term.confirmedAt > $1.term.confirmedAt
            }
            return $0.term.id.uuidString < $1.term.id.uuidString
        }

        var seen: Set<String> = []
        var orderedTerms: [String] = []
        var orderedIDs: [String] = []
        var orderedIsPersonal: [Bool] = []

        for ranked in eligible {
            let canonical = ranked.term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(normalizedKey(canonical)).inserted else {
                droppedReasons["duplicate", default: 0] += 1
                continue
            }
            orderedTerms.append(canonical)
            orderedIDs.append("personal:" + ranked.term.id.uuidString)
            orderedIsPersonal.append(true)
        }

        for builtIn in uniqueTerms(builtInTerms) {
            let key = normalizedKey(builtIn)
            guard seen.insert(key).inserted else { continue }
            orderedTerms.append(builtIn)
            orderedIDs.append("built_in:" + key)
            orderedIsPersonal.append(false)
        }

        let candidateCount = orderedTerms.count
        if candidateCount > boundedCapacity {
            droppedReasons["capacity", default: 0] += candidateCount - boundedCapacity
        }
        let selectedTerms = Array(orderedTerms.prefix(boundedCapacity))
        let selectedIDs = Array(orderedIDs.prefix(boundedCapacity))
        let selectedKinds = Array(orderedIsPersonal.prefix(boundedCapacity))
        let selectedPersonal = selectedKinds.filter { $0 }.count

        return RankedContextSelection(
            selectedTerms: selectedTerms,
            selectedTermIDs: selectedIDs,
            candidateCount: candidateCount,
            selectedPersonalTermCount: selectedPersonal,
            selectedBuiltInTermCount: selectedKinds.count - selectedPersonal,
            droppedReasons: droppedReasons,
            capacity: boundedCapacity
        )
    }

    private static func score(
        _ term: PersonalTerm,
        targetBundleIdentifier: String?,
        profile: String?,
        referenceDate: Date
    ) -> Int {
        var value = 500
        if term.pinned { value += 1_000 }
        if term.scopes.contains(where: {
            switch $0 {
            case .bundleIdentifier(let value): return value == targetBundleIdentifier
            case .profile(let value): return value == profile
            case .global: return false
            }
        }) {
            value += 150
        }
        value += min(100, max(0, term.correctionCount) * 20)
        if let lastUsedAt = term.lastUsedAt {
            let days = max(0, Int(referenceDate.timeIntervalSince(lastUsedAt) / 86_400))
            value += max(0, 80 - days)
        }
        value -= min(400, max(0, term.falsePositiveCount) * 100)
        return value
    }

    private static func scopeMatches(
        _ scopes: [PersonalTermScope],
        targetBundleIdentifier: String?,
        profile: String?
    ) -> Bool {
        let effective = scopes.isEmpty ? [.global] : scopes
        return effective.contains {
            switch $0 {
            case .global:
                return true
            case .bundleIdentifier(let value):
                return value == targetBundleIdentifier
            case .profile(let value):
                return value == profile
            }
        }
    }

    private static func uniqueTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return seen.insert(normalizedKey(trimmed)).inserted ? trimmed : nil
        }
    }

    static func normalizedKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
