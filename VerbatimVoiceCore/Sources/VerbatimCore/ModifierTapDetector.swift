import Foundation

/// When a single press of the trigger key toggles recording.
public enum ModifierTriggerEdge: Equatable, Sendable {
    /// On the way down, exactly as right Option always has: no combination
    /// filter and no hold limit. Right Option is rarely part of a shortcut.
    case press
    /// On the way up, and only if nothing else was pressed meanwhile. Command,
    /// left Option, left Control and Fn are everyday shortcut keys, so knowing
    /// that the press was not Command+C is worth starting a tap's length later.
    case release
}

/// One modifier key that can serve as the single-tap trigger, described by the
/// values a `flagsChanged` event carries: the virtual key code, the shared
/// family flag (`CGEventFlags.mask*`) and the `NX_DEVICE*KEYMASK` bits that tell
/// the left and right keys of that family apart.
public struct ModifierKeySpec: Equatable, Sendable {
    public let keyCode: Int64
    public let familyFlag: UInt64
    /// Zero for Fn, which has no left/right device bit.
    public let deviceMask: UInt64
    public let siblingDeviceMask: UInt64
    public let triggerOn: ModifierTriggerEdge

    public init(
        keyCode: Int64,
        familyFlag: UInt64,
        deviceMask: UInt64,
        siblingDeviceMask: UInt64,
        triggerOn: ModifierTriggerEdge
    ) {
        self.keyCode = keyCode
        self.familyFlag = familyFlag
        self.deviceMask = deviceMask
        self.siblingDeviceMask = siblingDeviceMask
        self.triggerOn = triggerOn
    }

    // `CGEventFlags` raw values, spelled out so this file needs no CoreGraphics.
    public static let shiftFlag: UInt64 = 0x0002_0000
    public static let controlFlag: UInt64 = 0x0004_0000
    public static let optionFlag: UInt64 = 0x0008_0000
    public static let commandFlag: UInt64 = 0x0010_0000
    public static let functionFlag: UInt64 = 0x0080_0000

    public static let rightOption = ModifierKeySpec(
        keyCode: 61, familyFlag: optionFlag, deviceMask: 0x40, siblingDeviceMask: 0x20, triggerOn: .press
    )
    public static let leftOption = ModifierKeySpec(
        keyCode: 58, familyFlag: optionFlag, deviceMask: 0x20, siblingDeviceMask: 0x40, triggerOn: .release
    )
    public static let rightCommand = ModifierKeySpec(
        keyCode: 54, familyFlag: commandFlag, deviceMask: 0x10, siblingDeviceMask: 0x08, triggerOn: .release
    )
    public static let leftControl = ModifierKeySpec(
        keyCode: 59, familyFlag: controlFlag, deviceMask: 0x01, siblingDeviceMask: 0x2000, triggerOn: .release
    )
    /// Fn / Globe (`kVK_Function`).
    public static let function = ModifierKeySpec(
        keyCode: 63, familyFlag: functionFlag, deviceMask: 0, siblingDeviceMask: 0, triggerOn: .release
    )

    /// Whether this key is down according to one event's raw flags. The shared
    /// family flag stays set while the key on the other side is held, so the
    /// device bit decides. Some keyboards and remappers set no device bits at
    /// all; only then does the family flag stand in.
    public func isDown(rawFlags: UInt64) -> Bool {
        let deviceBits = deviceMask | siblingDeviceMask
        if deviceBits == 0 || rawFlags & deviceBits == 0 {
            return rawFlags & familyFlag != 0
        }
        return rawFlags & deviceMask != 0
    }

    /// Another modifier is held: a different family, or the other side of this
    /// one. Caps Lock, numeric-pad and Fn bits are ignored here because they
    /// can stay set without a modifier being held (an Fn key press during the
    /// tap still interrupts it through its own flagsChanged event).
    public func otherModifierHeld(rawFlags: UInt64) -> Bool {
        let families = Self.shiftFlag | Self.controlFlag | Self.optionFlag | Self.commandFlag
        if rawFlags & families & ~familyFlag != 0 { return true }
        return siblingDeviceMask != 0 && rawFlags & siblingDeviceMask != 0
    }
}

public enum ModifierTapObservation: Equatable, Sendable {
    /// Toggle recording: an accepted press (`.press` keys) or a clean single
    /// tap (`.release` keys).
    case tap
    /// `.press` keys: the key went up; nothing to do.
    case released
    /// `.release` keys: the key went down and is being watched.
    case pressStarted
    /// The trigger went down while already down: the previous modifier-up was
    /// lost, and this press starts over.
    case pressRestarted
    case rejected(ModifierTapRejection)
    /// Another key's transition, or a release with no press on record.
    case unrelated
}

public enum ModifierTapRejection: Equatable, Sendable {
    /// Another modifier, key or mouse button was used while the trigger was down.
    case combined
    case heldTooLong
    /// Within `duplicateWindowNanoseconds` of the last accepted tap, or (for
    /// `.press` keys) a repeated edge.
    case duplicate
    /// Another modifier's event shows the trigger already up: its own up event
    /// was lost, and the press is dropped rather than guessed at.
    case releaseMissed
}

/// Turns the `flagsChanged` stream into single taps of one modifier key.
///
/// `.press` keys go through `ModifierPressEdgePolicy` unchanged, fed only the
/// trigger's own events, exactly as the right-Option monitor always did.
///
/// `.release` keys accept a tap on the way up, because only then is it known
/// that no other key joined it: Command+C, Option+arrow or Control+click must
/// not toggle recording. Every `flagsChanged` event is fed in, so another
/// modifier pressed during the tap interrupts it. Ordinary key and mouse
/// presses never reach a flagsChanged-only tap; `lastOtherInput` reads the
/// latest one from the HID system state, and is called only on a `.release`
/// key's up event.
public struct ModifierTapDetector: Sendable {
    /// `.release` keys: a second tap inside this window is a bounce of the same
    /// physical press. Same window as `ModifierPressEdgePolicy`.
    public static let duplicateWindowNanoseconds: UInt64 = ModifierPressEdgePolicy.duplicateWindowNanoseconds

    /// `.release` keys: a press held longer than this is not a tap (the user
    /// held Command and changed their mind). Generous, so that a slow press
    /// that ends a recording is never mistaken for a hold.
    public static let maximumTapNanoseconds: UInt64 = 1_000_000_000

    public private(set) var key: ModifierKeySpec
    private var pressEdges = ModifierPressEdgePolicy()
    private var pressStartedNanoseconds: UInt64?
    private var combined = false
    private var lastTapNanoseconds: UInt64?

    public init(key: ModifierKeySpec) {
        self.key = key
    }

    /// Switches the trigger. Any press in progress is forgotten.
    public mutating func setKey(_ key: ModifierKeySpec) {
        self.key = key
        reset()
    }

    public mutating func reset() {
        pressEdges.reset()
        pressStartedNanoseconds = nil
        combined = false
        lastTapNanoseconds = nil
    }

    /// - Parameter lastOtherInput: when the latest physical key or mouse
    ///   button went down, on the same clock as `nowNanoseconds`; nil when
    ///   unknown. Only consulted when a `.release` key goes up.
    public mutating func observe(
        keyCode: Int64,
        rawFlags: UInt64,
        nowNanoseconds: UInt64,
        lastOtherInput: () -> UInt64? = { nil }
    ) -> ModifierTapObservation {
        switch key.triggerOn {
        case .press:
            return observePress(keyCode: keyCode, rawFlags: rawFlags, nowNanoseconds: nowNanoseconds)
        case .release:
            return observeRelease(
                keyCode: keyCode, rawFlags: rawFlags, nowNanoseconds: nowNanoseconds, lastOtherInput: lastOtherInput
            )
        }
    }

    private mutating func observePress(keyCode: Int64, rawFlags: UInt64, nowNanoseconds: UInt64) -> ModifierTapObservation {
        guard keyCode == key.keyCode else { return .unrelated }
        switch pressEdges.observe(pressed: key.isDown(rawFlags: rawFlags), nowNanoseconds: nowNanoseconds) {
        case .acceptedPress: return .tap
        case .release: return .released
        case .ignoredDuplicate: return .rejected(.duplicate)
        }
    }

    private mutating func observeRelease(
        keyCode: Int64,
        rawFlags: UInt64,
        nowNanoseconds: UInt64,
        lastOtherInput: () -> UInt64?
    ) -> ModifierTapObservation {
        guard keyCode == key.keyCode else {
            guard pressStartedNanoseconds != nil else { return .unrelated }
            guard key.isDown(rawFlags: rawFlags) else {
                pressStartedNanoseconds = nil
                combined = false
                return .rejected(.releaseMissed)
            }
            combined = true
            return .unrelated
        }

        if key.isDown(rawFlags: rawFlags) {
            // Accept a new press even while one is on record. This is the
            // recovery path for a missing modifier-up event: the stale press is
            // replaced instead of latching and swallowing every later tap.
            let restarted = pressStartedNanoseconds != nil
            pressStartedNanoseconds = nowNanoseconds
            combined = key.otherModifierHeld(rawFlags: rawFlags)
            return restarted ? .pressRestarted : .pressStarted
        }

        guard let started = pressStartedNanoseconds else { return .unrelated }
        pressStartedNanoseconds = nil
        let wasCombined = combined
        combined = false
        if wasCombined || key.otherModifierHeld(rawFlags: rawFlags) {
            return .rejected(.combined)
        }
        if let other = lastOtherInput(), other >= started {
            return .rejected(.combined)
        }
        let held = nowNanoseconds >= started ? nowNanoseconds - started : 0
        if held > Self.maximumTapNanoseconds {
            return .rejected(.heldTooLong)
        }
        if let lastTapNanoseconds, nowNanoseconds >= lastTapNanoseconds,
           nowNanoseconds - lastTapNanoseconds < Self.duplicateWindowNanoseconds {
            return .rejected(.duplicate)
        }
        lastTapNanoseconds = nowNanoseconds
        return .tap
    }
}
