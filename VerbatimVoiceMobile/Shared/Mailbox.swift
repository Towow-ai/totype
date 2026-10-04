import Foundation

enum MailboxEntryState: String, Codable, Sendable {
    case pending
    case claimed
    case inserted
    case discarded
    /// The dictation produced no usable text; `failureReason` says why. The
    /// keyboard offers "重试" (the app re-transcribes the archived audio).
    case failed
    /// The app is re-transcribing it now.
    case retrying
    /// Still failed, and the user chose "稍后再试": hidden from the keyboard,
    /// retried once when the network comes back or the next session starts.
    case deferred
}

/// One dictation, as the keyboard sees it. A failed dictation and all its
/// retries stay this one entry: it moves failed → retrying → pending (text)
/// or back to failed (latest reason), so the user only ever sees one result.
struct MailboxEntry: Codable, Equatable, Identifiable, Sendable {
    let sessionID: UUID
    /// Mailbox revision at this entry's last change. A claim must quote it.
    var revision: UInt64
    /// Empty while failed or retrying.
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var state: MailboxEntryState
    /// Latest failure, for failed / retrying / deferred entries.
    var failureReason: String?
    /// Retries started so far (nil before the first).
    var retryCount: Int?

    var id: UUID { sessionID }

    /// Waiting for a retry, by the user or automatically.
    var awaitsRetry: Bool { state == .failed || state == .deferred }
}

struct MailboxSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Strictly increases with every write, including across corruption
    /// recovery.
    var revision: UInt64
    /// Oldest first.
    var entries: [MailboxEntry]

    static let empty = MailboxSnapshot(schemaVersion: currentSchemaVersion, revision: 0, entries: [])

    var latestPending: MailboxEntry? {
        entries.last { $0.state == .pending }
    }

    /// The newest failed or retrying entry (deferred ones stay hidden).
    var latestFailure: MailboxEntry? {
        entries.last { $0.state == .failed || $0.state == .retrying }
    }
}

/// Transcript hand-off from the app to the keyboard, stored as one JSON file
/// in the App Group container.
///
/// Invariants: every write is read-modify-write under an exclusive flock and
/// lands with an atomic rename; a pending entry can be claimed at most once
/// (state check plus revision match under the lock), so the keyboard inserts
/// a transcript at most once.
final class Mailbox: Sendable {
    static let capacity = 20

    let fileURL: URL
    private let lock: FileLock
    private let now: @Sendable () -> Date

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        fileURL = directory.appendingPathComponent("mailbox.json")
        lock = FileLock(url: directory.appendingPathComponent("mailbox.lock"))
        // Whole seconds so an entry survives the ISO 8601 round trip unchanged.
        self.now = { Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)) }
    }

    /// Lock-free read. Works without Full Access (the keyboard's container is
    /// read-only then). Missing or corrupt files read as empty.
    func read() -> MailboxSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.shared.decode(MailboxSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    /// Adds a pending transcript. Idempotent per session: posting the same
    /// session twice returns the existing entry unchanged.
    @discardableResult
    func post(sessionID: UUID, text: String) throws -> MailboxEntry {
        try mutate { snapshot in
            if let existing = snapshot.entries.first(where: { $0.sessionID == sessionID }) {
                return existing
            }
            let timestamp = now()
            snapshot.revision += 1
            let entry = MailboxEntry(
                sessionID: sessionID,
                revision: snapshot.revision,
                text: text,
                createdAt: timestamp,
                updatedAt: timestamp,
                state: .pending
            )
            snapshot.entries.append(entry)
            if snapshot.entries.count > Self.capacity {
                snapshot.entries.removeFirst(snapshot.entries.count - Self.capacity)
            }
            return entry
        }
    }

    /// Records a dictation that produced no usable text. Re-posting a
    /// failure for an entry that is still failed (or retrying, or deferred)
    /// updates its reason in place; an entry that already has text is left
    /// alone.
    @discardableResult
    func postFailure(sessionID: UUID, reason: String) throws -> MailboxEntry {
        try mutate { snapshot in
            let timestamp = now()
            if let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }) {
                guard [.failed, .retrying, .deferred].contains(snapshot.entries[index].state) else {
                    return snapshot.entries[index]
                }
                snapshot.entries[index].failureReason = reason
                return Self.transition(&snapshot, index: index, to: .failed, at: timestamp)
            }
            snapshot.revision += 1
            snapshot.entries.append(MailboxEntry(
                sessionID: sessionID,
                revision: snapshot.revision,
                text: "",
                createdAt: timestamp,
                updatedAt: timestamp,
                state: .failed,
                failureReason: reason
            ))
            if snapshot.entries.count > Self.capacity {
                snapshot.entries.removeFirst(snapshot.entries.count - Self.capacity)
            }
            return snapshot.entries[snapshot.entries.count - 1]
        }
    }

    /// failed / deferred → retrying, counting the attempt. Nil when the
    /// entry is missing, already retrying, or already has text, so two
    /// triggers never run the same retry twice.
    func beginRetry(sessionID: UUID) throws -> MailboxEntry? {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].awaitsRetry else { return nil }
            snapshot.entries[index].retryCount = (snapshot.entries[index].retryCount ?? 0) + 1
            return Self.transition(&snapshot, index: index, to: .retrying, at: now())
        }
    }

    /// retrying → pending with the new text: the same entry, so the
    /// keyboard shows one result however many retries it took.
    @discardableResult
    func finishRetry(sessionID: UUID, text: String) throws -> MailboxEntry? {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].state == .retrying else { return nil }
            snapshot.entries[index].text = text
            snapshot.entries[index].failureReason = nil
            return Self.transition(&snapshot, index: index, to: .pending, at: now())
        }
    }

    /// retrying → failed with the latest reason.
    @discardableResult
    func failRetry(sessionID: UUID, reason: String) throws -> MailboxEntry? {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].state == .retrying else { return nil }
            snapshot.entries[index].failureReason = reason
            return Self.transition(&snapshot, index: index, to: .failed, at: now())
        }
    }

    /// failed → deferred ("稍后再试").
    @discardableResult
    func deferRetry(sessionID: UUID) throws -> Bool {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].state == .failed else { return false }
            Self.transition(&snapshot, index: index, to: .deferred, at: now())
            return true
        }
    }

    /// After a relaunch nothing is retrying any more: retrying → failed.
    @discardableResult
    func resetInterruptedRetries(reason: String) throws -> Int {
        try mutate { snapshot in
            var count = 0
            for index in snapshot.entries.indices where snapshot.entries[index].state == .retrying {
                snapshot.entries[index].failureReason = reason
                Self.transition(&snapshot, index: index, to: .failed, at: now())
                count += 1
            }
            return count
        }
    }

    /// Moves a pending entry to `claimed` only if it still carries the
    /// revision the caller displayed. Returns nil when someone else claimed,
    /// discarded or replaced it first.
    func claim(sessionID: UUID, expectedRevision: UInt64) throws -> MailboxEntry? {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].state == .pending,
                  snapshot.entries[index].revision == expectedRevision else { return nil }
            return Self.transition(&snapshot, index: index, to: .claimed, at: now())
        }
    }

    @discardableResult
    func markInserted(sessionID: UUID) throws -> Bool {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  snapshot.entries[index].state == .claimed else { return false }
            Self.transition(&snapshot, index: index, to: .inserted, at: now())
            return true
        }
    }

    @discardableResult
    func discard(sessionID: UUID) throws -> Bool {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.sessionID == sessionID }),
                  [.pending, .failed, .deferred].contains(snapshot.entries[index].state) else { return false }
            Self.transition(&snapshot, index: index, to: .discarded, at: now())
            return true
        }
    }

    @discardableResult
    private static func transition(
        _ snapshot: inout MailboxSnapshot,
        index: Int,
        to state: MailboxEntryState,
        at timestamp: Date
    ) -> MailboxEntry {
        snapshot.revision += 1
        snapshot.entries[index].state = state
        snapshot.entries[index].revision = snapshot.revision
        snapshot.entries[index].updatedAt = timestamp
        return snapshot.entries[index]
    }

    private func mutate<T>(_ body: (inout MailboxSnapshot) throws -> T) throws -> T {
        try lock.withExclusiveLock {
            let original = try loadForWrite()
            var snapshot = original
            let result = try body(&snapshot)
            if snapshot != original {
                try AtomicFile.write(try JSONEncoder.shared.encode(snapshot), to: fileURL)
            }
            return result
        }
    }

    /// Called with the lock held. A corrupt file is moved aside and replaced
    /// by an empty mailbox whose revision starts at the current epoch
    /// milliseconds: normal revisions are small counters (+1 per change), so
    /// the restarted sequence stays above every revision issued before.
    private func loadForWrite() throws -> MailboxSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        if let snapshot = try? JSONDecoder.shared.decode(MailboxSnapshot.self, from: data) {
            return snapshot
        }
        let stamp = UInt64(max(0, now().timeIntervalSince1970) * 1_000)
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("mailbox.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        var recovered = MailboxSnapshot.empty
        recovered.revision = stamp
        try AtomicFile.write(try JSONEncoder.shared.encode(recovered), to: fileURL)
        return recovered
    }
}
