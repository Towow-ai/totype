import AVFoundation
import Foundation
import os

/// Microphone capture for a whole session: AVAudioSession + AVAudioEngine
/// input tap, converted to 16 kHz mono s16le with the macOS `PCMConverter`.
///
/// The engine is *armed* once in the foreground and keeps running between
/// dictations: iOS only lets a background app continue audio IO it already
/// has, so a running engine is what lets the keyboard start the next
/// dictation without opening the app. While no dictation is attached, PCM
/// goes into a ~1 s ring; `beginRecording` sends the last ~300 ms first so
/// the first syllable is not lost.
///
/// Threads: state flags and observers on the main thread; every
/// AVAudioSession activation and engine start/stop on `controlQueue` with a
/// 2 s deadline (CoreAudio's `start()` can block); the tap on the render
/// thread. `lock` guards what the render thread shares (handler, ring,
/// sequence) and the current engine reference.
final class AudioCapture: @unchecked Sendable {
    enum State: Sendable {
        case disarmed
        case running
        /// Interrupted by a call, Siri, another app's audio… The engine and
        /// tap are kept for `resume()`; the system stopped the IO.
        case suspended
    }

    enum CaptureEvent: Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// Input route or hardware format changed (headset unplugged,
        /// Bluetooth connected). The engine has stopped. Debounce first.
        case configurationChanged
        /// The engine is gone; never auto-recover.
        case mediaServicesReset
    }

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInput
        case timedOut
        case notArmed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有麦克风权限，请到 设置 → \(MobileIdentity.displayName) 打开麦克风"
            case .noInput: return "没有可用的麦克风输入"
            case .timedOut: return "音频系统 2 秒内没有响应"
            case .notArmed: return "会话没有在运行"
            }
        }
    }

    typealias ChunkHandler = @Sendable (PCM16Chunk, Float) -> Void
    typealias EventHandler = @Sendable (CaptureEvent) -> Void

    static let ringSeconds: TimeInterval = 1.0
    static let preRollSeconds: TimeInterval = 0.3
    /// Only audio captured this recently counts as pre-roll; older ring
    /// contents (for example from before a stall) are dropped.
    static let preRollMaximumAge: TimeInterval = 0.4
    static let controlDeadline: TimeInterval = 2
    private static let bytesPerSecond = 16_000 * 2

    private let controlQueue = DispatchQueue(label: MobileIdentity.label("audio-control"), qos: .userInitiated)
    private let lock = NSLock()
    private let log = Logger(subsystem: MobileIdentity.appBundleID, category: "audio")
    // Guarded by `lock`.
    private var engine: AVAudioEngine?
    private var eventHandler: EventHandler?
    private var chunkHandler: ChunkHandler?
    private var ring: [(data: Data, capturedAt: Date)] = []
    private var ringBytes = 0
    private var sequence: Int64 = 0
    private var preRollPending = false
    // Render-thread only.
    private let converter = PCMConverter()
    // Main thread.
    private var observers: [NSObjectProtocol] = []
    private(set) var state: State = .disarmed

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Activates the audio session and starts a fresh engine with no
    /// dictation attached. Needs the app in the foreground the first time:
    /// a background activation fails (`!int`, `!rec`).
    @MainActor
    func arm(mixWithOthers: Bool, onEvent: @escaping EventHandler) async throws {
        guard state == .disarmed else { return }
        let fresh = EngineBox(AVAudioEngine())
        install(fresh.engine, onEvent: onEvent)
        observeSession()
        do {
            try await control { [weak self] in
                let session = AVAudioSession.sharedInstance()
                var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
                if mixWithOthers { options.insert(.mixWithOthers) }
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: options)
                    try session.setActive(true)
                } catch {
                    SessionDiagnostics.log("audioSession.activate.failed", "where=arm error=\(Self.describe(error))")
                    throw error
                }
                SessionDiagnostics.log("audioSession.activated", "where=arm category=playAndRecord mix=\(mixWithOthers) route=\(Self.routeDescription())")
                try self?.installTapAndStart(fresh.engine, context: "arm")
            } onLate: { [weak self] in
                SessionDiagnostics.log("engine.stop", "why=lateArm")
                self?.stopEngine(fresh.engine)
            }
        } catch {
            log.error("arm failed: \(error.localizedDescription, privacy: .public)")
            SessionDiagnostics.log("arm.failed", "error=\(Self.describe(error))")
            disarm()
            throw error
        }
        state = .running
    }

    /// After an interruption: re-activate and restart the same engine.
    @MainActor
    func resume() async throws {
        guard state == .suspended, let engine = currentEngine else { throw CaptureError.notArmed }
        let current = EngineBox(engine)
        do {
            try await control {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    SessionDiagnostics.log("audioSession.activate.failed", "where=resume error=\(Self.describe(error))")
                    throw error
                }
                SessionDiagnostics.log("audioSession.activated", "where=resume route=\(Self.routeDescription())")
                if !current.engine.isRunning {
                    current.engine.prepare()
                    do {
                        try current.engine.start()
                    } catch {
                        SessionDiagnostics.log("engine.start.failed", "where=resume error=\(Self.describe(error))")
                        throw error
                    }
                }
                SessionDiagnostics.log("engine.start", "where=resume running=\(current.engine.isRunning)")
            } onLate: { [weak self] in
                SessionDiagnostics.log("engine.stop", "why=lateResume")
                self?.stopEngine(current.engine)
            }
        } catch {
            if case CaptureError.timedOut = error { SessionDiagnostics.log("resume.timedOut") }
            throw error
        }
        state = .running
    }

    /// Marks the IO as stopped by the system (interruption began). Keeps the
    /// engine so `resume()` can try again.
    @MainActor
    func suspend() {
        guard state == .running else { return }
        state = .suspended
        endRecording()
    }

    /// Attaches a dictation. The first chunk it receives is the pre-roll
    /// (when there is recent audio), then live buffers in order.
    func beginRecording(onChunk: @escaping ChunkHandler) {
        lock.lock()
        chunkHandler = onChunk
        sequence = 0
        preRollPending = true
        lock.unlock()
    }

    /// Detaches the dictation; the engine keeps running into the ring.
    func endRecording() {
        lock.lock()
        chunkHandler = nil
        preRollPending = false
        clearRing()
        lock.unlock()
    }

    /// Re-installs the tap with the new hardware format after a route change,
    /// off the main thread and within the deadline.
    @MainActor
    func restart() async throws {
        guard state == .running, let engine = currentEngine else { throw CaptureError.notArmed }
        let current = EngineBox(engine)
        try await control { [weak self] in
            SessionDiagnostics.log("engine.stop", "why=restart")
            current.engine.stop()
            current.engine.inputNode.removeTap(onBus: 0)
            try self?.installTapAndStart(current.engine, context: "restart")
        } onLate: { [weak self] in
            SessionDiagnostics.log("engine.stop", "why=lateRestart")
            self?.stopEngine(current.engine)
        }
    }

    /// The engine this session armed reports running. False between an
    /// unexpected stop and the configuration-change restart.
    var isEngineRunning: Bool {
        currentEngine?.isRunning ?? false
    }

    /// Port types only (no device names): `MicrophoneBuiltIn>Speaker`.
    static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: "+")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: "+")
        return "\(inputs.isEmpty ? "none" : inputs)>\(outputs.isEmpty ? "none" : outputs)"
    }

    /// `domain code` plus the OSStatus as four characters when it is one
    /// (`!int`, `!rec`, `cant`).
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain)#\(ns.code)"
        let code = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            text += "(\(String(decoding: bytes, as: UTF8.self)))"
        }
        return text
    }

    /// Stops and drops the engine and releases the audio session (the orange
    /// dot goes away and other apps' audio may resume). Never waits.
    @MainActor
    func disarm() {
        lock.lock()
        let old = engine.map(EngineBox.init)
        engine = nil
        chunkHandler = nil
        eventHandler = nil
        preRollPending = false
        clearRing()
        lock.unlock()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        state = .disarmed
        controlQueue.async {
            if let old {
                old.engine.inputNode.removeTap(onBus: 0)
                old.engine.stop()
                SessionDiagnostics.log("engine.stop", "why=disarm")
            }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                SessionDiagnostics.log("audioSession.deactivated")
            } catch {
                SessionDiagnostics.log("audioSession.deactivate.failed", "error=\(Self.describe(error))")
            }
        }
    }

    // MARK: Engine control

    private var currentEngine: AVAudioEngine? {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    /// Runs `work` on `controlQueue`. Throws `timedOut` after the deadline;
    /// if the work finishes after that, `onLate` undoes it.
    private func control(
        _ work: @escaping @Sendable () throws -> Void,
        onLate: @escaping @Sendable () -> Void
    ) async throws {
        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                let result = Result { try work() }
                if gate.claim() {
                    continuation.resume(with: result)
                } else if case .success = result {
                    onLate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.controlDeadline) {
                if gate.claim() { continuation.resume(throwing: CaptureError.timedOut) }
            }
        }
    }

    private func stopEngine(_ target: AVAudioEngine) {
        target.inputNode.removeTap(onBus: 0)
        target.stop()
    }

    private func install(_ fresh: AVAudioEngine, onEvent: @escaping EventHandler) {
        lock.lock()
        defer { lock.unlock() }
        engine = fresh
        eventHandler = onEvent
        chunkHandler = nil
        clearRing()
    }

    /// Called with `lock` held.
    private func clearRing() {
        ring.removeAll()
        ringBytes = 0
    }

    private func installTapAndStart(_ target: AVAudioEngine, context: String) throws {
        let input = target.inputNode
        // The session must be active before reading the format; a 0 Hz format
        // here would crash installTap.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            SessionDiagnostics.log("engine.start.failed", "where=\(context) error=noInput")
            throw CaptureError.noInput
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        target.prepare()
        do {
            try target.start()
        } catch {
            SessionDiagnostics.log("engine.start.failed", "where=\(context) error=\(Self.describe(error))")
            throw error
        }
        SessionDiagnostics.log("engine.start", "where=\(context) rate=\(Int(format.sampleRate)) ch=\(format.channelCount)")
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let data = try? converter.convert(buffer), !data.isEmpty else { return }
        let now = Date()
        var outgoing: [PCM16Chunk] = []
        lock.lock()
        let handler = chunkHandler
        if handler == nil {
            ring.append((data, now))
            ringBytes += data.count
            let limit = Int(Self.ringSeconds * Double(Self.bytesPerSecond))
            while ringBytes > limit, let first = ring.first {
                ringBytes -= first.data.count
                ring.removeFirst()
            }
        } else {
            if preRollPending {
                preRollPending = false
                if let preRoll = takePreRoll(now: now) {
                    sequence += 1
                    outgoing.append(Self.chunk(sequence, preRoll.data, preRoll.capturedAt))
                }
            }
            sequence += 1
            outgoing.append(Self.chunk(sequence, data, now))
        }
        lock.unlock()
        guard let handler else { return }
        for chunk in outgoing {
            handler(chunk, Self.normalizedLevel(chunk.data))
        }
    }

    /// Called with `lock` held. Returns the newest ≤300 ms of recent ring
    /// audio as one chunk and empties the ring.
    private func takePreRoll(now: Date) -> (data: Data, capturedAt: Date)? {
        defer {
            ring.removeAll()
            ringBytes = 0
        }
        let recent = ring.filter { now.timeIntervalSince($0.capturedAt) <= Self.preRollMaximumAge }
        guard let first = recent.first else { return nil }
        var joined = Data()
        for item in recent { joined.append(item.data) }
        // Keep whole 16-bit samples.
        let wanted = Int(Self.preRollSeconds * Double(Self.bytesPerSecond)) & ~1
        let data = joined.count > wanted ? joined.suffix(wanted) : joined
        guard !data.isEmpty else { return nil }
        let duration = Double(data.count) / Double(Self.bytesPerSecond)
        let capturedAt = max(first.capturedAt, now.addingTimeInterval(-duration))
        return (Data(data), capturedAt)
    }

    private static func chunk(_ sequence: Int64, _ data: Data, _ capturedAt: Date) -> PCM16Chunk {
        PCM16Chunk(sequence: sequence, data: data, capturedAt: capturedAt, sampleRate: 16_000, channels: 1)
    }

    @MainActor
    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                let reason = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                self.log.notice("interruption began, reason \(reason ?? 0, privacy: .public)")
                // Reasons: 0 default (another app / call / Siri), 1
                // appWasSuspended, 2 builtInMicMuted, 3 routeDisconnected.
                SessionDiagnostics.log(
                    "interruption.began",
                    "reason=\(reason.map(String.init) ?? "nil") engineRunning=\(self.isEngineRunning) otherAudio=\(session.isOtherAudioPlaying)"
                )
                self.emit(.interruptionBegan)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                )
                self.log.notice("interruption ended, shouldResume \(options.contains(.shouldResume), privacy: .public)")
                SessionDiagnostics.log("interruption.ended", "shouldResume=\(options.contains(.shouldResume))")
                self.emit(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })
        // Logged only; restarts are driven by the engine's configuration
        // change notification.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self?.log.notice("route change, reason \(reason, privacy: .public)")
            SessionDiagnostics.log(
                "route.change",
                "reason=\(reason) route=\(Self.routeDescription()) engineRunning=\(self?.isEngineRunning ?? false)"
            )
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let source = notification.object as? AVAudioEngine,
                  source === self.currentEngine else { return }
            SessionDiagnostics.log("engine.configurationChange", "running=\(source.isRunning) route=\(Self.routeDescription())")
            self.emit(.configurationChanged)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: session,
            queue: .main
        ) { _ in
            SessionDiagnostics.log("mediaServices.lost")
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            SessionDiagnostics.log("mediaServices.reset")
            self?.emit(.mediaServicesReset)
        })
    }

    private func emit(_ event: CaptureEvent) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }

    /// RMS of s16le samples mapped from -50…0 dBFS to 0…1.
    private static func normalizedLevel(_ data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let value = Double(sample) / Double(Int16.max)
                sum += value * value
            }
        }
        let rms = (sum / Double(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return Float(min(1, max(0, (decibels + 50) / 50)))
    }
}

/// One-shot flag shared by a control operation and its deadline.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Hands an engine to `controlQueue`. AVAudioEngine is not Sendable; all
/// starts and stops on it happen on that one serial queue.
private struct EngineBox: @unchecked Sendable {
    let engine: AVAudioEngine

    init(_ engine: AVAudioEngine) {
        self.engine = engine
    }
}
