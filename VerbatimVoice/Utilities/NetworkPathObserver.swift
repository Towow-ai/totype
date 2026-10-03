import CFNetwork
import Foundation
import Network

/// Long-lived `NWPathMonitor` whose latest path is stamped on each dictation
/// (history `networkPath`). Reading it never blocks the recording path: the
/// snapshot is computed on the monitor queue when the path changes, and the
/// system proxy settings are refreshed there too.
final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "\(AppIdentity.dataDirectoryName).network-path", qos: .utility)
    private let lock = NSLock()
    private var latest: NetworkPathSnapshot?
    private var generation: UInt64 = 0
    private var started = false

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// The latest path and a generation that increases on every change.
    func current() -> (snapshot: NetworkPathSnapshot?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (latest, generation)
    }

    /// Proxy toggles do not always change the path; re-read them off-main
    /// whenever a dictation starts, for the next record.
    func refreshProxySettings() {
        queue.async { [weak self] in
            guard let self else { return }
            let proxy = Self.systemProxyEnabled()
            self.lock.lock()
            if var snapshot = self.latest, snapshot.systemProxy != proxy {
                snapshot.systemProxy = proxy
                self.latest = snapshot
            }
            self.lock.unlock()
        }
    }

    private func update(_ path: NWPath) {
        let interfaces = path.availableInterfaces
        let names = interfaces.prefix(4).map(\.name)
        let tunnel = interfaces.first.map { NetworkPathSnapshot.isTunnelInterfaceName($0.name) }
        let physical = interfaces.first { !NetworkPathSnapshot.isTunnelInterfaceName($0.name) }
        let interface: String
        switch physical?.type ?? interfaces.first?.type {
        case .wifi?: interface = "wifi"
        case .cellular?: interface = "cellular"
        case .wiredEthernet?: interface = "wired"
        case .loopback?: interface = "loopback"
        case .other?: interface = "other"
        case nil: interface = "none"
        @unknown default: interface = "other"
        }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        let snapshot = NetworkPathSnapshot(
            status: status,
            interface: interface,
            interfaceNames: names,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            systemProxy: Self.systemProxyEnabled(),
            tunnelInterface: tunnel
        )
        lock.lock()
        latest = snapshot
        generation &+= 1
        lock.unlock()
    }

    private static func systemProxyEnabled() -> Bool? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"] {
            if (settings[key] as? NSNumber)?.boolValue == true { return true }
        }
        return false
    }
}
