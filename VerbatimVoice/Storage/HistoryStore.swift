import Foundation

actor HistoryStore {
    static let shared = HistoryStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func baseDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = AppIdentity.dataDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("audio", isDirectory: true), withIntermediateDirectories: true)
        return directory
    }

    func audioDirectory() throws -> URL {
        try baseDirectory().appendingPathComponent("audio", isDirectory: true)
    }

    func append(_ record: HistoryRecord) throws {
        let fileURL = try baseDirectory().appendingPathComponent("history.jsonl")
        var line = try encoder.encode(record)
        line.append(0x0A)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func appendAction(
        sessionID: UUID,
        insertionStatus: InsertionStatus? = nil,
        correctedText: String? = nil,
        message: String,
        originalText: String? = nil,
        correctionSource: String? = nil,
        targetBundleIdentifier: String? = nil,
        replacements: [CorrectionReplacement]? = nil
    ) throws {
        let action = HistoryActionRecord(
            id: UUID(),
            sessionID: sessionID,
            occurredAt: Date(),
            insertionStatus: insertionStatus,
            correctedText: correctedText,
            message: message,
            originalText: originalText,
            correctionSource: correctionSource,
            targetBundleIdentifier: targetBundleIdentifier,
            replacements: replacements
        )
        let fileURL = try baseDirectory().appendingPathComponent("history-actions.jsonl")
        var line = try encoder.encode(action)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func recent(limit: Int = 50) throws -> [HistoryRecord] {
        let fileURL = try baseDirectory().appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let lines = data.split(separator: 0x0A).suffix(max(0, limit))
        let actions = try latestActionsBySession()
        let revisions = try revisionsBySession()
        return lines.compactMap { line in
            guard let record = try? decoder.decode(HistoryRecord.self, from: Data(line)) else { return nil }
            let action = actions[record.id]
            return HistoryRecord(
                id: record.id,
                startedAt: record.startedAt,
                finishedAt: record.finishedAt,
                targetBundleIdentifier: record.targetBundleIdentifier,
                targetApplicationName: record.targetApplicationName,
                primary: record.primary,
                appleBaseline: record.appleBaseline,
                comparisons: record.comparisons,
                effectiveProviderID: record.effectiveProviderID,
                usedOfflineFallback: record.usedOfflineFallback,
                insertedText: action?.correctedText ?? record.insertedText,
                insertionStatus: action?.insertionStatus ?? record.insertionStatus,
                insertionTransport: record.insertionTransport,
                insertionAttempts: record.insertionAttempts,
                providerContextReceipts: record.providerContextReceipts,
                audioRelativePath: record.audioRelativePath,
                preRollMilliseconds: record.preRollMilliseconds,
                notes: record.notes + (action.map { [$0.message] } ?? []),
                schemaVersion: record.schemaVersion,
                appVersion: record.appVersion,
                buildNumber: record.buildNumber,
                timeline: record.timeline,
                selectedReason: record.selectedReason,
                userPathFinishedAt: record.userPathFinishedAt,
                persistenceFinishedAt: record.persistenceFinishedAt,
                disposition: record.disposition,
                audioState: record.audioState,
                transcriptRevisions: (record.transcriptRevisions ?? []) + (revisions[record.id] ?? []),
                selectedRevisionID: record.selectedRevisionID,
                networkPath: record.networkPath
            )
        }
    }

    func appendRevision(sessionID: UUID, revision: TranscriptRevision) throws {
        let record = TranscriptRevisionRecord(sessionID: sessionID, revision: revision)
        let fileURL = try baseDirectory().appendingPathComponent("history-revisions.jsonl")
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func correctionSuggestions(limit: Int = 20) throws -> [CorrectionSuggestion] {
        let fileURL = try baseDirectory().appendingPathComponent("history-actions.jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var counts: [CorrectionReplacement: Int] = [:]
        for line in data.split(separator: 0x0A) {
            guard let action = try? decoder.decode(HistoryActionRecord.self, from: Data(line)),
                  action.correctionSource == "observed-after-insertion",
                  let replacements = action.replacements else { continue }
            for replacement in replacements where replacement.original != replacement.corrected {
                counts[replacement, default: 0] += 1
            }
        }
        return counts
            .map { replacement, count in
                CorrectionSuggestion(
                    original: replacement.original,
                    corrected: replacement.corrected,
                    occurrences: count,
                    punctuationOnly: replacement.punctuationOnly
                )
            }
            .sorted {
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                if $0.punctuationOnly != $1.punctuationOnly { return !$0.punctuationOnly }
                return $0.corrected.localizedStandardCompare($1.corrected) == .orderedAscending
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func audioURL(for record: HistoryRecord) throws -> URL? {
        guard let relative = record.audioRelativePath else { return nil }
        let url = try baseDirectory().appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func performMaintenance(retentionDays: Int, quotaBytes: Int64) throws -> StorageMaintenanceResult {
        let directory = try audioDirectory()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard ["wav", "flac"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, retentionDays), to: Date()) ?? .distantPast
        var remaining = candidates
        var deletedCount = 0
        var reclaimed: Int64 = 0

        for item in candidates where item.date < cutoff {
            try FileManager.default.removeItem(at: item.url)
            deletedCount += 1
            reclaimed += item.size
            remaining.removeAll { $0.url == item.url }
        }

        var total = remaining.reduce(Int64(0)) { $0 + $1.size }
        let boundedQuota = max(Int64(64 * 1_024 * 1_024), quotaBytes)
        for item in remaining.sorted(by: { $0.date < $1.date }) where total > boundedQuota {
            try FileManager.default.removeItem(at: item.url)
            total -= item.size
            deletedCount += 1
            reclaimed += item.size
        }

        return StorageMaintenanceResult(deletedAudioFiles: deletedCount, reclaimedBytes: reclaimed)
    }

    private func latestActionsBySession() throws -> [UUID: HistoryActionRecord] {
        let fileURL = try baseDirectory().appendingPathComponent("history-actions.jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        var result: [UUID: HistoryActionRecord] = [:]
        for line in data.split(separator: 0x0A) {
            guard let action = try? decoder.decode(HistoryActionRecord.self, from: Data(line)) else { continue }
            let previous = result[action.sessionID]
            if (previous?.occurredAt ?? .distantPast) <= action.occurredAt {
                result[action.sessionID] = HistoryActionRecord(
                    id: action.id,
                    sessionID: action.sessionID,
                    occurredAt: action.occurredAt,
                    insertionStatus: action.insertionStatus ?? previous?.insertionStatus,
                    correctedText: action.correctedText ?? previous?.correctedText,
                    message: action.message,
                    originalText: action.originalText ?? previous?.originalText,
                    correctionSource: action.correctionSource ?? previous?.correctionSource,
                    targetBundleIdentifier: action.targetBundleIdentifier ?? previous?.targetBundleIdentifier,
                    replacements: action.replacements ?? previous?.replacements
                )
            }
        }
        return result
    }

    private func revisionsBySession() throws -> [UUID: [TranscriptRevision]] {
        let fileURL = try baseDirectory().appendingPathComponent("history-revisions.jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        var result: [UUID: [TranscriptRevision]] = [:]
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(TranscriptRevisionRecord.self, from: Data(line)) else { continue }
            result[record.sessionID, default: []].append(record.revision)
        }
        for sessionID in result.keys {
            result[sessionID]?.sort { $0.createdAt < $1.createdAt }
        }
        return result
    }
}
