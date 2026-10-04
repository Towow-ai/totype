import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Global trigger-key / Escape monitor. The trigger is a single tap of one
/// modifier key (right Option by default; see `TriggerKey`).
///
/// Both event taps live on a dedicated run-loop thread, never on the main
/// thread. A tap serviced by the main run loop inherits every SwiftUI/AppKit
/// stall; macOS then delays the user's keystrokes or disables the tap and the
/// trigger press that ends a recording is silently lost.
///
/// The modifier tap subscribes to flagsChanged only and never consumes an
/// event, so ordinary typing (including input-method composition) never passes
/// through this process. The Escape tap is the only one that consumes events
/// and exists only while a recording is starting or listening.
///
/// Switching the trigger key only swaps the key code and device masks the
/// detector compares against; the tap already receives every flagsChanged
/// event and is not recreated.
///
/// The modifier tap is an active (`.defaultTap`) flagsChanged tap, which
/// Accessibility authorises. The Escape tap is different: any tap that receives
/// keyDown needs Input Monitoring (`kTCCServiceListenEvent`). When that grant is
/// missing or pinned to an obsolete code identity (the personal machine's record
/// pointed at an August ad-hoc cdhash until 2026-10-01), a keyDown-only tap is
/// refused, and a tap with a wider mask is created but keyDown is silently
/// filtered out of it. Escape cancellation is therefore reported as available
/// only when Input Monitoring preflights and a keyDown-only tap can be created;
/// there is no wider-mask fallback that would hide the missing grant.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// Called on the main thread whenever the Escape self-check changes its answer
    /// (and once after the first check).
    var onEscapeCancelAvailabilityChanged: ((Bool) -> Void)?

    static let escapeKeyCode: Int64 = 53

    private let tapThread = EventTapThread()
    // Accessed only on `tapThread`.
    private var modifierTap: CFMachPort?
    private var modifierSource: CFRunLoopSource?
    private var escapeTap: CFMachPort?
    private var escapeSource: CFRunLoopSource?
    private var healthTimer: CFRunLoopTimer?

    // Accessed only on the main thread.
    private var globalFallback: Any?
    private var localFallback: Any?
    private var isStarted = false

    // Per-recording Escape tap health, accessed only on `tapThread`. Logged once
    // when capture is disarmed; no key codes are recorded.
    private var escapeSessionArmed = false
    private var escapeSessionTapCreated = false
    private var escapeSessionKeyDowns = 0
    private var escapeSessionEscapeCaptured = false
    private var escapeSessionReenables = 0

    private var escapeAvailability: Bool?
    private let escapeAvailabilityLock = NSLock()

    // Device masks matter: `.maskAlternate` is shared by both Option keys, so
    // with left Option held, releasing right Option would still read as
    // "pressed". `ModifierKeySpec` compares the `NX_DEVICE*KEYMASK` bits.
    private var tapDetector = ModifierTapDetector(key: TriggerKey.rightOption.modifierKeySpec)
    private let tapDetectorLock = NSLock()
    private var cancelCaptureActive = false
    private let cancelCaptureLock = NSLock()
    private let logger = Logger(
        subsystem: AppIdentity.bundleID,
        category: "Hotkey"
    )

    static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Changes the trigger key at once. The flagsChanged tap stays as it is;
    /// only the detector's key code and device masks change.
    func setTriggerKey(_ key: TriggerKey) {
        tapDetectorLock.lock()
        let changed = tapDetector.key != key.modifierKeySpec
        if changed { tapDetector.setKey(key.modifierKeySpec) }
        tapDetectorLock.unlock()
        if changed { logger.notice("trigger key set to \(key.rawValue, privacy: .public)") }
    }

    /// Latest Escape self-check result; false until the first check has run.
    var isEscapeCancelAvailable: Bool {
        escapeAvailabilityLock.lock()
        defer { escapeAvailabilityLock.unlock() }
        return escapeAvailability ?? false
    }

    /// Re-runs the Escape self-check on the tap thread. While a recording holds
    /// the Escape tap, that tap is the live answer and the probe is skipped.
    func refreshEscapeCancelAvailability() {
        tapThread.perform { [weak self] in
            self?.probeEscapeCancelOnTapThread()
        }
    }

    /// Arms exclusive Escape capture only while an utterance is actively being
    /// recorded. Arming installs the active keyDown tap; disarming removes it.
    func setCancelCaptureActive(_ active: Bool) {
        cancelCaptureLock.lock()
        let changed = cancelCaptureActive != active
        cancelCaptureActive = active
        cancelCaptureLock.unlock()
        guard changed else { return }
        tapThread.perform { [weak self] in
            guard let self else { return }
            if self.isCancelCaptureActive {
                self.installEscapeTapOnTapThread()
            } else {
                self.removeEscapeTapOnTapThread()
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NSLog(
            "[VerbatimVoice] hotkey start: inputMonitoring=%@",
            Self.hasInputMonitoringAccess ? "yes" : "no"
        )
        var created = false
        tapThread.performAndWait { [weak self] in
            created = self?.installModifierTapOnTapThread() ?? false
            if created, self?.isCancelCaptureActive == true {
                self?.installEscapeTapOnTapThread()
            } else {
                self?.probeEscapeCancelOnTapThread()
            }
        }
        if created {
            logger.notice("hotkey backend active: flagsChanged CGEventTap on dedicated thread")
            return
        }

        // Only install the fallback when the primary tap cannot be created.
        // Running both backends concurrently produced two accepted presses
        // 157-159 ms apart and ended a new recording before its first PCM.
        installNSEventFallback()
        logger.error("hotkey backend fallback: NSEvent only")
        onFailure?(String(localized: "无法创建全局事件监听，已切换到 NSEvent fallback；请检查辅助功能/输入监控权限"))
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        tapThread.performAndWait { [weak self] in
            self?.removeEscapeTapOnTapThread()
            self?.removeModifierTapOnTapThread()
        }
        if let globalFallback { NSEvent.removeMonitor(globalFallback) }
        if let localFallback { NSEvent.removeMonitor(localFallback) }
        globalFallback = nil
        localFallback = nil
        isStarted = false
        tapDetectorLock.lock()
        tapDetector.reset()
        tapDetectorLock.unlock()
        setCancelCaptureActive(false)
    }

    // MARK: - Tap thread

    private var isCancelCaptureActive: Bool {
        cancelCaptureLock.lock()
        defer { cancelCaptureLock.unlock() }
        return cancelCaptureActive
    }

    private func installModifierTapOnTapThread() -> Bool {
        guard modifierTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Accessibility-authorised; the callback always passes the event on.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handleModifierTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            logger.error("modifier tap created but not enabled by the system")
            return false
        }
        modifierTap = tap
        modifierSource = source
        installHealthTimerOnTapThread()
        return true
    }

    private func removeModifierTapOnTapThread() {
        if let healthTimer {
            CFRunLoopTimerInvalidate(healthTimer)
        }
        healthTimer = nil
        if let modifierSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), modifierSource, .commonModes)
        }
        if let modifierTap {
            CGEvent.tapEnable(tap: modifierTap, enable: false)
            CFMachPortInvalidate(modifierTap)
        }
        modifierTap = nil
        modifierSource = nil
    }

    private func installEscapeTapOnTapThread() {
        guard escapeTap == nil else { return }
        escapeSessionArmed = true
        escapeSessionTapCreated = false
        escapeSessionKeyDowns = 0
        escapeSessionEscapeCaptured = false
        escapeSessionReenables = 0
        guard modifierTap != nil else { return }
        // Escape capture is keyDown-only. A refused keyDown tap means Input
        // Monitoring is missing; a wider mask would be accepted but would never
        // see keyDown, so there is deliberately no fallback mask.
        guard Self.hasInputMonitoringAccess, let tap = makeEscapeTap() else {
            recordEscapeCancelAvailability(false, logAlways: true)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(tap)
            recordEscapeCancelAvailability(false, logAlways: true)
            return
        }
        escapeTap = tap
        escapeSource = source
        escapeSessionTapCreated = true
        recordEscapeCancelAvailability(true, logAlways: false)
        logger.notice("escape tap active (keyDown)")
    }

    /// Escape self-check: Input Monitoring preflights and a keyDown-only active
    /// tap can be created. The probe tap is disabled and destroyed at once and is
    /// never attached to a run loop. Without the preflight no tap is attempted.
    private func probeEscapeCancelOnTapThread() {
        guard escapeTap == nil else { return }
        var available = false
        if Self.hasInputMonitoringAccess, let probe = makeEscapeTap() {
            available = CGEvent.tapIsEnabled(tap: probe)
            CGEvent.tapEnable(tap: probe, enable: false)
            CFMachPortInvalidate(probe)
        }
        recordEscapeCancelAvailability(available, logAlways: false)
    }

    private func recordEscapeCancelAvailability(_ available: Bool, logAlways: Bool) {
        escapeAvailabilityLock.lock()
        let changed = escapeAvailability != available
        escapeAvailability = available
        escapeAvailabilityLock.unlock()
        if !available, changed || logAlways {
            logger.error("escape cancel unavailable: input monitoring not granted")
        } else if available, changed {
            logger.notice("escape cancel available: input monitoring granted, keyDown tap accepted")
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onEscapeCancelAvailabilityChanged?(available)
        }
    }

    private func makeEscapeTap() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A listen-only tap cannot stop Escape from reaching the target
            // application. This active tap exists only while recording.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEscapeTap(type: type, event: event)
                    ? nil
                    : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func removeEscapeTapOnTapThread() {
        if escapeSessionArmed {
            escapeSessionArmed = false
            let enabledAtEnd = escapeTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            logger.notice(
                "escape session: tapActive=\(self.escapeSessionTapCreated, privacy: .public) enabledAtEnd=\(enabledAtEnd, privacy: .public) keyDownSeen=\(self.escapeSessionKeyDowns > 0, privacy: .public) keyDowns=\(self.escapeSessionKeyDowns, privacy: .public) escapeCaptured=\(self.escapeSessionEscapeCaptured, privacy: .public) reenables=\(self.escapeSessionReenables, privacy: .public)"
            )
        }
        if let escapeSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), escapeSource, .commonModes)
        }
        if let escapeTap {
            CGEvent.tapEnable(tap: escapeTap, enable: false)
            CFMachPortInvalidate(escapeTap)
        }
        escapeTap = nil
        escapeSource = nil
    }

    /// macOS can disable a tap without delivering the disabled event (for
    /// example after a secure-input session). Re-check every few seconds.
    private func installHealthTimerOnTapThread() {
        guard healthTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 5,
            5,
            0,
            0
        ) { [weak self] _ in
            guard let self, let tap = self.modifierTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                self.logger.notice("modifier tap found disabled; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if let escapeTap = self.escapeTap, !CGEvent.tapIsEnabled(tap: escapeTap) {
                self.escapeSessionReenables += 1
                CGEvent.tapEnable(tap: escapeTap, enable: true)
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        healthTimer = timer
    }

    private func handleModifierTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.notice("modifier tap disabled by system (type \(type.rawValue, privacy: .public)); re-enabling")
            if let modifierTap { CGEvent.tapEnable(tap: modifierTap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }
        // Every modifier's flagsChanged goes to the detector so another
        // modifier can interrupt a tap. Read the state from the event being
        // delivered: CGEventSource.keyState can lag behind flagsChanged on some
        // keyboards/layouts and turn a real press into a no-op.
        transition(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            rawFlags: event.flags.rawValue
        )
    }

    /// Returns true only when the event must be consumed by the active tap.
    private func handleEscapeTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.notice("escape tap disabled by system; re-enabling")
            escapeSessionReenables += 1
            if let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: true) }
            return false
        }
        if type == .keyDown { escapeSessionKeyDowns += 1 }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode,
              isCancelCaptureActive else { return false }
        escapeSessionEscapeCaptured = true
        logger.notice("Escape captured exclusively for active recording")
        DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        return true
    }

    // MARK: - Shared edge handling

    /// NSEvent global monitors cannot suppress delivery. They therefore never
    /// route Escape cancellation. A local monitor may consume it when the app
    /// itself is frontmost, preserving the same exclusive contract.
    private func handle(_ event: NSEvent, canConsumeCancel: Bool) -> Bool {
        if event.type == .keyDown, Int64(event.keyCode) == Self.escapeKeyCode {
            guard canConsumeCancel, isCancelCaptureActive else { return false }
            logger.notice("Escape captured by local monitor for active recording")
            onCancel?()
            return true
        }
        guard event.type == .flagsChanged else { return false }
        transition(keyCode: Int64(event.keyCode), rawFlags: UInt64(event.modifierFlags.rawValue))
        return false
    }

    private func transition(keyCode: Int64, rawFlags: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        tapDetectorLock.lock()
        let observation = tapDetector.observe(
            keyCode: keyCode,
            rawFlags: rawFlags,
            nowNanoseconds: now,
            lastOtherInput: { Self.lastOtherInputNanoseconds(now: now) }
        )
        tapDetectorLock.unlock()
        switch observation {
        case .tap:
            logger.notice("trigger press accepted")
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        case .released:
            logger.debug("trigger released")
        case .rejected(.duplicate):
            logger.notice("trigger edge ignored as duplicate")
        case .pressStarted:
            logger.debug("trigger down")
        case .pressRestarted:
            logger.notice("trigger down again without an up event; press restarted")
        case .rejected(let reason):
            logger.notice("trigger release ignored: \(String(describing: reason), privacy: .public)")
        case .unrelated:
            break
        }
    }

    /// Latest physical key or mouse-button press, on the `DispatchTime` uptime
    /// clock. A flagsChanged-only tap never sees these events, so the HID
    /// system state answers whether one happened while a release-mode trigger
    /// was down. The detector asks only on such a key's up event.
    /// Scrolling is left out: trackpad momentum keeps posting scroll events
    /// after the fingers lift and would swallow the tap that ends a recording.
    private static func lastOtherInputNanoseconds(now: UInt64) -> UInt64? {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let seconds = types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let elapsed = seconds * 1_000_000_000
        guard elapsed < Double(now) else { return nil }
        return now - UInt64(elapsed)
    }

    private func installNSEventFallback() {
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalFallback = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            _ = self?.handle(event, canConsumeCancel: false)
        }
        localFallback = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            let consumed = self?.handle(event, canConsumeCancel: true) ?? false
            return consumed ? nil : event
        }
    }
}

extension TriggerKey {
    var modifierKeySpec: ModifierKeySpec {
        switch self {
        case .rightOption: return .rightOption
        case .rightCommand: return .rightCommand
        case .leftOption: return .leftOption
        case .leftControl: return .leftControl
        case .function: return .function
        }
    }
}

/// A thread that owns a CFRunLoop for event taps, isolated from main-thread stalls.
private final class EventTapThread: Thread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "\(AppIdentity.bundleID).event-tap"
        qualityOfService = .userInteractive
        start()
        ready.wait()
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // Keep the run loop alive while no tap source is installed.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func performAndWait(_ block: @escaping () -> Void) {
        if Thread.current == self {
            block()
            return
        }
        let done = DispatchSemaphore(value: 0)
        perform {
            block()
            done.signal()
        }
        done.wait()
    }
}
