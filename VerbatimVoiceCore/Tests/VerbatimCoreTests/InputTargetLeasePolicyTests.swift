import XCTest
@testable import VerbatimCore

final class InputTargetLeasePolicyTests: XCTestCase {
    private func evidence(
        processExists: Bool = true,
        bundleMatches: Bool = true,
        frontmost: Bool = true,
        secureInput: Bool = false,
        editableTarget: Bool = true,
        secureField: Bool = false,
        composition: Bool = false
    ) -> InputTargetLeaseEvidence {
        InputTargetLeaseEvidence(
            processExists: processExists,
            bundleIdentifierMatches: bundleMatches,
            applicationIsFrontmost: frontmost,
            secureInputEnabled: secureInput,
            liveEditableTargetAvailable: editableTarget,
            liveTargetIsSecure: secureField,
            liveTargetHasComposition: composition
        )
    }

    func testAllEditableApplicationFamiliesUseCommitTimeCaret() {
        // These labels document the real families observed in local history.
        // The policy intentionally receives no application name or profile:
        // identical evidence must always produce identical behavior.
        for family in ["AppKit", "Codex-Electron", "Chrome-Web", "WeChat", "Terminal", "iTerm"] {
            XCTAssertEqual(
                InputTargetLeasePolicy.resolve(evidence()),
                .liveEditableTarget,
                family
            )
        }
    }

    func testCustomCanvasUsesCurrentKeyboardFocus() {
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(editableTarget: false)),
            .keyboardFocus
        )
    }

    func testExitedOrReusedProcessIsRejected() {
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(processExists: false)),
            .reject(.applicationExited)
        )
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(bundleMatches: false)),
            .reject(.applicationIdentityChanged)
        )
    }

    func testDifferentFrontmostApplicationIsRejected() {
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(frontmost: false)),
            .reject(.applicationNotFrontmost)
        )
    }

    func testSecureInputIsRejectedWithOrWithoutAXTarget() {
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(secureInput: true)),
            .reject(.secureInputEnabled)
        )
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(secureField: true)),
            .reject(.secureField)
        )
    }

    func testUncommittedInputMethodCompositionIsRejected() {
        XCTAssertEqual(
            InputTargetLeasePolicy.resolve(evidence(composition: true)),
            .reject(.compositionActive)
        )
    }
}
