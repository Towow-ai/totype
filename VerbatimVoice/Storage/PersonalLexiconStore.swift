import Foundation

actor PersonalLexiconStore {
    enum StoreError: LocalizedError {
        case unsupportedReader(required: Int, supported: Int)
        case corruptLine(Int)
        case invalidEvent(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedReader(let required, let supported):
                return String(localized: "个人词库需要 reader \(required)，当前仅支持 \(supported)")
            case .corruptLine(let line):
                return String(localized: "个人词库第 \(line, format: .number.grouping(.never)) 行无法解码")
            case .invalidEvent(let line):
                return String(localized: "个人词库第 \(line, format: .number.grouping(.never)) 行事件不完整")
            }
        }
    }

    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            directory = baseDirectory
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = AppIdentity.dataDirectory(in: root)
        }
        fileURL = directory.appendingPathComponent("personal-lexicon-v1.jsonl")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func location() -> URL { fileURL }

    func load() throws -> [PersonalTerm] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var terms: [UUID: PersonalTerm] = [:]
        for (offset, line) in data.split(separator: 0x0A).enumerated() {
            let lineNumber = offset + 1
            guard let event = try? decoder.decode(PersonalLexiconEvent.self, from: Data(line)) else {
                throw StoreError.corruptLine(lineNumber)
            }
            guard event.minReaderVersion <= PersonalLexiconEvent.currentReaderVersion else {
                throw StoreError.unsupportedReader(
                    required: event.minReaderVersion,
                    supported: PersonalLexiconEvent.currentReaderVersion
                )
            }
            switch event.operation {
            case .upsert:
                guard let term = event.term, term.id == event.termID else {
                    throw StoreError.invalidEvent(lineNumber)
                }
                terms[event.termID] = term
            case .delete:
                terms.removeValue(forKey: event.termID)
            }
        }
        return terms.values.sorted(by: Self.termOrder)
    }

    @discardableResult
    func upsert(_ term: PersonalTerm) throws -> [PersonalTerm] {
        try append(.upsert(term))
        return try load()
    }

    @discardableResult
    func delete(termID: UUID) throws -> [PersonalTerm] {
        try append(.delete(termID: termID))
        let remaining = try load()
        try compact(remaining)
        return remaining
    }

    @discardableResult
    func seedIfMissing(_ seeds: [PersonalTerm]) throws -> [PersonalTerm] {
        var current = try load()
        var keys = Set(current.map { Self.normalizedKey($0.canonical) })
        for seed in seeds {
            guard keys.insert(Self.normalizedKey(seed.canonical)).inserted else { continue }
            try append(.upsert(seed))
            current.append(seed)
        }
        return current.sorted(by: Self.termOrder)
    }

    private func append(_ event: PersonalLexiconEvent) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = try encoder.encode(event)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func compact(_ terms: [PersonalTerm]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for term in terms.sorted(by: Self.termOrder) {
            data.append(try encoder.encode(PersonalLexiconEvent.upsert(term)))
            data.append(0x0A)
        }
        let temporary = directory.appendingPathComponent(".personal-lexicon-v1.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func termOrder(_ lhs: PersonalTerm, _ rhs: PersonalTerm) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        let comparison = lhs.canonical.localizedStandardCompare(rhs.canonical)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
