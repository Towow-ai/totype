import Foundation

public enum PersonalTermState: String, Codable, CaseIterable, Sendable {
    case confirmed
    case ignored
    case retired
}

public enum PersonalTermCategory: String, Codable, CaseIterable, Sendable {
    case technical
    case project
    case person
    case place
    case other
}

public enum PersonalTermScope: Codable, Hashable, Sendable {
    case global
    case bundleIdentifier(String)
    case profile(String)
}

public struct PersonalTerm: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var canonical: String
    public var aliases: [String]
    public var category: PersonalTermCategory
    public var scopes: [PersonalTermScope]
    public var sourceEpisodeIDs: [UUID]
    public var confirmedAt: Date
    public var lastUsedAt: Date?
    public var correctionCount: Int
    public var falsePositiveCount: Int
    public var pinned: Bool
    public var state: PersonalTermState

    public init(
        id: UUID = UUID(),
        canonical: String,
        aliases: [String] = [],
        category: PersonalTermCategory = .technical,
        scopes: [PersonalTermScope] = [.global],
        sourceEpisodeIDs: [UUID] = [],
        confirmedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        correctionCount: Int = 0,
        falsePositiveCount: Int = 0,
        pinned: Bool = true,
        state: PersonalTermState = .confirmed
    ) {
        self.id = id
        self.canonical = canonical
        self.aliases = aliases
        self.category = category
        self.scopes = scopes
        self.sourceEpisodeIDs = sourceEpisodeIDs
        self.confirmedAt = confirmedAt
        self.lastUsedAt = lastUsedAt
        self.correctionCount = correctionCount
        self.falsePositiveCount = falsePositiveCount
        self.pinned = pinned
        self.state = state
    }
}

public enum PersonalLexiconOperation: String, Codable, Sendable {
    case upsert
    case delete
}

public struct PersonalLexiconEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentReaderVersion = 1

    public let schemaVersion: Int
    public let minReaderVersion: Int
    public let eventID: UUID
    public let occurredAt: Date
    public let operation: PersonalLexiconOperation
    public let termID: UUID
    public let term: PersonalTerm?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        minReaderVersion: Int = Self.currentReaderVersion,
        eventID: UUID = UUID(),
        occurredAt: Date = Date(),
        operation: PersonalLexiconOperation,
        termID: UUID,
        term: PersonalTerm?
    ) {
        self.schemaVersion = schemaVersion
        self.minReaderVersion = minReaderVersion
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.operation = operation
        self.termID = termID
        self.term = term
    }

    public static func upsert(_ term: PersonalTerm, occurredAt: Date = Date()) -> Self {
        Self(occurredAt: occurredAt, operation: .upsert, termID: term.id, term: term)
    }

    public static func delete(termID: UUID, occurredAt: Date = Date()) -> Self {
        Self(occurredAt: occurredAt, operation: .delete, termID: termID, term: nil)
    }
}

public struct RankedContextSelection: Equatable, Sendable {
    public let selectedTerms: [String]
    public let selectedTermIDs: [String]
    public let candidateCount: Int
    public let selectedPersonalTermCount: Int
    public let selectedBuiltInTermCount: Int
    public let droppedReasons: [String: Int]
    public let capacity: Int

    public init(
        selectedTerms: [String],
        selectedTermIDs: [String],
        candidateCount: Int,
        selectedPersonalTermCount: Int,
        selectedBuiltInTermCount: Int,
        droppedReasons: [String: Int],
        capacity: Int
    ) {
        self.selectedTerms = selectedTerms
        self.selectedTermIDs = selectedTermIDs
        self.candidateCount = candidateCount
        self.selectedPersonalTermCount = selectedPersonalTermCount
        self.selectedBuiltInTermCount = selectedBuiltInTermCount
        self.droppedReasons = droppedReasons
        self.capacity = capacity
    }
}

public struct ProviderContextReceipt: Codable, Equatable, Identifiable, Sendable {
    public let sessionID: UUID
    public let provider: String
    public let includedTermIDs: [String]
    public let includedTerms: [String]
    public let candidateCount: Int
    public let droppedCount: Int
    public let droppedReasons: [String: Int]
    public let promptHash: String?
    public let capabilitiesUsed: [String]
    public let capacityBudget: Int

    public var id: String { sessionID.uuidString + ":" + provider }

    public init(
        sessionID: UUID,
        provider: String,
        includedTermIDs: [String],
        includedTerms: [String],
        candidateCount: Int,
        droppedCount: Int,
        droppedReasons: [String: Int],
        promptHash: String?,
        capabilitiesUsed: [String],
        capacityBudget: Int
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.includedTermIDs = includedTermIDs
        self.includedTerms = includedTerms
        self.candidateCount = candidateCount
        self.droppedCount = droppedCount
        self.droppedReasons = droppedReasons
        self.promptHash = promptHash
        self.capabilitiesUsed = capabilitiesUsed
        self.capacityBudget = capacityBudget
    }
}
