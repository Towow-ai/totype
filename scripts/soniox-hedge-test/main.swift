// Offline check of SonioxProvider's hedged connect against a local
// WebSocket server (no Soniox traffic). A stalled attempt is a TCP
// connection whose WebSocket upgrade is never answered.
import Foundation
import Network

final class Server: @unchecked Sendable {
    let listener: NWListener
    var accepted = 0
    var stallFirst: Int
    var held: [NWConnection] = []
    var receivedConfigs = 0
    init(stallFirst: Int) throws {
        self.stallFirst = stallFirst
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: 0)
        listener.newConnectionHandler = { [unowned self] c in
            self.accepted += 1
            self.held.append(c)
            // Stalled attempts: never start the connection, so the WebSocket
            // upgrade is never answered.
            guard self.accepted > self.stallFirst else { return }
            c.start(queue: .main)
            func rx() { c.receiveMessage { d, _, _, e in if d != nil { self.receivedConfigs += 1 }; if e == nil { rx() } } }
            rx()
        }
    }
    func start() async -> UInt16 {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { if case .ready = $0, once.claim() { cont.resume() } }
            listener.start(queue: .main)
        }
        return listener.port!.rawValue
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

var failures = 0
func check(_ ok: Bool, _ name: String) { print(ok ? "ok  " : "FAIL", name); if !ok { failures += 1 } }

@main struct HedgeTest {
    static func main() async throws {
        // 1. First handshake stalls; hedge at 300 ms wins.
        let s1 = try Server(stallFirst: 1)
        let p1 = await s1.start()
        var t = ContinuousClock.now
        let opened = try await SonioxProvider.openConfiguredSocketForTesting(
            endpoint: URL(string: "ws://127.0.0.1:\(p1)/")!, configuration: "{}",
            hedgeAfterNanoseconds: 300_000_000, deadlineNanoseconds: 2_000_000_000)
        var ms = Int(ProviderLivenessProbe.nanoseconds(t.duration(to: .now)) / 1_000_000)
        check(opened.hedged && opened.attempts == 2 && ms >= 300 && ms < 1_500, "第一条握手卡住时 300 ms 后对冲的第二条胜出（\(ms) ms，attempts=\(opened.attempts)）")
        opened.socket.cancel(with: .normalClosure, reason: nil)

        // 2. Normal: first attempt wins, no hedge.
        let s2 = try Server(stallFirst: 0)
        let p2 = await s2.start()
        t = .now
        let normal = try await SonioxProvider.openConfiguredSocketForTesting(
            endpoint: URL(string: "ws://127.0.0.1:\(p2)/")!, configuration: "{}",
            hedgeAfterNanoseconds: 300_000_000, deadlineNanoseconds: 2_000_000_000)
        ms = Int(ProviderLivenessProbe.nanoseconds(t.duration(to: .now)) / 1_000_000)
        try await Task.sleep(nanoseconds: 400_000_000)
        check(!normal.hedged && normal.attempts == 1 && s2.accepted == 1, "正常握手不对冲，只开一条（\(ms) ms，服务端连接数 \(s2.accepted)）")
        normal.socket.cancel(with: .normalClosure, reason: nil)

        // 3. Both stall: deadline error with the parsed text.
        let s3 = try Server(stallFirst: 9)
        let p3 = await s3.start()
        t = .now
        do {
            _ = try await SonioxProvider.openConfiguredSocketForTesting(
                endpoint: URL(string: "ws://127.0.0.1:\(p3)/")!, configuration: "{}",
                hedgeAfterNanoseconds: 300_000_000, deadlineNanoseconds: 1_000_000_000)
            check(false, "两条都卡住应超时")
        } catch {
            ms = Int(ProviderLivenessProbe.nanoseconds(t.duration(to: .now)) / 1_000_000)
            check(error.localizedDescription == "等待超时：Soniox 连接配置超过 1000 ms" && ms < 1_300 && s3.accepted == 2,
                  "两条都卡住：\(ms) ms 后报“\(error.localizedDescription)”，共开 \(s3.accepted) 条")
        }

        // 4. Refused port. With `waitsForConnectivity` on (kept so a press
        //    right after wake or a Wi-Fi roam can still connect), URLSession
        //    waits instead of failing; the hedged deadline must still bound it.
        let s4 = try Server(stallFirst: 0)
        let p4 = await s4.start()
        s4.listener.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        t = .now
        do {
            _ = try await SonioxProvider.openConfiguredSocketForTesting(
                endpoint: URL(string: "ws://127.0.0.1:\(p4)/")!, configuration: "{}",
                hedgeAfterNanoseconds: 300_000_000, deadlineNanoseconds: 1_000_000_000)
            check(false, "拒绝连接应失败")
        } catch {
            ms = Int(ProviderLivenessProbe.nanoseconds(t.duration(to: .now)) / 1_000_000)
            check(ms < 1_300, "端口拒绝：\(ms) ms 内结束，不超过建连时限（\(error.localizedDescription)）")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
