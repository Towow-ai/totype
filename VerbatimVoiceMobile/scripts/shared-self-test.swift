// Assertion tests for VerbatimVoiceMobile/Shared. Runs on macOS:
//   VerbatimVoiceMobile/scripts/shared-self-test.sh
import Foundation

@main
struct SharedSelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("ok  \(message)")
        } else {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 2, arguments[1] == "claim-worker" {
            runClaimWorker(arguments)
            return
        }

        testPostReadAndIdempotence()
        testRevisionMonotonic()
        testClaimRequiresMatchingRevision()
        testConcurrentClaimThreads()
        testConcurrentClaimProcesses()
        testAtomicWritesUnderConcurrentReaders()
        testCorruptRecovery()
        testTrimToCapacity()
        testSharedSessionState()
        testFallbackProviderFields()
        testSessionLivenessAndAnswers()
        testKeyboardRoute()
        testFailureAndRetryKeepOneEntry()
        testHeartbeatWhileIdleOrPaused()
        testKeyboardRequests()
        testLevelSnapshot()
        testKeyboardPresence()
        testDarwinNotification()

        if failures > 0 {
            print("\n\(failures) shared self-test assertion(s) failed")
            exit(1)
        }
        print("\nall shared self-tests passed")
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbatim-shared-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func testPostReadAndIdempotence() {
        let mailbox = Mailbox(directory: temporaryDirectory())
        check(mailbox.read() == .empty, "missing mailbox reads as empty")
        let id = UUID()
        let first = try! mailbox.post(sessionID: id, text: "嗯，我我想说的是 skill")
        let second = try! mailbox.post(sessionID: id, text: "different text")
        let snapshot = mailbox.read()
        check(snapshot.entries.count == 1, "posting one session twice keeps one entry")
        check(second == first && snapshot.entries[0].text == "嗯，我我想说的是 skill", "second post returns the original entry verbatim")
        check(snapshot.latestPending?.sessionID == id, "latest pending is the posted entry")
    }

    static func testRevisionMonotonic() {
        let mailbox = Mailbox(directory: temporaryDirectory())
        var seen: [UInt64] = []
        let a = UUID(), b = UUID(), c = UUID()
        try! mailbox.post(sessionID: a, text: "a"); seen.append(mailbox.read().revision)
        try! mailbox.post(sessionID: b, text: "b"); seen.append(mailbox.read().revision)
        let entryB = mailbox.read().entries.first { $0.sessionID == b }!
        _ = try! mailbox.claim(sessionID: b, expectedRevision: entryB.revision); seen.append(mailbox.read().revision)
        try! mailbox.markInserted(sessionID: b); seen.append(mailbox.read().revision)
        try! mailbox.discard(sessionID: a); seen.append(mailbox.read().revision)
        try! mailbox.post(sessionID: c, text: "c"); seen.append(mailbox.read().revision)
        let before = mailbox.read().revision
        _ = try! mailbox.claim(sessionID: a, expectedRevision: 1)
        check(mailbox.read().revision == before, "failed claim does not bump revision")
        check(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "revision strictly increases: \(seen)")
        let entries = mailbox.read().entries
        check(entries.map(\.state) == [.discarded, .inserted, .pending], "states follow pending→claimed→inserted and pending→discarded")
        check(entries.allSatisfy { $0.revision <= mailbox.read().revision }, "entry revisions never exceed mailbox revision")
    }

    static func testClaimRequiresMatchingRevision() {
        let mailbox = Mailbox(directory: temporaryDirectory())
        let id = UUID()
        let entry = try! mailbox.post(sessionID: id, text: "x")
        check(try! mailbox.claim(sessionID: id, expectedRevision: entry.revision + 1) == nil, "claim with wrong revision fails")
        let claimed = try! mailbox.claim(sessionID: id, expectedRevision: entry.revision)
        check(claimed?.state == .claimed, "claim with displayed revision succeeds")
        check(try! mailbox.claim(sessionID: id, expectedRevision: entry.revision) == nil, "second claim of same entry fails")
        check(try! mailbox.discard(sessionID: id) == false, "claimed entry cannot be discarded")
        check(try! mailbox.markInserted(sessionID: id), "claimed entry can be marked inserted")
        check(try! mailbox.markInserted(sessionID: id) == false, "inserted entry cannot be marked twice")
    }

    static func testConcurrentClaimThreads() {
        let directory = temporaryDirectory()
        let id = UUID()
        let entry = try! Mailbox(directory: directory).post(sessionID: id, text: "only once")
        let winners = ManagedCounter()
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                // Separate instances share nothing but the files.
                if case .some(.some) = try? Mailbox(directory: directory).claim(sessionID: id, expectedRevision: entry.revision) {
                    winners.increment()
                }
                group.leave()
            }
        }
        group.wait()
        check(winners.value == 1, "32 concurrent thread claims: exactly one wins (got \(winners.value))")
    }

    static func testConcurrentClaimProcesses() {
        let directory = temporaryDirectory()
        let id = UUID()
        let entry = try! Mailbox(directory: directory).post(sessionID: id, text: "cross-process")
        let startAt = Date().timeIntervalSince1970 + 0.5
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        var processes: [(Process, Pipe)] = []
        for _ in 0..<8 {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["claim-worker", directory.path, id.uuidString, String(entry.revision), String(startAt)]
            process.standardOutput = pipe
            try! process.run()
            processes.append((process, pipe))
        }
        var claimed = 0
        var lost = 0
        for (process, pipe) in processes {
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("claimed") { claimed += 1 }
            if output.contains("lost") { lost += 1 }
        }
        check(claimed == 1 && lost == 7, "8 concurrent process claims: exactly one wins (claimed=\(claimed) lost=\(lost))")
        check(Mailbox(directory: directory).read().entries.first?.state == .claimed, "entry ends claimed after process race")
    }

    static func runClaimWorker(_ arguments: [String]) {
        let directory = URL(fileURLWithPath: arguments[2])
        let id = UUID(uuidString: arguments[3])!
        let revision = UInt64(arguments[4])!
        let startAt = Double(arguments[5])!
        while Date().timeIntervalSince1970 < startAt {}
        let result = try? Mailbox(directory: directory).claim(sessionID: id, expectedRevision: revision)
        print(result != nil ? "claimed" : "lost")
    }

    static func testAtomicWritesUnderConcurrentReaders() {
        let directory = temporaryDirectory()
        let mailbox = Mailbox(directory: directory)
        try! mailbox.post(sessionID: UUID(), text: String(repeating: "长文本", count: 2_000))
        let done = ManagedFlag()
        let badReads = ManagedCounter()
        let reads = ManagedCounter()
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                while !done.isSet {
                    // Decode the raw file directly so a torn write cannot hide
                    // behind read()'s "corrupt means empty" fallback.
                    if let data = try? Data(contentsOf: mailbox.fileURL) {
                        reads.increment()
                        if (try? JSONDecoder.shared.decode(MailboxSnapshot.self, from: data)) == nil {
                            badReads.increment()
                        }
                    }
                }
                group.leave()
            }
        }
        for index in 0..<150 {
            try! mailbox.post(sessionID: UUID(), text: String(repeating: "第\(index)段", count: 500))
        }
        done.set()
        group.wait()
        check(badReads.value == 0 && reads.value > 0, "\(reads.value) concurrent raw reads during 150 writes: none torn")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".tmp") } ?? []
        check(leftovers.isEmpty, "no temporary files left behind")
    }

    static func testCorruptRecovery() {
        let directory = temporaryDirectory()
        let mailbox = Mailbox(directory: directory)
        for _ in 0..<3 { try! mailbox.post(sessionID: UUID(), text: "x") }
        let previousRevision = mailbox.read().revision
        try! Data("{\"schemaVersion\":1,\"revision\":".utf8).write(to: mailbox.fileURL)
        check(mailbox.read() == .empty, "corrupt mailbox reads as empty without throwing")
        let id = UUID()
        let entry = try? mailbox.post(sessionID: id, text: "after recovery")
        check(entry != nil, "post succeeds on a corrupt mailbox")
        let snapshot = mailbox.read()
        check(snapshot.entries.map(\.sessionID) == [id], "recovered mailbox holds only the new entry")
        check(snapshot.revision > previousRevision, "revision after recovery (\(snapshot.revision)) exceeds earlier (\(previousRevision))")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("mailbox.corrupt-") } ?? []
        check(backups.count == 1, "corrupt file is backed up")
        if let backup = backups.first {
            let data = try? Data(contentsOf: directory.appendingPathComponent(backup))
            check(data == Data("{\"schemaVersion\":1,\"revision\":".utf8), "backup keeps the original bytes")
        }
        check(try! mailbox.claim(sessionID: id, expectedRevision: entry!.revision) != nil, "entry posted after recovery can be claimed")
    }

    static func testTrimToCapacity() {
        let mailbox = Mailbox(directory: temporaryDirectory())
        var ids: [UUID] = []
        for index in 0..<25 {
            let id = UUID()
            ids.append(id)
            try! mailbox.post(sessionID: id, text: "第 \(index) 条")
        }
        let snapshot = mailbox.read()
        check(snapshot.entries.count == Mailbox.capacity, "mailbox keeps \(Mailbox.capacity) entries after 25 posts")
        check(snapshot.entries.map(\.sessionID) == Array(ids.suffix(Mailbox.capacity)), "oldest entries are trimmed first")
        check(snapshot.revision == 25, "revision counts all 25 posts")
    }

    static func testSharedSessionState() {
        let directory = temporaryDirectory()
        let store = SharedSessionStateStore(directory: directory)
        check(store.read() == .idle, "missing session state reads as idle")
        let id = UUID()
        let start = Date()
        try! store.publish(phase: .starting, sessionID: id, recordingStartedAt: nil, now: start)
        try! store.publish(phase: .recording, sessionID: id, recordingStartedAt: start, now: start)
        let reader = SharedSessionStateStore(directory: directory)
        let state = reader.read()
        check(state.phase == .recording && state.sessionID == id && state.revision == 2, "reader sees recording state with revision 2")
        check(state.effectivePhase(now: start.addingTimeInterval(2)) == .recording, "fresh heartbeat keeps recording phase")
        check(state.effectivePhase(now: start.addingTimeInterval(SharedSessionState.staleAfter + 1)) == .idle, "stale heartbeat reads as idle")
        try! store.heartbeat(now: start.addingTimeInterval(10))
        check(reader.read().effectivePhase(now: start.addingTimeInterval(12)) == .recording, "heartbeat refreshes liveness")
        try! store.publish(phase: .idle, sessionID: id, recordingStartedAt: start)
        check(reader.read().sessionID == nil && reader.read().phase == .idle, "idle clears session fields")
        try! Data("garbage".utf8).write(to: store.fileURL)
        check(reader.read() == .idle, "corrupt session state reads as idle")
    }

    /// 0.3.74 added two optional fields; files written by older builds (or
    /// read by an older keyboard) must keep decoding.
    static func testFallbackProviderFields() {
        let directory = temporaryDirectory()
        let store = SharedSessionStateStore(directory: directory)
        let reader = SharedSessionStateStore(directory: directory)
        try! store.publish { state in
            state.fallbackProviderName = "阿里云"
            state.providerNotice = "Soniox 余额不足，已改用阿里云"
        }
        var state = reader.read()
        check(state.fallbackProviderName == "阿里云" && state.providerNotice == "Soniox 余额不足，已改用阿里云", "fallback provider fields round-trip through the shared file")
        try! store.publish(phase: .recording, sessionID: UUID(), recordingStartedAt: Date())
        check(reader.read().fallbackProviderName == "阿里云", "publishing other fields keeps the fallback provider")
        try! store.publish { state in
            state.fallbackProviderName = nil
            state.providerNotice = nil
        }
        state = reader.read()
        check(state.fallbackProviderName == nil && state.providerNotice == nil, "recovery clears the fallback provider fields")

        // A state file from before 0.3.74: the new keys are absent.
        let encoded = try! JSONEncoder.precise.encode(SharedSessionState.idle)
        var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "fallbackProviderName")
        object.removeValue(forKey: "providerNotice")
        let legacy = try! JSONSerialization.data(withJSONObject: object)
        let decoded = try? JSONDecoder.precise.decode(SharedSessionState.self, from: legacy)
        check(decoded != nil && decoded?.fallbackProviderName == nil, "state written before 0.3.74 still decodes")
        // A newer file read by an older decoder: unknown keys are ignored by
        // Codable, so the extra keys cannot break an old keyboard either.
        var newer = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        newer["fallbackProviderName"] = "阿里云"
        newer["someFutureField"] = 1
        let newerData = try! JSONSerialization.data(withJSONObject: newer)
        check((try? JSONDecoder.precise.decode(SharedSessionState.self, from: newerData))?.fallbackProviderName == "阿里云", "unknown keys are ignored when decoding")
    }

    static func testSessionLivenessAndAnswers() {
        let directory = temporaryDirectory()
        let store = SharedSessionStateStore(directory: directory)
        let reader = SharedSessionStateStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000.123)
        try! store.publish(now: start) { state in
            state.sessionActive = true
            state.sessionEndsAt = start.addingTimeInterval(300)
        }
        var state = reader.read()
        check(state.heartbeatAt == start, "heartbeat keeps sub-second precision across the file (\(state.heartbeatAt.timeIntervalSince1970))")
        check(state.keyboardRoute(heartbeatAge: 0.5) == .request, "armed session with fresh heartbeat gets a request")
        check(state.effectivePhase(now: start) == .idle, "armed but not recording reads as idle phase")
        try! store.heartbeat(now: start.addingTimeInterval(10))
        state = reader.read()
        check(state.heartbeatAt == start.addingTimeInterval(10), "heartbeat refreshes an idle armed session")

        let request = KeyboardRequest(action: .start, issuedAt: start)
        let dictation = UUID()
        let recordingAt = start.addingTimeInterval(10.25)
        try! store.publish(now: recordingAt) { state in
            state.phase = .recording
            state.sessionID = dictation
            state.recordingStartedAt = recordingAt
            state.originRequestID = request.id
            state.handledRequestID = request.id
            state.handledRequestResult = .accepted
            state.sessionEndsAt = nil
        }
        state = reader.read()
        check(state.answer(to: request.id) == .accepted, "app answer is matched to the keyboard's request ID")
        check(state.answer(to: UUID()) == nil, "another request ID has no answer yet")
        check(state.originRequestID == request.id && state.sessionID == dictation, "origin request links the request to its dictation")
        check(state.recordingStartedAt == recordingAt, "recording start keeps sub-second precision")

        let pausedEnd = Date().addingTimeInterval(120)
        try! store.publish { state in
            state.phase = .idle
            state.sessionActive = false
            state.sessionPaused = true
            state.sessionEndsAt = pausedEnd
        }
        state = reader.read()
        check(state.sessionPaused && state.keyboardRoute(heartbeatAge: 0) == .openApp(why: "paused") && abs((state.sessionEndsAt ?? .distantPast).timeIntervalSince(pausedEnd)) < 0.001, "paused session is not live but keeps its end time")
        try! store.publish { state in
            state.phase = .idle
            state.sessionActive = false
            state.sessionPaused = false
            state.sessionEndsAt = Date()
        }
        state = reader.read()
        check(state.sessionID == nil && state.originRequestID == nil && state.sessionEndsAt == nil, "idle and inactive clear dictation and session fields")
        check(state.answer(to: request.id) == .accepted, "answer survives later publishes")
        try! store.heartbeat(now: Date().addingTimeInterval(100))
        check(reader.read().heartbeatAt < Date().addingTimeInterval(50), "no heartbeat once idle and inactive")
    }

    /// Device log 2026-10-01: the keyboard saw heartbeat ages of 3.0–8.2 s
    /// for a live session (it judged a cached read against the render
    /// clock) and opened the app. An active session now gets a request
    /// unless its heartbeat is older than the idle timeout.
    static func testKeyboardRoute() {
        var state = SharedSessionState.idle
        check(state.keyboardRoute(heartbeatAge: 0) == .openApp(why: "noSession"), "no session opens the app")
        state.sessionActive = true
        state.sessionIdleTimeout = 300
        check(state.keyboardRoute(heartbeatAge: 0.5) == .request, "active, 0.5 s heartbeat: request")
        for age in [3.046, 5.054, 7.129, 8.237] {
            check(state.keyboardRoute(heartbeatAge: age) == .request, "active, \(age) s heartbeat (logged false stale): request, not URL")
        }
        check(state.keyboardRoute(heartbeatAge: 299) == .request, "active, heartbeat just inside the idle timeout: request")
        check(state.keyboardRoute(heartbeatAge: 301) == .openApp(why: "stale"), "active, heartbeat older than the idle timeout: open the app")
        state.sessionIdleTimeout = 60
        check(state.keyboardRoute(heartbeatAge: 61) == .openApp(why: "stale"), "the limit follows the session's idle timeout")
        state.sessionIdleTimeout = nil
        check(state.keyboardRoute(heartbeatAge: 1_800) == .request, "manual timeout: request within the cap")
        check(state.keyboardRoute(heartbeatAge: SharedSessionState.unresponsiveCapWithoutTimeout + 1) == .openApp(why: "stale"), "manual timeout: open the app beyond the cap")
        state.sessionPaused = true
        state.sessionActive = false
        check(state.keyboardRoute(heartbeatAge: 0.1) == .openApp(why: "paused"), "paused session opens the app even with a fresh heartbeat")

        // Round trip through the file, and files without the new fields.
        let directory = temporaryDirectory()
        let store = SharedSessionStateStore(directory: directory)
        try! store.publish { state in
            state.sessionActive = true
            state.sessionIdleTimeout = 900
        }
        check(SharedSessionStateStore(directory: directory).read().sessionIdleTimeout == 900, "idle timeout round-trips through the shared file")
        let encoded = try! JSONEncoder.precise.encode(SharedSessionState.idle)
        var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "sessionIdleTimeout")
        object.removeValue(forKey: "fallbackProviderName")
        object.removeValue(forKey: "providerNotice")
        object["sessionActive"] = true
        let legacy = try? JSONDecoder.precise.decode(SharedSessionState.self, from: try! JSONSerialization.data(withJSONObject: object))
        check(legacy != nil && legacy?.sessionIdleTimeout == nil, "state without the idle timeout still decodes")
        check(legacy?.keyboardRoute(heartbeatAge: 30) == .request, "legacy state uses the cap, not a 2.5 s window")

        let request = KeyboardRequest(action: .start, seenHeartbeatAt: Date(timeIntervalSince1970: 1_800_000_000.456))
        let requestStore = KeyboardRequestStore(directory: directory)
        try! requestStore.write(request)
        check(requestStore.read()?.seenHeartbeatAt == request.seenHeartbeatAt, "request carries the heartbeat the keyboard saw")
        var requestObject = try! JSONSerialization.jsonObject(with: JSONEncoder.precise.encode(request)) as! [String: Any]
        requestObject.removeValue(forKey: "seenHeartbeatAt")
        let oldRequest = try? JSONDecoder.precise.decode(KeyboardRequest.self, from: try! JSONSerialization.data(withJSONObject: requestObject))
        check(oldRequest?.id == request.id && oldRequest?.seenHeartbeatAt == nil, "request without the seen heartbeat still decodes")
    }

    /// A failed dictation and its retries stay one mailbox entry: failed →
    /// retrying → failed (latest reason) → retrying → pending (text), then
    /// claimable once. Nothing else can move it while it waits.
    static func testFailureAndRetryKeepOneEntry() {
        let mailbox = Mailbox(directory: temporaryDirectory())
        let id = UUID()
        let failed = try! mailbox.postFailure(sessionID: id, reason: "网络不通")
        check(failed.state == .failed && failed.text.isEmpty && failed.failureReason == "网络不通", "failure is posted as one failed entry")
        check(mailbox.read().latestPending == nil && mailbox.read().latestFailure?.sessionID == id, "a failure is not pending text")
        check((try? mailbox.claim(sessionID: id, expectedRevision: failed.revision)) ?? nil == nil, "a failed entry cannot be claimed")
        let first = try! mailbox.beginRetry(sessionID: id)
        check(first?.state == .retrying && first?.retryCount == 1, "retry moves it to retrying and counts the attempt")
        check((try! mailbox.beginRetry(sessionID: id)) == nil, "a running retry is not started twice")
        try! mailbox.failRetry(sessionID: id, reason: "超时")
        var entry = mailbox.read().entries.first { $0.sessionID == id }
        check(entry?.state == .failed && entry?.failureReason == "超时", "failed retry keeps the entry with the latest reason")
        try! mailbox.postFailure(sessionID: id, reason: "仍然超时")
        check(mailbox.read().entries.filter { $0.sessionID == id }.count == 1, "re-posting a failure updates in place, no second entry")
        check(try! mailbox.deferRetry(sessionID: id), "稍后再试 defers a failed entry")
        check(mailbox.read().latestFailure == nil, "a deferred entry is hidden from the keyboard")
        let second = try! mailbox.beginRetry(sessionID: id)
        check(second?.retryCount == 2, "a deferred entry can still be retried (automatic retry)")
        try! mailbox.finishRetry(sessionID: id, text: "嗯，重试成功的原话")
        entry = mailbox.read().entries.first { $0.sessionID == id }
        check(entry?.state == .pending && entry?.text == "嗯，重试成功的原话" && entry?.failureReason == nil, "successful retry turns the same entry into pending text")
        check(mailbox.read().entries.filter { $0.sessionID == id }.count == 1, "one entry after any number of retries")
        check(mailbox.read().latestPending?.sessionID == id, "the retried result waits behind 插入")
        let claimed = try! mailbox.claim(sessionID: id, expectedRevision: entry!.revision)
        check(claimed?.text == "嗯，重试成功的原话", "retried text is claimed once")
        check((try! mailbox.beginRetry(sessionID: id)) == nil, "an entry with text is never retried")
        try! mailbox.postFailure(sessionID: id, reason: "late")
        check(mailbox.read().entries.first { $0.sessionID == id }?.state == .claimed, "a late failure does not overwrite a result")

        let interrupted = UUID()
        try! mailbox.postFailure(sessionID: interrupted, reason: "x")
        _ = try! mailbox.beginRetry(sessionID: interrupted)
        check(try! mailbox.resetInterruptedRetries(reason: "上次重试被中断") == 1, "relaunch resets an interrupted retry")
        check(mailbox.read().entries.first { $0.sessionID == interrupted }?.state == .failed, "interrupted retry is failed again")
        check(try! mailbox.discard(sessionID: interrupted), "a failed entry can be dismissed")

        // A mailbox written before failures existed still decodes.
        let legacy = #"{"schemaVersion":1,"revision":3,"entries":[{"sessionID":"\#(UUID().uuidString)","revision":3,"text":"旧","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z","state":"pending"}]}"#
        let decoded = try? JSONDecoder.shared.decode(MailboxSnapshot.self, from: Data(legacy.utf8))
        check(decoded?.latestPending?.text == "旧" && decoded?.latestPending?.retryCount == nil, "mailbox without failure fields still decodes")
    }

    /// The heartbeat keeps beating for an idle armed session and a paused
    /// one, stops once neither holds, and `lastWrittenHeartbeat` follows it.
    static func testHeartbeatWhileIdleOrPaused() {
        let directory = temporaryDirectory()
        let store = SharedSessionStateStore(directory: directory)
        let reader = SharedSessionStateStore(directory: directory)
        let t0 = Date(timeIntervalSince1970: 1_800_000_100)
        try! store.heartbeat(now: t0)
        check(store.lastWrittenHeartbeat == nil, "no beat before the first publish")
        try! store.publish(now: t0) { state in
            state.sessionActive = true
            state.sessionIdleTimeout = 300
        }
        try! store.heartbeat(now: t0.addingTimeInterval(1))
        check(reader.read().heartbeatAt == t0.addingTimeInterval(1) && store.lastWrittenHeartbeat == t0.addingTimeInterval(1), "idle armed session beats")
        try! store.publish(now: t0.addingTimeInterval(2)) { state in
            state.sessionActive = false
            state.sessionPaused = true
        }
        try! store.heartbeat(now: t0.addingTimeInterval(3))
        check(reader.read().heartbeatAt == t0.addingTimeInterval(3), "paused session beats")
        try! store.publish(now: t0.addingTimeInterval(4)) { state in
            state.sessionPaused = false
        }
        try! store.heartbeat(now: t0.addingTimeInterval(5))
        check(reader.read().heartbeatAt == t0.addingTimeInterval(4), "ended session stops beating")
    }

    static func testKeyboardRequests() {
        let directory = temporaryDirectory()
        let keyboard = KeyboardRequestStore(directory: directory)
        let app = KeyboardRequestStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000.5)
        check(app.read() == nil, "missing request file reads as nil")
        let start = KeyboardRequest(action: .start, issuedAt: now)
        try! keyboard.write(start)
        check(app.read() == start, "request round-trips with its ID, action and sub-second time")
        check(app.unhandled(after: nil, now: now.addingTimeInterval(0.5)) == start, "fresh request is unhandled")
        check(app.unhandled(after: start.id, now: now.addingTimeInterval(0.5)) == nil, "answered request is not handled twice")
        check(app.unhandled(after: nil, now: now.addingTimeInterval(KeyboardRequest.expiresAfter + 0.1)) == nil, "expired request is ignored")
        check(start.isExpired(now: now.addingTimeInterval(KeyboardRequest.expiresAfter + 0.1)), "request expires after \(KeyboardRequest.expiresAfter)s")
        check(!start.isExpired(now: now.addingTimeInterval(KeyboardRequest.answerTimeout)), "request is still valid when the keyboard gives up waiting")
        let target = UUID()
        let stop = KeyboardRequest(action: .stop, issuedAt: now.addingTimeInterval(1), targetSessionID: target)
        try! keyboard.write(stop)
        let latest = app.unhandled(after: start.id, now: now.addingTimeInterval(1.2))
        check(latest == stop && latest?.targetSessionID == target, "a newer request replaces the older one and keeps its target dictation")
        try! Data("{".utf8).write(to: app.fileURL)
        check(app.read() == nil, "corrupt request file reads as nil")
    }

    static func testLevelSnapshot() {
        let store = SharedLevelStore(directory: temporaryDirectory())
        check(store.read() == nil, "missing level file reads as nil")
        let id = UUID()
        let levels = (0..<40).map { UInt8($0 * 6) }
        try! store.write(SharedLevelSnapshot(sessionID: id, updatedAt: Date(timeIntervalSince1970: 5.5), levels: levels))
        let snapshot = store.read()
        check(snapshot?.levels == Array(levels.suffix(SharedLevelSnapshot.capacity)), "level file keeps the newest \(SharedLevelSnapshot.capacity) samples")
        check(snapshot?.sessionID == id && snapshot?.updatedAt.timeIntervalSince1970 == 5.5, "level file keeps session and time")
    }

    static func testKeyboardPresence() {
        let directory = temporaryDirectory()
        check(KeyboardPresence.lastSeen(directory: directory) == nil, "keyboard never seen before first mark")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        KeyboardPresence.mark(directory: directory, now: now)
        check(KeyboardPresence.lastSeen(directory: directory) == now, "keyboard presence mark round-trips")
    }

    static func testDarwinNotification() {
        var received: [DarwinNotification] = []
        let observer = DarwinObserver([.mailboxChanged, .keyboardRequest]) { received.append($0) }
        DarwinNotifier.post(.mailboxChanged)
        DarwinNotifier.post(.sessionChanged)
        DarwinNotifier.post(.keyboardRequest)
        let deadline = Date().addingTimeInterval(2)
        while received.count < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(received == [.mailboxChanged, .keyboardRequest], "Darwin observer receives only the subscribed names (got \(received))")
        check(DarwinNotification.mailboxChanged.name == "\(MobileIdentity.appBundleID).mailbox-changed",
              "Darwin names are <app bundle ID>.<suffix> (got \(DarwinNotification.mailboxChanged.name))")
        withExtendedLifetime(observer) {}
    }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
