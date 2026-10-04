import AppKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import OSLog

struct WarmPreRollSnapshot: Sendable {
    let data: Data
    let throughSequence: Int64
}

private enum AudioEngineCandidateOutcome: Sendable {
    case started(AudioEngineCandidate)
    case failed(String)
    case quarantined
}

/// Owns one `AVAudioEngine.start()` call on a private serial queue.
///
/// CoreAudio can block `start()` for minutes while another application is
/// rebuilding an aggregate input device. The candidate therefore remains
/// detached from the active engine until the call returns inside our deadline.
/// A timed-out candidate is quarantined: it cannot publish audio, and a late
/// success only tears itself down.
private final class AudioEngineCandidate: @unchecked Sendable {
    let id = UUID()
    let engine = AVAudioEngine()
    let generation: UInt64
    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    private let controlQueue: DispatchQueue
    private let stateLock = NSLock()
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onStartCallReturned: @Sendable (UUID, Bool) -> Void
    private let maximumBufferedBeforeAcceptance = 512
    private var accepted = false
    private var flushingBufferedAudio = false
    private var quarantined = false
    private var cleanedUp = false
    private var prepared = false
    private var bufferedBeforeAcceptance: [AVAudioPCMBuffer] = []

    init(
        generation: UInt64,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onStartCallReturned: @escaping @Sendable (UUID, Bool) -> Void
    ) throws {
        self.generation = generation
        self.onBuffer = onBuffer
        self.onStartCallReturned = onStartCallReturned
        controlQueue = DispatchQueue(
            label: "\(AppIdentity.dataDirectoryName).AudioEngineCandidate.\(id.uuidString)",
            qos: .userInitiated
        )

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        guard channelCount > 0 else { throw WarmAudioEngine.AudioError.noInputChannels }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    /// Allocate the graph while idle without starting input I/O. This mirrors
    /// common recorder behavior: the next press avoids rebuilding the graph,
    /// while Continuity remains free because `engine.start()` is not called.
    func prepare() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in
                if !cleanedUp, !prepared {
                    engine.prepare()
                    prepared = true
                }
                continuation.resume()
            }
        }
    }

    func start() async -> AudioEngineCandidateOutcome {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in
                let outcome: AudioEngineCandidateOutcome
                do {
                    if !prepared {
                        engine.prepare()
                        prepared = true
                    }
                    try engine.start()
                    if isQuarantined {
                        cleanUpOnControlQueue()
                        outcome = .quarantined
                    } else {
                        outcome = .started(self)
                    }
                } catch {
                    cleanUpOnControlQueue()
                    outcome = .failed(error.localizedDescription)
                }
                onStartCallReturned(id, isQuarantined)
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Returns the count of PCM buffers that arrived while `engine.start()`
    /// was still returning. They are flushed before newer live buffers so the
    /// first spoken syllable cannot be dropped at the acceptance boundary.
    func accept() -> Int? {
        stateLock.lock()
        guard !quarantined else {
            stateLock.unlock()
            return nil
        }
        accepted = true
        flushingBufferedAudio = true
        stateLock.unlock()

        var flushedCount = 0
        while true {
            stateLock.lock()
            if quarantined {
                bufferedBeforeAcceptance.removeAll(keepingCapacity: false)
                flushingBufferedAudio = false
                stateLock.unlock()
                return nil
            }
            let batch = bufferedBeforeAcceptance
            bufferedBeforeAcceptance.removeAll(keepingCapacity: true)
            if batch.isEmpty {
                flushingBufferedAudio = false
                stateLock.unlock()
                return flushedCount
            }
            stateLock.unlock()

            flushedCount += batch.count
            for buffer in batch {
                onBuffer(buffer)
            }
        }
    }

    func quarantine(onCleanedUp: (@Sendable () -> Void)? = nil) {
        stateLock.lock()
        quarantined = true
        accepted = false
        flushingBufferedAudio = false
        bufferedBeforeAcceptance.removeAll(keepingCapacity: false)
        stateLock.unlock()

        // If `start()` is blocked this is queued behind it, deliberately. We
        // never call stop/reset concurrently with a wedged CoreAudio start.
        controlQueue.async { [self] in
            cleanUpOnControlQueue()
            onCleanedUp?()
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let copied = buffer.deepCopy() else { return }
        stateLock.lock()
        guard !quarantined else {
            stateLock.unlock()
            return
        }
        if !accepted || flushingBufferedAudio {
            if bufferedBeforeAcceptance.count < maximumBufferedBeforeAcceptance {
                bufferedBeforeAcceptance.append(copied)
            }
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        onBuffer(copied)
    }

    private var isQuarantined: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return quarantined
    }

    private func cleanUpOnControlQueue() {
        guard !cleanedUp else { return }
        cleanedUp = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }
}

final class WarmAudioEngine: ObservableObject, @unchecked Sendable {
    enum AudioError: LocalizedError {
        case microphoneDenied
        case noInputChannels
        case engineStartTimedOut
        case engineStartFailed(String)
        case firstAudioTimedOut
        case startAttemptsQuarantined
        case startSuperseded

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return String(localized: "麦克风权限未授予")
            case .noInputChannels: return String(localized: "当前没有可用的麦克风输入声道")
            case .engineStartTimedOut: return String(localized: "系统麦克风启动超时，正在等待音频设备释放")
            case let .engineStartFailed(message): return String(localized: "系统麦克风启动失败：\(message)")
            case .firstAudioTimedOut: return String(localized: "麦克风已连接但没有收到音频；请检查是否仍被电话或其他应用占用")
            case .startAttemptsQuarantined: return String(localized: "系统仍有卡住的麦克风启动请求，正在等待它们退出")
            case .startSuperseded: return String(localized: "麦克风启动已被更新的设备状态取代")
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    var onChunk: ((PCM16Chunk) -> Void)?

    private var activeEngine: AudioEngineCandidate?
    private var standbyEngine: AudioEngineCandidate?
    private var standbyPreparationTask: Task<Void, Never>?
    private var standbyRebuildTask: Task<Void, Never>?
    private var pendingCandidateCleanups = 0
    private let processingQueue = DispatchQueue(label: "\(AppIdentity.dataDirectoryName).AudioProcessing", qos: .userInteractive)
    private let converter = PCMConverter()
    private var ringBuffer: AudioRingBuffer
    private var sequence: Int64 = 0
    private var configurationObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration: UInt64 = 0
    private var watchdogTask: Task<Void, Never>?
    private var wantsToRun = false
    private let captureGenerationLock = NSLock()
    private var captureGeneration: UInt64 = 0
    private var outstandingStartAttemptIDs: Set<UUID> = []
    private let logger = Logger(
        subsystem: AppIdentity.bundleID,
        category: "AudioInput"
    )

    init(preRollMilliseconds: Int = 300) {
        let bytes = Int(PCMConverter.targetSampleRate) * 2 * preRollMilliseconds / 1_000
        ringBuffer = AudioRingBuffer(capacityBytes: bytes)
    }

    deinit {
        recoveryTask?.cancel()
        watchdogTask?.cancel()
        standbyPreparationTask?.cancel()
        standbyRebuildTask?.cancel()
        standbyEngine?.quarantine()
        activeEngine?.quarantine()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func setPreRoll(milliseconds: Int) {
        let bytes = Int(PCMConverter.targetSampleRate) * 2 * max(0, milliseconds) / 1_000
        ringBuffer.resize(capacityBytes: bytes)
    }

    func requestPermissionAndStart() async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            let previousActivationPolicy = await MainActor.run {
                let policy = NSApplication.shared.activationPolicy()
                _ = NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return policy
            }
            let shouldContinue = await MainActor.run {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = String(localized: "启用本地语音输入")
                alert.informativeText = String(localized: "\(AppIdentity.displayName) 需要麦克风来录制你的口述。声音默认只在这台 Mac 上交给本地 SenseVoice 识别。接下来 macOS 会再显示一次系统授权框。")
                alert.addButton(withTitle: String(localized: "继续"))
                alert.addButton(withTitle: String(localized: "暂不"))
                return alert.runModal() == .alertFirstButtonReturn
            }
            granted = shouldContinue
                ? await AVCaptureDevice.requestAccess(for: .audio)
                : false
            await MainActor.run {
                _ = NSApplication.shared.setActivationPolicy(previousActivationPolicy)
            }
        default:
            granted = false
        }
        guard granted else { throw AudioError.microphoneDenied }
        prepareForNewCapture()
        try await startWarm()
        try await waitForFirstAudio()
    }

    func startWarm() async throws {
        wantsToRun = true
        standbyRebuildTask?.cancel()
        standbyRebuildTask = nil
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        guard !isRunning else {
            ensureWatchdog()
            return
        }
        do {
            try await startFreshEngine()
            ensureWatchdog()
        } catch {
            scheduleRecovery(reason: .startFailed)
            throw error
        }
    }

    private func startFreshEngine(
        publishReady: Bool = true,
        requiredRecoveryGeneration: UInt64? = nil
    ) async throws {
        if activeEngine != nil {
            tearDownEngine()
        }
        guard outstandingStartAttemptIDs.count < AudioInputWatchdogPolicy.maximumOutstandingStartAttempts else {
            throw AudioError.startAttemptsQuarantined
        }

        let candidate: AudioEngineCandidate
        let engineGeneration: UInt64
        if requiredRecoveryGeneration == nil,
           let standbyEngine,
           isCurrentCaptureGeneration(standbyEngine.generation) {
            candidate = standbyEngine
            engineGeneration = standbyEngine.generation
            self.standbyEngine = nil
            standbyPreparationTask = nil
            logger.info("using prepared idle audio graph generation=\(engineGeneration, privacy: .public)")
        } else {
            discardStandbyEngine()
            engineGeneration = beginCaptureGeneration()
            candidate = try makeCandidate(
                generation: engineGeneration,
                publishReadyOnFirstFrame: publishReady
            )
        }
        outstandingStartAttemptIDs.insert(candidate.id)

        let startTask = Task<AudioEngineCandidateOutcome, Never> {
            await candidate.start()
        }
        let deadlineResult = await CompletionDeadline.wait(
            for: startTask,
            timeoutNanoseconds: AudioInputWatchdogPolicy.engineStartDeadlineNanoseconds,
            onTimeout: {
                candidate.quarantine()
            }
        )

        switch deadlineResult {
        case let .completed(.started(startedCandidate)):
            if Task.isCancelled || requiredRecoveryGeneration.map({ $0 != recoveryGeneration }) == true {
                startedCandidate.quarantine()
                throw AudioError.startSuperseded
            }
            guard let earlyBufferCount = startedCandidate.accept() else {
                startedCandidate.quarantine()
                throw AudioError.engineStartTimedOut
            }
            logger.info("audio candidate accepted with \(earlyBufferCount, privacy: .public) early buffers")
            activeEngine = startedCandidate
        case let .completed(.failed(message)):
            throw AudioError.engineStartFailed(message)
        case .completed(.quarantined), .timedOut:
            throw AudioError.engineStartTimedOut
        }

        // `AVAudioEngine.start()` is not a readiness signal. Startup becomes
        // ready on the first PCM callback from this exact generation; recovery
        // attempts are published only after their explicit 850 ms probe.
        isRunning = false
        lastError = nil
        observeConfigurationChanges()
        ensureWatchdog()
        logger.info("audio engine started: \(candidate.sampleRate, privacy: .public)Hz \(candidate.channelCount, privacy: .public)ch generation=\(engineGeneration, privacy: .public)")
    }

    func stop() {
        wantsToRun = false
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        standbyRebuildTask?.cancel()
        standbyRebuildTask = nil
        discardStandbyEngine()
        tearDownEngine()
        lastError = nil
        scheduleStandbyPreparationAfterCleanup()
    }

    func preRollSnapshot() -> WarmPreRollSnapshot {
        processingQueue.sync {
            WarmPreRollSnapshot(
                data: ringBuffer.snapshot(),
                throughSequence: sequence
            )
        }
    }

    func hasRecentAudioFrames(maxAgeNanoseconds: UInt64 = 2_500_000_000) -> Bool {
        guard isRunning else { return false }
        let lastFrame = processingQueue.sync { lastFrameUptimeNanoseconds }
        guard lastFrame > 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= lastFrame && now - lastFrame <= maxAgeNanoseconds
    }

    private var lastFrameUptimeNanoseconds: UInt64 = 0

    private func prepareForNewCapture() {
        processingQueue.sync {
            ringBuffer.clear()
            lastFrameUptimeNanoseconds = 0
        }
    }

    /// `AVAudioEngine.start()` may return before the device produces PCM. A
    /// dictation is ready only after a fresh callback from this capture.
    private func waitForFirstAudio(timeoutNanoseconds: UInt64 = 1_500_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while !hasRecentAudioFrames(maxAgeNanoseconds: timeoutNanoseconds) {
            try Task.checkCancellation()
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                stop()
                throw AudioError.firstAudioTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func process(
        _ buffer: AVAudioPCMBuffer,
        generation: UInt64,
        publishReadyOnFirstFrame: Bool
    ) {
        guard isCurrentCaptureGeneration(generation) else { return }
        do {
            let pcm = try converter.convert(buffer)
            guard isCurrentCaptureGeneration(generation) else { return }
            ringBuffer.append(pcm)
            sequence += 1
            lastFrameUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let chunk = PCM16Chunk(
                sequence: sequence,
                data: pcm,
                capturedAt: Date(),
                sampleRate: Int(PCMConverter.targetSampleRate),
                channels: 1
            )
            let measuredLevel = Self.rmsLevel(buffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentCaptureGeneration(generation) else { return }
                self.level = measuredLevel
                if publishReadyOnFirstFrame, !self.isRunning {
                    self.isRunning = true
                    self.lastError = nil
                    self.logger.info("audio input ready on first PCM generation=\(generation, privacy: .public)")
                }
            }
            onChunk?(chunk)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        guard let activeEngine else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: activeEngine.engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.wantsToRun else { return }
            self.scheduleRecovery(reason: .deviceChanged)
        }
    }

    private enum RecoveryReason {
        case startFailed
        case noContinuousFrames
        case deviceChanged
        case audioStreamStopped
        case notRunning
        case startRequestReleased

        /// Log text; never shown to the user.
        var logText: String {
            switch self {
            case .startFailed: return "麦克风启动失败" // l10n:ignore
            case .noContinuousFrames: return "检测到麦克风没有持续音频帧" // l10n:ignore
            case .deviceChanged: return "检测到输入设备变化" // l10n:ignore
            case .audioStreamStopped: return "检测到麦克风音频断流" // l10n:ignore
            case .notRunning: return "检测到麦克风未运行" // l10n:ignore
            case .startRequestReleased: return "系统麦克风启动请求已释放" // l10n:ignore
            }
        }

        var recoveringMessage: String {
            switch self {
            case .startFailed: return String(localized: "麦克风启动失败，正在恢复麦克风")
            case .noContinuousFrames: return String(localized: "检测到麦克风没有持续音频帧，正在恢复麦克风")
            case .deviceChanged: return String(localized: "检测到输入设备变化，正在恢复麦克风")
            case .audioStreamStopped: return String(localized: "检测到麦克风音频断流，正在恢复麦克风")
            case .notRunning: return String(localized: "检测到麦克风未运行，正在恢复麦克风")
            case .startRequestReleased: return String(localized: "系统麦克风启动请求已释放，正在恢复麦克风")
            }
        }
    }

    private func scheduleRecovery(reason: RecoveryReason) {
        recoveryGeneration &+= 1
        let scheduledGeneration = recoveryGeneration
        recoveryTask?.cancel()
        tearDownEngine()
        lastError = reason.recoveringMessage
        logger.error("audio recovery scheduled: \(reason.logText, privacy: .public)")
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var recoveryCycle = 0
            while self.wantsToRun,
                  self.recoveryGeneration == scheduledGeneration,
                  !Task.isCancelled {
                recoveryCycle += 1
                for (index, delay) in AudioInputRecoveryPolicy.delaysNanoseconds.enumerated() {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        return
                    }
                    guard self.wantsToRun,
                          self.recoveryGeneration == scheduledGeneration,
                          !Task.isCancelled else { return }

                    do {
                        let attemptSequence = self.processingQueue.sync { self.sequence }
                        try await self.startFreshEngine(
                            publishReady: false,
                            requiredRecoveryGeneration: scheduledGeneration
                        )
                        guard self.wantsToRun,
                              self.recoveryGeneration == scheduledGeneration,
                              !Task.isCancelled else { return }
                        // `AVAudioEngine.start()` can report success while the
                        // phone/Continuity aggregate is still not delivering
                        // input. A callback from this exact engine generation
                        // is the readiness contract; queued frames from the
                        // discarded engine are rejected in `process`.
                        try await Task.sleep(nanoseconds: AudioInputWatchdogPolicy.recoveryProbeNanoseconds)
                        guard self.wantsToRun,
                              self.recoveryGeneration == scheduledGeneration,
                              !Task.isCancelled else { return }
                        let currentSequence = self.processingQueue.sync { self.sequence }
                        if AudioInputRecoveryPolicy.receivedFreshFrame(
                            sequenceBeforeStart: attemptSequence,
                            sequenceAfterProbe: currentSequence
                        ) {
                            self.isRunning = true
                            self.lastError = nil
                            self.recoveryTask = nil
                            self.ensureWatchdog()
                            self.logger.info("audio engine recovered with fresh PCM on cycle=\(recoveryCycle, privacy: .public) attempt=\(index + 1, privacy: .public)")
                            return
                        }
                        self.tearDownEngine()
                        self.lastError = String(localized: "麦克风已连接但没有音频，正在重试（\(index + 1)/\(AudioInputRecoveryPolicy.delaysNanoseconds.count)）")
                        self.logger.error("audio recovery produced no PCM: cycle=\(recoveryCycle, privacy: .public) attempt=\(index + 1, privacy: .public)")
                    } catch {
                        guard self.wantsToRun,
                              self.recoveryGeneration == scheduledGeneration,
                              !Task.isCancelled else { return }
                        self.tearDownEngine()
                        self.lastError = String(localized: "音频设备尚未就绪，正在重试（\(index + 1)/\(AudioInputRecoveryPolicy.delaysNanoseconds.count)）：\(error.localizedDescription)")
                        self.logger.error("audio recovery start failed: cycle=\(recoveryCycle, privacy: .public) attempt=\(index + 1, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    }
                }

                guard self.wantsToRun,
                      self.recoveryGeneration == scheduledGeneration,
                      !Task.isCancelled else { return }
                self.lastError = String(localized: "系统输入设备仍未恢复；\(AppIdentity.displayName) 会继续自动重试")
                self.logger.error("audio recovery cycle exhausted; retrying after cooldown")
                do {
                    try await Task.sleep(nanoseconds: AudioInputWatchdogPolicy.recoveryCyclePauseNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func ensureWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousSequence = self.processingQueue.sync { self.sequence }
            var staleProbeCount = 0

            while self.wantsToRun, !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: AudioInputWatchdogPolicy.probeIntervalNanoseconds)
                } catch {
                    return
                }
                guard self.wantsToRun, !Task.isCancelled else { return }

                let currentSequence = self.processingQueue.sync { self.sequence }
                staleProbeCount = AudioInputWatchdogPolicy.nextStaleProbeCount(
                    engineClaimsRunning: self.isRunning,
                    previousSequence: previousSequence,
                    currentSequence: currentSequence,
                    previousStaleProbeCount: staleProbeCount
                )
                previousSequence = currentSequence

                if staleProbeCount >= AudioInputWatchdogPolicy.staleProbeLimit {
                    self.logger.error("audio watchdog detected a silent tap; forcing engine rebuild")
                    staleProbeCount = 0
                    self.scheduleRecovery(reason: .audioStreamStopped)
                } else if !self.isRunning, self.recoveryTask == nil {
                    self.scheduleRecovery(reason: .notRunning)
                }
            }
        }
    }

    private func tearDownEngine() {
        invalidateCaptureGeneration()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        let engineToStop = activeEngine
        activeEngine = nil
        if let engineToStop {
            quarantineCandidate(engineToStop)
        }
        processingQueue.sync {
            lastFrameUptimeNanoseconds = 0
        }
        isRunning = false
        level = 0
    }

    /// Builds and prepares the next graph without starting microphone I/O.
    /// The idle process therefore owns no active input stream, but the next
    /// Option press avoids graph construction on the first-word path.
    private func prepareStandbyEngine() {
        // Building the graph touches the input device, which makes macOS show the
        // microphone prompt. Before the user has allowed it (first run), wait for
        // the explicit request instead of prompting at launch.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              !wantsToRun,
              activeEngine == nil,
              standbyEngine == nil,
              pendingCandidateCleanups == 0,
              outstandingStartAttemptIDs.isEmpty else { return }
        let generation = beginCaptureGeneration()
        do {
            let candidate = try makeCandidate(
                generation: generation,
                publishReadyOnFirstFrame: true
            )
            standbyEngine = candidate
            standbyPreparationTask = Task(priority: .utility) {
                await candidate.prepare()
            }
        } catch {
            standbyEngine = nil
            standbyPreparationTask = nil
            logger.error("idle audio graph preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func discardStandbyEngine() {
        standbyPreparationTask?.cancel()
        standbyPreparationTask = nil
        if let standbyEngine {
            quarantineCandidate(standbyEngine)
        }
        standbyEngine = nil
    }

    /// CoreAudio may keep invoking the old tap briefly after `stop()` is
    /// requested. Constructing another AVAudioEngine graph during that drain
    /// window can race the IO thread and crash in a null callback. Every active
    /// or standby candidate therefore reports cleanup completion before a new
    /// idle graph is allowed to exist.
    private func quarantineCandidate(_ candidate: AudioEngineCandidate) {
        pendingCandidateCleanups += 1
        candidate.quarantine { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingCandidateCleanups = max(0, self.pendingCandidateCleanups - 1)
                self.scheduleStandbyPreparationAfterCleanup()
            }
        }
    }

    private func scheduleStandbyPreparationAfterCleanup() {
        guard !wantsToRun,
              activeEngine == nil,
              standbyEngine == nil,
              pendingCandidateCleanups == 0,
              outstandingStartAttemptIDs.isEmpty else { return }
        standbyRebuildTask?.cancel()
        standbyRebuildTask = Task { @MainActor [weak self] in
            // `AVAudioEngine.stop/reset` has returned, but the HAL IO thread can
            // retire one run-loop turn later. Keep graph construction outside
            // that final drain window without keeping microphone I/O active.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.standbyRebuildTask = nil
            self.prepareStandbyEngine()
        }
    }

    private func makeCandidate(
        generation: UInt64,
        publishReadyOnFirstFrame: Bool
    ) throws -> AudioEngineCandidate {
        try AudioEngineCandidate(
            generation: generation,
            onBuffer: { [weak self] copied in
                guard let self else { return }
                // 512 frames halves the visible meter/chunk cadence while
                // conversion remains on the dedicated processing queue.
                self.processingQueue.async { [weak self] in
                    self?.process(
                        copied,
                        generation: generation,
                        publishReadyOnFirstFrame: publishReadyOnFirstFrame
                    )
                }
            },
            onStartCallReturned: { [weak self] attemptID, returnedAfterQuarantine in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let wasOutstanding = self.outstandingStartAttemptIDs.remove(attemptID) != nil
                    guard returnedAfterQuarantine,
                          wasOutstanding,
                          self.wantsToRun,
                          self.activeEngine == nil else { return }
                    self.scheduleRecovery(reason: .startRequestReleased)
                }
            }
        )
    }

    private func beginCaptureGeneration() -> UInt64 {
        captureGenerationLock.lock()
        captureGeneration &+= 1
        let generation = captureGeneration
        captureGenerationLock.unlock()
        return generation
    }

    private func invalidateCaptureGeneration() {
        captureGenerationLock.lock()
        captureGeneration &+= 1
        captureGenerationLock.unlock()
    }

    private func isCurrentCaptureGeneration(_ generation: UInt64) -> Bool {
        captureGenerationLock.lock()
        let isCurrent = captureGeneration == generation
        captureGenerationLock.unlock()
        return isCurrent
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return min(1, max(0, rms * 8))
    }
}
