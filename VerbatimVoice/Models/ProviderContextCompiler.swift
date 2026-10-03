import CryptoKit
import Foundation

struct CompiledProviderContext: Sendable {
    let context: ASRContext
    let receipt: ProviderContextReceipt
}

enum ProviderContextCompiler {
    static func compile(
        sessionID: UUID,
        providerID: String,
        personalTerms: [PersonalTerm],
        builtInTerms: [String],
        targetBundleIdentifier: String?,
        profile: String? = nil,
        prompt: String,
        hotwordWeight: Int,
        speakerBackground: String = "",
        referenceDate: Date = Date()
    ) -> CompiledProviderContext {
        let capability = capability(for: providerID)
        let selection = ContextBudgeter.select(
            personalTerms: personalTerms,
            builtInTerms: builtInTerms,
            targetBundleIdentifier: targetBundleIdentifier,
            profile: profile,
            capacity: capability.capacity,
            referenceDate: referenceDate
        )

        let effectivePrompt = capability.promptLimit.map { String(prompt.prefix($0)) } ?? prompt
        let terms = capability.supportsTerms ? selection.selectedTerms : []
        var droppedReasons = selection.droppedReasons
        if !capability.supportsTerms, selection.candidateCount > 0 {
            droppedReasons["unsupported", default: 0] += selection.candidateCount
        }
        let droppedCount = droppedReasons.values.reduce(0, +)
        let capabilities: [String]
        if capability.supportsTerms {
            capabilities = capability.supportsPrompt ? ["terms", "literal_prompt"] : ["terms"]
        } else {
            capabilities = ["terms_unsupported"]
        }
        let receipt = ProviderContextReceipt(
            sessionID: sessionID,
            provider: providerID,
            includedTermIDs: capability.supportsTerms ? selection.selectedTermIDs : [],
            includedTerms: terms,
            candidateCount: selection.candidateCount,
            droppedCount: droppedCount,
            droppedReasons: droppedReasons,
            promptHash: capability.supportsPrompt ? sha256(effectivePrompt) : nil,
            capabilitiesUsed: capabilities,
            capacityBudget: capability.capacity
        )
        return CompiledProviderContext(
            context: .personal(
                terms: terms,
                instructions: effectivePrompt,
                hotwordWeight: hotwordWeight,
                speakerBackground: speakerBackground
            ),
            receipt: receipt
        )
    }

    private struct Capability {
        let capacity: Int
        let supportsTerms: Bool
        let supportsPrompt: Bool
        let promptLimit: Int?
    }

    private static func capability(for providerID: String) -> Capability {
        switch providerID {
        case "soniox":
            return Capability(capacity: 150, // = SonioxProvider.maximumContextTerms
                              supportsTerms: true, supportsPrompt: true, promptLimit: nil)
        case "aliyun-qwen-audio-asr":
            return Capability(capacity: 2_000, supportsTerms: true, supportsPrompt: true, promptLimit: 400)
        default:
            return Capability(capacity: 0, supportsTerms: false, supportsPrompt: false, promptLimit: nil)
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
