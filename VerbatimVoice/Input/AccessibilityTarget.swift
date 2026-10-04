import AppKit
import ApplicationServices
import Foundation

struct AXTextRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

struct AXObservedTextState: Sendable {
    let value: String
    let selectedRange: AXTextRange?
}

final class TargetSnapshot: @unchecked Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String?
    let element: AXUIElement
    let role: String?
    let subrole: String?
    let selectedRange: AXTextRange?
    let textValue: String?
    let characterCount: Int?
    let precedingCharacter: Character?
    let bounds: CGRect?
    let focusBounds: CGRect?
    let isSecureField: Bool
    let compositionLikelyActive: Bool
    let capturedAt: Date

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String?,
        element: AXUIElement,
        role: String?,
        subrole: String?,
        selectedRange: AXTextRange?,
        textValue: String?,
        characterCount: Int?,
        precedingCharacter: Character?,
        bounds: CGRect?,
        focusBounds: CGRect?,
        isSecureField: Bool,
        compositionLikelyActive: Bool,
        capturedAt: Date = Date()
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.element = element
        self.role = role
        self.subrole = subrole
        self.selectedRange = selectedRange
        self.textValue = textValue
        self.characterCount = characterCount
        self.precedingCharacter = precedingCharacter
        self.bounds = bounds
        self.focusBounds = focusBounds
        self.isSecureField = isSecureField
        self.compositionLikelyActive = compositionLikelyActive
        self.capturedAt = capturedAt
    }
}

enum InsertionVerification: Sendable {
    case confirmed
    case unchanged(String)
    case ambiguous(String)
}

struct AccessibilityTargetService {
    static func requestTrustPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func capture() -> TargetSnapshot? {
        guard Self.isTrusted else {
            NSLog("[VerbatimVoice] target capture failed: accessibility not trusted")
            return nil
        }

        var candidates: [AXUIElement] = []
        let system = AXUIElementCreateSystemWide()
        var focusedResult: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedResult
        )
        if focusedError == .success,
           let focusedResult,
           CFGetTypeID(focusedResult) == AXUIElementGetTypeID() {
            candidates.append(unsafeBitCast(focusedResult, to: AXUIElement.self))
        } else {
            NSLog("[VerbatimVoice] system-wide focused element unavailable: error=%d", focusedError.rawValue)
        }

        // Electron/WebKit apps can omit the system-wide focused element while
        // still exposing it from their own AX application object. Query the
        // actual frontmost process as a second source of truth.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            let applicationElement = AXUIElementCreateApplication(frontmost.processIdentifier)
            enableAccessibilityTree(applicationElement)
            var applicationFocusedResult: CFTypeRef?
            let applicationFocusedError = AXUIElementCopyAttributeValue(
                applicationElement,
                kAXFocusedUIElementAttribute as CFString,
                &applicationFocusedResult
            )
            if applicationFocusedError == .success,
               let applicationFocusedResult,
               CFGetTypeID(applicationFocusedResult) == AXUIElementGetTypeID() {
                let candidate = unsafeBitCast(applicationFocusedResult, to: AXUIElement.self)
                if !candidates.contains(where: { CFEqual($0, candidate) }) {
                    candidates.append(candidate)
                }
            } else {
                NSLog(
                    "[VerbatimVoice] app-specific focused element unavailable: app=%@ error=%d",
                    frontmost.bundleIdentifier ?? "unknown",
                    applicationFocusedError.rawValue
                )
            }

            // Electron apps sometimes expose a wrapper as the focused element
            // and put the actual contenteditable node below it. Search only
            // the focused wrapper's close relatives, then focused descendants
            // of the active window, to avoid selecting an unrelated text box.
            let initialCandidates = candidates
            for candidate in initialCandidates {
                appendNearbyCandidates(from: candidate, to: &candidates)
            }
            if let focusedWindow: AXUIElement = copyAttribute(
                applicationElement,
                kAXFocusedWindowAttribute as CFString
            ) {
                appendFocusedDescendants(from: focusedWindow, to: &candidates, limit: 4_000)
            }
        }

        let rankedCandidates = candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = editableCandidateScore(lhs.element)
            let rhsScore = editableCandidateScore(rhs.element)
            if lhsScore == rhsScore { return lhs.offset < rhs.offset }
            return lhsScore > rhsScore
        }.map(\.element)

        for element in rankedCandidates {
            if let snapshot = makeSnapshot(element) {
                return snapshot
            }
        }

        NSLog("[VerbatimVoice] target capture failed: no editable focused candidate")
        return nil
    }

    func capture(processIdentifier: pid_t) -> TargetSnapshot? {
        guard Self.isTrusted else {
            NSLog("[VerbatimVoice] pid capture failed: accessibility not trusted")
            return nil
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            NSLog("[VerbatimVoice] pid capture failed: target application unavailable pid=%d", processIdentifier)
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        enableAccessibilityTree(applicationElement)
        var candidates: [AXUIElement] = []

        if let focused: AXUIElement = copyAttribute(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString
        ) {
            appendUnique(focused, to: &candidates)
            appendNearbyCandidates(from: focused, to: &candidates)
        }
        if let focusedWindow: AXUIElement = copyAttribute(
            applicationElement,
            kAXFocusedWindowAttribute as CFString
        ) {
            appendUnique(focusedWindow, to: &candidates)
            appendNearbyCandidates(from: focusedWindow, to: &candidates)
        }

        let rankedCandidates = candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = editableCandidateScore(lhs.element)
            let rhsScore = editableCandidateScore(rhs.element)
            if lhsScore == rhsScore { return lhs.offset < rhs.offset }
            return lhsScore > rhsScore
        }.map(\.element)

        for element in rankedCandidates {
            guard let snapshot = makeSnapshot(element) else { continue }
            if snapshot.processIdentifier == processIdentifier {
                return snapshot
            }
        }
        NSLog(
            "[VerbatimVoice] pid capture failed: no editable candidate pid=%d candidates=%d active=%@",
            processIdentifier,
            candidates.count,
            application.isActive ? "yes" : "no"
        )
        return nil
    }

    func focus(_ target: TargetSnapshot) -> Bool {
        let error = AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return error == .success || error == .attributeUnsupported
    }

    func observedTextState(for target: TargetSnapshot) -> AXObservedTextState? {
        guard Self.isTrusted,
              NSRunningApplication(processIdentifier: target.processIdentifier) != nil,
              !target.isSecureField else { return nil }

        if let value: String = copyAttribute(target.element, kAXValueAttribute as CFString) {
            return AXObservedTextState(
                value: value,
                selectedRange: readRange(
                    target.element,
                    attribute: kAXSelectedTextRangeAttribute as CFString
                )
            )
        }

        guard let current = capture(processIdentifier: target.processIdentifier),
              !current.isSecureField,
              representsSameLogicalTarget(target, current),
              let value = current.textValue else { return nil }
        return AXObservedTextState(value: value, selectedRange: current.selectedRange)
    }

    func performPasteMenuAction(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        enableAccessibilityTree(applicationElement)
        guard let menuBar: AXUIElement = copyAttribute(
            applicationElement,
            kAXMenuBarAttribute as CFString
        ) else {
            NSLog("[VerbatimVoice] paste menu unavailable: no menu bar for pid=%d", processIdentifier)
            return false
        }

        var queue = children(of: menuBar)
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let element = queue.removeFirst()
            visited += 1
            let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
            if role == (kAXMenuItemRole as String), isPlainPasteMenuItem(element) {
                let enabled: Bool = copyAttribute(element, kAXEnabledAttribute as CFString) ?? true
                guard enabled else {
                    NSLog("[VerbatimVoice] paste menu found but disabled for pid=%d", processIdentifier)
                    return false
                }
                let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
                NSLog("[VerbatimVoice] paste menu action pid=%d error=%d", processIdentifier, error.rawValue)
                return error == .success
            }
            queue.append(contentsOf: children(of: element))
        }
        NSLog("[VerbatimVoice] paste menu item not found for pid=%d", processIdentifier)
        return false
    }

    private func makeSnapshot(_ element: AXUIElement) -> TargetSnapshot? {

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            NSLog("[VerbatimVoice] target capture failed: focused element has no pid")
            return nil
        }
        let app = NSRunningApplication(processIdentifier: pid)
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            // Clicking the menu-bar control must never lock Verbatim Voice's
            // own button as the destination. Manual recording intentionally
            // falls back to preview/copy in this case.
            NSLog("[VerbatimVoice] target capture deferred: own menu is focused")
            return nil
        }
        let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
        let subrole: String? = copyAttribute(element, kAXSubroleAttribute as CFString)
        let selectedRange = readRange(element, attribute: kAXSelectedTextRangeAttribute as CFString)
        guard isEditableTextTarget(element, role: role, selectedRange: selectedRange) else {
            NSLog(
                "[VerbatimVoice] target capture failed: non-editable role=%@ app=%@",
                role ?? "unknown",
                app?.bundleIdentifier ?? "unknown"
            )
            return nil
        }
        let characterCount: Int? = copyNumberAttribute(element, kAXNumberOfCharactersAttribute as CFString)
        let textValue: String? = copyAttribute(element, kAXValueAttribute as CFString)
        let preceding = readPrecedingCharacter(element, selectedRange: selectedRange)
        let bounds = readBounds(element)
        let focusBounds = readBoundsForRange(element, selectedRange: selectedRange) ?? bounds
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
        let composition = detectMarkedTextHeuristically(element)

        return TargetSnapshot(
            processIdentifier: pid,
            bundleIdentifier: app?.bundleIdentifier,
            applicationName: app?.localizedName,
            element: element,
            role: role,
            subrole: subrole,
            selectedRange: selectedRange,
            textValue: textValue,
            characterCount: characterCount,
            precedingCharacter: preceding,
            bounds: bounds,
            focusBounds: focusBounds,
            isSecureField: secure,
            compositionLikelyActive: composition
        )
    }

    private func enableAccessibilityTree(_ applicationElement: AXUIElement) {
        // Chromium/Electron honors this process-local AX switch; it does not
        // change a system permission. AXEnhancedUserInterface is deliberately
        // not set: it is the VoiceOver-mode switch, stays on for the target's
        // whole lifetime, and changes how that app handles windows and input
        // long after the dictation that enabled it.
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
    }

    private func appendNearbyCandidates(from element: AXUIElement, to candidates: inout [AXUIElement]) {
        var ancestor = element
        for _ in 0..<6 {
            guard let parent: AXUIElement = copyAttribute(ancestor, kAXParentAttribute as CFString) else { break }
            appendUnique(parent, to: &candidates)
            ancestor = parent
        }

        var queue: [(AXUIElement, Int)] = children(of: element).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 4_000 {
            let (descendant, depth) = queue.removeFirst()
            visited += 1
            appendUnique(descendant, to: &candidates)
            if depth < 40 {
                queue.append(contentsOf: children(of: descendant).map { ($0, depth + 1) })
            }
        }
    }

    private func appendFocusedDescendants(
        from root: AXUIElement,
        to candidates: inout [AXUIElement],
        limit: Int
    ) {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let element = queue.removeFirst()
            visited += 1
            let focused: Bool = copyAttribute(element, kAXFocusedAttribute as CFString) ?? false
            let selectedRange = readRange(element, attribute: kAXSelectedTextRangeAttribute as CFString)
            if focused || selectedRange != nil {
                appendUnique(element, to: &candidates)
            }
            queue.append(contentsOf: children(of: element))
        }
    }

    private func appendUnique(_ element: AXUIElement, to candidates: inout [AXUIElement]) {
        if !candidates.contains(where: { CFEqual($0, element) }) {
            candidates.append(element)
        }
    }

    private func editableCandidateScore(_ element: AXUIElement) -> Int {
        let role: String? = copyAttribute(element, kAXRoleAttribute as CFString)
        var score = 0
        if role == (kAXTextAreaRole as String) { score += 120 }
        if role == (kAXTextFieldRole as String) { score += 110 }
        if role == (kAXComboBoxRole as String) { score += 90 }
        if readRange(element, attribute: kAXSelectedTextRangeAttribute as CFString) != nil {
            score += 100
        }
        let focused: Bool = copyAttribute(element, kAXFocusedAttribute as CFString) ?? false
        if focused { score += 80 }
        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success,
        selectedTextSettable.boolValue {
            score += 60
        }
        let editable: Bool = copyAttribute(element, "AXEditable" as CFString) ?? false
        if editable { score += 40 }
        return score
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute as CFString) ?? []
    }

    private func isPlainPasteMenuItem(_ element: AXUIElement) -> Bool {
        let title: String = copyAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exactTitles: Set<String> = ["paste", "粘贴", "貼り付け", "붙여넣기"] // l10n:ignore
        if exactTitles.contains(normalizedTitle) { return true }

        let commandCharacter: String? = copyAttribute(
            element,
            kAXMenuItemCmdCharAttribute as CFString
        )
        let modifiers: Int = copyNumberAttribute(
            element,
            kAXMenuItemCmdModifiersAttribute as CFString
        ) ?? 0
        return commandCharacter?.lowercased() == "v" && modifiers == 0
    }

    func verifyInsertion(_ original: TargetSnapshot, insertedText: String) -> InsertionVerification {
        guard let current = capture(processIdentifier: original.processIdentifier) else {
            return .ambiguous(String(localized: "输入已发送，但目标应用不再暴露输入焦点"))
        }
        guard current.processIdentifier == original.processIdentifier else {
            return .ambiguous(String(localized: "输入已发送，但前台应用已经变化"))
        }
        guard representsSameLogicalTarget(original, current) else {
            return .ambiguous(String(localized: "输入已发送，但插入后焦点已经变化"))
        }

        let insertedUTF16Length = (insertedText as NSString).length
        let currentValue: String? = copyAttribute(current.element, kAXValueAttribute as CFString)
        var valueChangedUnexpectedly = false
        if let currentValue {
            // Empty Chromium/Electron editors sometimes expose their visual
            // placeholder as AXValue.  Once typing begins, AXValue changes to
            // the real editor content.  Treat the actual inserted text, or a
            // newly appearing occurrence of it, as stronger evidence than a
            // placeholder-derived whole-string prediction.
            if currentValue == insertedText {
                return .confirmed
            }
            if let originalValue = original.textValue,
               let originalRange = original.selectedRange {
                let originalNSString = originalValue as NSString
                let replacementRange = NSRange(
                    location: originalRange.location,
                    length: originalRange.length
                )
                if NSMaxRange(replacementRange) <= originalNSString.length {
                    let expectedValue = originalNSString.replacingCharacters(
                        in: replacementRange,
                        with: insertedText
                    )
                    if currentValue == expectedValue {
                        return .confirmed
                    }
                    if InsertionTextEvidence.containsNewOccurrence(
                        insertedText: insertedText,
                        originalText: originalValue,
                        currentText: currentValue
                    ) {
                        return .confirmed
                    }
                    if currentValue == originalValue,
                       current.selectedRange == original.selectedRange,
                       current.characterCount == original.characterCount {
                        return .unchanged(String(localized: "输入框内容、字符数和光标均未变化"))
                    }
                    valueChangedUnexpectedly = currentValue != originalValue
                }
            }
        }
        var countChangedUnexpectedly = false
        if let originalCount = original.characterCount,
           let currentCount = current.characterCount {
            let replacedLength = original.selectedRange?.length ?? 0
            let expectedCount = originalCount - replacedLength + insertedUTF16Length
            if expectedCount != originalCount, currentCount == expectedCount {
                return .confirmed
            }
            if currentCount == originalCount,
               current.selectedRange == original.selectedRange {
                return .unchanged(String(localized: "字符数和光标均未变化"))
            }
            countChangedUnexpectedly = currentCount != originalCount
        }

        var rangeChangedUnexpectedly = false
        if let originalRange = original.selectedRange,
           let currentRange = current.selectedRange {
            let expectedLocation = originalRange.location + insertedUTF16Length
            if currentRange.length == 0, currentRange.location == expectedLocation {
                return .confirmed
            }
            if currentRange == originalRange {
                return .unchanged(String(localized: "光标和选区未变化"))
            }
            rangeChangedUnexpectedly = true
        }

        if valueChangedUnexpectedly {
            return .ambiguous(String(localized: "输入框发生了非预期变化，无法安全自动重试"))
        }
        if countChangedUnexpectedly {
            return .ambiguous(String(localized: "字符数发生了非预期变化，无法安全自动重试"))
        }
        if rangeChangedUnexpectedly {
            return .ambiguous(String(localized: "光标发生了非预期变化，无法安全自动重试"))
        }
        return .ambiguous(String(localized: "当前应用不提供足够的 Accessibility 信息来确认结果"))
    }

    private func representsSameLogicalTarget(
        _ original: TargetSnapshot,
        _ current: TargetSnapshot
    ) -> Bool {
        if CFEqual(original.element, current.element) { return true }

        // Chromium/WebKit may replace the AX object after processing focus or
        // input even though the visible editor is the same. Match only when
        // role, subrole, security state, and geometry all still identify the
        // same control; without geometry, keep the conservative result.
        guard original.role == current.role,
              original.subrole == current.subrole,
              original.isSecureField == current.isSecureField,
              let originalBounds = original.bounds,
              let currentBounds = current.bounds else {
            return false
        }

        let centerDistance = hypot(
            originalBounds.midX - currentBounds.midX,
            originalBounds.midY - currentBounds.midY
        )
        let widthDelta = abs(originalBounds.width - currentBounds.width)
        let heightDelta = abs(originalBounds.height - currentBounds.height)
        return centerDistance <= 3 && widthDelta <= 3 && heightDelta <= 3
    }

    private func readPrecedingCharacter(_ element: AXUIElement, selectedRange: AXTextRange?) -> Character? {
        guard let selectedRange, selectedRange.location > 0 else { return nil }

        if let value: String = copyAttribute(element, kAXValueAttribute as CFString) {
            let string = value as NSString
            let utf16Index = selectedRange.location - 1
            if utf16Index >= 0, utf16Index < string.length {
                let composedRange = string.rangeOfComposedCharacterSequence(at: utf16Index)
                return string.substring(with: composedRange).first
            }
        }

        var range = CFRange(location: selectedRange.location - 1, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard error == .success, let string = result as? String else { return nil }
        return string.first
    }

    private func detectMarkedTextHeuristically(_ element: AXUIElement) -> Bool {
        let possibleAttributes = ["AXMarkedTextRange", "AXMarkedText"]
        for name in possibleAttributes {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            guard error == .success, let result else { continue }
            if let string = result as? String, !string.isEmpty { return true }
            if let value = asAXValue(result),
               AXValueGetType(value) == .cfRange {
                var range = CFRange()
                if AXValueGetValue(value, .cfRange, &range), range.length > 0 { return true }
            }
        }
        return false
    }

    private func isEditableTextTarget(
        _ element: AXUIElement,
        role: String?,
        selectedRange: AXTextRange?
    ) -> Bool {
        if selectedRange != nil { return true }

        let knownEditableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if let role, knownEditableRoles.contains(role) { return true }

        var editableResult: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableResult) == .success,
           let editable = editableResult as? Bool,
           editable {
            return true
        }

        return false
    }

    private func readBounds(_ element: AXUIElement) -> CGRect? {
        var positionResult: CFTypeRef?
        var sizeResult: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionResult) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeResult) == .success,
              let positionValue = asAXValue(positionResult),
              let sizeValue = asAXValue(sizeResult),
              AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func readBoundsForRange(
        _ element: AXUIElement,
        selectedRange: AXTextRange?
    ) -> CGRect? {
        guard let selectedRange else { return nil }
        var range = CFRange(location: selectedRange.location, length: selectedRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success,
        let value = asAXValue(result),
        AXValueGetType(value) == .cgRect else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect),
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.height > 0 else { return nil }
        return rect
    }

    private func readRange(_ element: AXUIElement, attribute: CFString) -> AXTextRange? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success,
              let value = asAXValue(result),
              AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return AXTextRange(location: range.location, length: range.length)
    }

    private func copyNumberAttribute(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        if let number = result as? NSNumber { return number.intValue }
        return nil
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: CFString) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
        return result as? T
    }

    private func asAXValue(_ result: CFTypeRef?) -> AXValue? {
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXValue.self)
    }
}

@MainActor
final class InsertedTextCorrectionMonitor {
    typealias ObservationHandler = @MainActor @Sendable (
        _ correctedText: String,
        _ replacement: CorrectionReplacement
    ) -> Void

    private let service = AccessibilityTargetService()
    private var observationTask: Task<Void, Never>?

    deinit {
        observationTask?.cancel()
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    @discardableResult
    func observe(
        insertedText: String,
        target: TargetSnapshot,
        durationSeconds: TimeInterval = 45,
        onObservation: @escaping ObservationHandler
    ) -> Bool {
        stop()
        guard !insertedText.isEmpty, target.textValue != nil, target.selectedRange != nil else { return false }

        let service = self.service
        observationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  let initial = await Task.detached(priority: .utility, operation: {
                      service.observedTextState(for: target)
                  }).value,
                  let locatedRange = Self.locateInsertedText(
                      insertedText,
                      in: initial.value,
                      preferredLocation: target.selectedRange?.location
                  ) else {
                self?.observationTask = nil
                return
            }

            var baselineWholeText = initial.value
            var insertedRange = locatedRange
            var pendingCorrection: String?
            var pendingSince: Date?
            var lastDelivered: String?
            let deadline = Date().addingTimeInterval(max(5, durationSeconds))

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                // Do not read the field while the user is actively typing:
                // wait for a pause so an input-method composition is never
                // observed (or disturbed) mid-word.
                let sinceKeyDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                if sinceKeyDown < 1.0 { continue }

                guard let current = await Task.detached(priority: .utility, operation: {
                    service.observedTextState(for: target)
                }).value else { break }

                if current.value != baselineWholeText {
                    guard let mutation = CorrectionInference.mutation(
                        from: baselineWholeText,
                        to: current.value
                    ), let tracked = CorrectionInference.track(
                        mutation: mutation,
                        oldWholeText: baselineWholeText,
                        newWholeText: current.value,
                        insertedRange: insertedRange
                    ) else {
                        // The change crossed the dictated-text boundary, the
                        // editor was cleared/sent, or the AX node was replaced
                        // ambiguously. Stop instead of learning unrelated text.
                        break
                    }

                    baselineWholeText = current.value
                    insertedRange = tracked.updatedInsertedRange
                    if let corrected = tracked.correctedText,
                       corrected != insertedText,
                       Self.isConservativeCorrection(original: insertedText, corrected: corrected) {
                        pendingCorrection = corrected
                        pendingSince = Date()
                    }
                }

                guard let pendingCorrection,
                      pendingCorrection != lastDelivered,
                      let pendingSince,
                      Date().timeIntervalSince(pendingSince) >= 1.1,
                      let replacement = CorrectionInference.replacement(
                          from: insertedText,
                          to: pendingCorrection
                      ) else { continue }

                lastDelivered = pendingCorrection
                onObservation(
                    pendingCorrection,
                    CorrectionReplacement(
                        original: replacement.original,
                        corrected: replacement.corrected,
                        punctuationOnly: replacement.punctuationOnly
                    )
                )
            }
            self?.observationTask = nil
        }
        return true
    }

    private static func locateInsertedText(
        _ insertedText: String,
        in wholeText: String,
        preferredLocation: Int?
    ) -> NSRange? {
        let whole = wholeText as NSString
        let needleLength = (insertedText as NSString).length
        guard needleLength > 0, whole.length >= needleLength else { return nil }

        if let preferredLocation,
           preferredLocation >= 0,
           preferredLocation + needleLength <= whole.length {
            let preferred = NSRange(location: preferredLocation, length: needleLength)
            if whole.substring(with: preferred) == insertedText { return preferred }
        }

        var candidates: [NSRange] = []
        var search = NSRange(location: 0, length: whole.length)
        while search.length > 0 {
            let found = whole.range(of: insertedText, options: [], range: search)
            guard found.location != NSNotFound else { break }
            candidates.append(found)
            let next = NSMaxRange(found)
            guard next < whole.length else { break }
            search = NSRange(location: next, length: whole.length - next)
        }
        guard !candidates.isEmpty else { return nil }
        guard let preferredLocation else { return candidates.last }
        return candidates.min { abs($0.location - preferredLocation) < abs($1.location - preferredLocation) }
    }

    private static func isConservativeCorrection(original: String, corrected: String) -> Bool {
        let originalLength = (original as NSString).length
        let correctedLength = (corrected as NSString).length
        guard correctedLength > 0,
              correctedLength <= max(originalLength + 32, Int(Double(originalLength) * 1.35)) else {
            return false
        }
        guard let replacement = CorrectionInference.replacement(from: original, to: corrected) else {
            return false
        }
        if replacement.punctuationOnly { return true }
        let changedLength = (replacement.original as NSString).length
            + (replacement.corrected as NSString).length
        return changedLength <= max(24, originalLength / 2)
    }
}
