import AppKit
import CoreGraphics
import Foundation

struct InsertionResult: Sendable {
    let status: InsertionStatus
    let message: String
    let clipboardRestored: Bool
    let transport: InsertionTransport
    let attempts: [InsertionAttemptSummary]
    let resolvedTarget: TargetSnapshot?

    init(
        status: InsertionStatus,
        message: String,
        clipboardRestored: Bool,
        transport: InsertionTransport = .none,
        attempts: [InsertionAttemptSummary] = [],
        resolvedTarget: TargetSnapshot? = nil
    ) {
        self.status = status
        self.message = message
        self.clipboardRestored = clipboardRestored
        self.transport = transport
        self.attempts = attempts
        self.resolvedTarget = resolvedTarget
    }
}

@MainActor
final class PasteboardInserter {
    private enum TargetLeaseResolution {
        case editable(TargetSnapshot)
        case keyboardFocus
        case rejected(String)
    }

    private let targetService = AccessibilityTargetService()

    func insert(
        text: String,
        target: TargetSnapshot,
        onDispatched: (() -> Void)? = nil
    ) async -> InsertionResult {
        guard !text.isEmpty else {
            return InsertionResult(status: .failed, message: String(localized: "转写结果为空"), clipboardRestored: true)
        }

        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return InsertionResult(status: .previewOnly, message: String(localized: "原输入应用已经退出"), clipboardRestored: true)
        }
        guard application.bundleIdentifier == target.bundleIdentifier else {
            return InsertionResult(status: .previewOnly, message: String(localized: "原输入应用身份已经变化"), clipboardRestored: true)
        }
        if !application.isActive {
            guard await activateAndWait(application) else {
                return InsertionResult(
                    status: .previewOnly,
                    message: String(localized: "无法重新激活原输入应用"),
                    clipboardRestored: true
                )
            }
        }

        // A dictation target is an application-scoped lease, not an immutable
        // AX object. Resolve the application's current editable focus at commit
        // time, exactly as a system input method does. This single path covers
        // native controls, WebKit/Electron DOM rebuilds, terminals, chat apps,
        // IDEs and custom canvases without per-application exceptions.
        var lease = resolveTargetLease(startingAt: target)
        if case .editable(let liveTarget) = lease {
            _ = targetService.focus(liveTarget)
            await Task.yield()
            lease = resolveTargetLease(startingAt: target)
        }

        let resolvedTarget: TargetSnapshot?
        switch lease {
        case .editable(let liveTarget):
            resolvedTarget = liveTarget
        case .keyboardFocus:
            resolvedTarget = nil
        case .rejected(let reason):
            return InsertionResult(status: .previewOnly, message: reason, clipboardRestored: true)
        }

        // Layer 1: emit Unicode through the target process's keyboard event
        // stream. This produces ordinary input events for Electron/WebKit and
        // terminal-style controls without touching the pasteboard. Do not use
        // AXValue as an insertion primitive: Accessibility value mutation is
        // not a text-input event and can bypass an app's editor/undo state.
        let terminalTarget = AppProfile.profile(for: target.bundleIdentifier).kind == .terminal
        var attempts: [InsertionAttemptSummary] = []
        if await postUnicodeText(text, targetPID: target.processIdentifier) {
            // The visible status belongs to dispatch, not to the slower AX
            // verification that follows.  Let the caller hide it as soon as
            // the destination has received the keyboard events.
            onDispatched?()
            attempts.append(InsertionAttemptSummary(
                transport: .unicodeKeyboard,
                outcome: .unverifiable,
                detail: resolvedTarget == nil
                    ? String(localized: "目标应用不暴露可编辑 AX 控件；已向当前键盘焦点发送 Unicode 事件")
                    : String(localized: "Unicode 事件已发送；Accessibility 验证已移出用户关键路径")
            ))

            // Dispatch is the terminal success condition. Accessibility is an
            // asynchronous audit only: it may neither delay the return value,
            // retry insertion, reopen Preview, nor reveal the overlay again.
            if let resolvedTarget {
                Task(priority: .utility) { [weak self] in
                    _ = await self?.waitForVerification(resolvedTarget, insertedText: text)
                }
            }
            return InsertionResult(
                status: .dispatched,
                message: terminalTarget
                    ? String(localized: "已向终端发送 Unicode 键盘输入；未使用剪贴板")
                    : String(localized: "已发送 Unicode 键盘输入；未使用剪贴板"),
                clipboardRestored: true,
                transport: .unicodeKeyboard,
                attempts: attempts,
                resolvedTarget: resolvedTarget
            )
        } else {
            attempts.append(InsertionAttemptSummary(
                transport: .unicodeKeyboard,
                outcome: .dispatchFailed,
                detail: String(localized: "无法创建或发送 Unicode 键盘事件")
            ))
        }

        // Never turn a direct-input failure into an automatic paste. Writing
        // and then restoring the general pasteboard still creates two new local
        // clipboard generations, which can race with Apple's Universal
        // Clipboard and replace content copied on another device. Preserve the
        // transcript in Preview and let only the explicit Copy action touch
        // the clipboard.
        return InsertionResult(
            status: .previewOnly,
            message: String(localized: "当前应用没有接收直接输入；为保护通用剪贴板，未自动改用粘贴"),
            clipboardRestored: true,
            transport: .unicodeKeyboard,
            attempts: attempts,
            resolvedTarget: resolvedTarget
        )
    }

    private func resolveTargetLease(startingAt original: TargetSnapshot) -> TargetLeaseResolution {
        let application = NSRunningApplication(processIdentifier: original.processIdentifier)
        let liveTarget = targetService.capture(processIdentifier: original.processIdentifier)
        let evidence = InputTargetLeaseEvidence(
            processExists: application != nil,
            bundleIdentifierMatches: application?.bundleIdentifier == original.bundleIdentifier,
            applicationIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == original.processIdentifier,
            secureInputEnabled: SecureInputMonitor.isEnabled,
            liveEditableTargetAvailable: liveTarget != nil,
            liveTargetIsSecure: liveTarget?.isSecureField ?? false,
            liveTargetHasComposition: liveTarget?.compositionLikelyActive ?? false
        )

        switch InputTargetLeasePolicy.resolve(evidence) {
        case .liveEditableTarget:
            guard let liveTarget else { return .rejected(String(localized: "当前输入目标暂时不可用")) }
            return .editable(liveTarget)
        case .keyboardFocus:
            return .keyboardFocus
        case .reject(.applicationExited):
            return .rejected(String(localized: "原输入应用已经退出"))
        case .reject(.applicationIdentityChanged):
            return .rejected(String(localized: "原输入应用身份已经变化"))
        case .reject(.applicationNotFrontmost):
            return .rejected(String(localized: "原输入应用不再位于前台"))
        case .reject(.secureInputEnabled):
            return .rejected(String(localized: "系统 Secure Input 正在占用键盘事件"))
        case .reject(.secureField):
            return .rejected(String(localized: "当前是安全输入字段"))
        case .reject(.compositionActive):
            return .rejected(String(localized: "检测到可能尚未上屏的中文输入法组合文本"))
        }
    }

    func insertAtCurrentFocus(
        text: String,
        onDispatched: (() -> Void)? = nil
    ) async -> InsertionResult {
        guard !text.isEmpty else {
            return InsertionResult(status: .failed, message: String(localized: "转写结果为空"), clipboardRestored: true)
        }
        guard !SecureInputMonitor.isEnabled else {
            return InsertionResult(status: .previewOnly, message: String(localized: "系统 Secure Input 正在占用键盘事件"), clipboardRestored: true)
        }

        if let target = targetService.capture() {
            return await insert(
                text: text,
                target: target,
                onDispatched: onDispatched
            )
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return InsertionResult(status: .previewOnly, message: String(localized: "当前没有可接收文字的前台应用"), clipboardRestored: true)
        }

        return await insertAtApplication(
            text: text,
            processIdentifier: application.processIdentifier,
            applicationName: application.localizedName,
            onDispatched: onDispatched
        )
    }

    func insertAtApplication(
        text: String,
        processIdentifier: pid_t,
        applicationName: String?,
        onDispatched: (() -> Void)? = nil
    ) async -> InsertionResult {
        guard !text.isEmpty else {
            return InsertionResult(status: .failed, message: String(localized: "转写结果为空"), clipboardRestored: true)
        }
        guard !SecureInputMonitor.isEnabled else {
            return InsertionResult(status: .previewOnly, message: String(localized: "系统 Secure Input 正在占用键盘事件"), clipboardRestored: true)
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return InsertionResult(status: .previewOnly, message: String(localized: "原输入应用已经退出"), clipboardRestored: true)
        }

        let activated = await activateAndWait(application)
        guard activated else {
            return InsertionResult(
                status: .previewOnly,
                message: AccessibilityTargetService.isTrusted
                    ? String(localized: "无法重新激活原输入应用；诊断：辅助功能=已授权，目标激活=否")
                    : String(localized: "无法重新激活原输入应用；诊断：辅助功能=未授权，目标激活=否"),
                clipboardRestored: true
            )
        }

        let trusted = AccessibilityTargetService.isTrusted
        guard trusted else {
            return InsertionResult(
                status: .previewOnly,
                message: String(localized: "运行中的 \(AppIdentity.displayName) 没有实际获得辅助功能控制；诊断：辅助功能=未授权，目标激活=是，未发送粘贴"),
                clipboardRestored: true
            )
        }

        let expectedPID = processIdentifier
        let resolvedApplicationName = applicationName ?? application.localizedName ?? application.bundleIdentifier ?? String(localized: "当前应用")
        NSLog(
            "[VerbatimVoice] using direct application keyboard route: app=%@ pid=%d",
            application.bundleIdentifier ?? "unknown",
            expectedPID
        )

        // The application PID is the session lease. Do not scan its AX tree on
        // the user path: Electron/WebKit/terminal AX calls have blocked real
        // sessions for 2.7-12.3 seconds even though the text result was ready.
        // Secure Input, process identity and foreground activation were already
        // checked above. Send once and leave AX/correction observation to the
        // background; never retry the same utterance.
        if await postUnicodeText(text, targetPID: expectedPID) {
            onDispatched?()
            let attempt = InsertionAttemptSummary(
                transport: .unicodeKeyboard,
                outcome: .unverifiable,
                detail: String(localized: "已按会话锁定的应用进程发送 Unicode；AX 扫描不在用户关键路径")
            )
            return InsertionResult(
                status: .dispatched,
                message: String(localized: "已向\(resolvedApplicationName)发送 Unicode 键盘输入；该界面不提供本机可验证文本状态"),
                clipboardRestored: true,
                transport: .unicodeKeyboard,
                attempts: [attempt]
            )
        }

        return InsertionResult(
            status: .previewOnly,
            message: String(localized: "\(resolvedApplicationName)没有接收直接输入；为保护通用剪贴板，未自动改用粘贴"),
            clipboardRestored: true,
            transport: .unicodeKeyboard,
            attempts: [InsertionAttemptSummary(
                transport: .unicodeKeyboard,
                outcome: .dispatchFailed,
                detail: String(localized: "无法创建或发送 Unicode 键盘事件")
            )]
        )
    }

    private func waitForVerification(
        _ target: TargetSnapshot,
        insertedText: String
    ) async -> InsertionVerification {
        var latest = targetService.verifyInsertion(target, insertedText: insertedText)
        if case .confirmed = latest { return latest }

        // Web views often publish their AX state one or two run-loop turns
        // after processing input. Poll long enough to observe that update,
        // while keeping the normal path below half a second.
        for delay in [60, 90, 130, 180] {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            latest = targetService.verifyInsertion(target, insertedText: insertedText)
            if case .confirmed = latest { return latest }
        }
        return latest
    }

    private func activateAndWait(_ application: NSRunningApplication) async -> Bool {
        if application.isActive { return true }
        guard application.activate(options: []) else { return false }

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if application.isActive,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                // Let the target app finish restoring its focused control and
                // accessibility tree after becoming frontmost.
                try? await Task.sleep(nanoseconds: 150_000_000)
                return true
            }
        }
        return application.isActive
    }

    func copyOnly(_ text: String) -> InsertionResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        return InsertionResult(
            status: success ? .copied : .failed,
            message: success ? String(localized: "已复制") : String(localized: "复制失败"),
            clipboardRestored: false,
            transport: .clipboardCopy
        )
    }

    private func postUnicodeText(_ text: String, targetPID: pid_t) async -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let chunks = unicodeEventChunks(text)
        for (index, chunk) in chunks.enumerated() {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                return false
            }

            let utf16 = Array(chunk.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(targetPID)
            keyUp.postToPid(targetPID)
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
        }
        return true
    }

    private func unicodeEventChunks(_ text: String, maximumUTF16Length: Int = 20) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for character in text {
            let part = String(character)
            let partLength = part.utf16.count
            if !current.isEmpty, currentLength + partLength > maximumUTF16Length {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += partLength
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
