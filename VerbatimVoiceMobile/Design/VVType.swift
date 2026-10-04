import SwiftUI

/// Type ramp from DESIGN.md §5. System text styles keep Dynamic Type
/// (the system font already applies the HIG tracking table, so no
/// `.tracking()`); line heights are the design's, scaled with the style.
enum VVTextStyle {
    case largeTitle      // 34/41 bold
    case headline        // 17/22 semibold
    case transcript      // 17/26 regular — the only loosened style
    case body            // 17/22 regular
    case subhead         // 15/20 regular
    case subheadMedium   // 15/20 medium
    case footnote        // 13/18 regular
    case timer           // 22/28 medium, tabular
    case timerLarge      // 44/52 medium, tabular
    case keyLabel        // 23 regular, never scales
    case keyLabelSmall   // 16 regular, never scales

    var font: Font {
        switch self {
        case .largeTitle: return .largeTitle.weight(.bold)
        case .headline: return .headline
        case .transcript, .body: return .body
        case .subhead: return .subheadline
        case .subheadMedium: return .subheadline.weight(.medium)
        case .footnote: return .footnote
        case .timer: return .title2.weight(.medium).monospacedDigit()
        case .timerLarge: return .system(size: 44, weight: .medium).monospacedDigit()
        case .keyLabel: return .system(size: VVMetric.keyboardLabelSize)
        case .keyLabelSmall: return .system(size: VVMetric.keyboardLabelSizeSmall)
        }
    }

    var lineHeight: CGFloat {
        switch self {
        case .largeTitle: return 41
        case .headline, .body: return 22
        case .transcript: return 26
        case .subhead, .subheadMedium: return 20
        case .footnote: return 18
        case .timer: return 28
        case .timerLarge: return 52
        case .keyLabel: return 28
        case .keyLabelSmall: return 21
        }
    }

    /// Natural SF line height at the default size, for the pre-iOS 26
    /// `lineSpacing` fallback (Tokens.swift `…LineSpacing`).
    var fallbackSpacing: CGFloat {
        switch self {
        case .transcript: return VVFont.transcriptLineSpacing
        case .largeTitle: return VVFont.largeTitleLineSpacing
        case .footnote: return VVFont.footnoteLineSpacing
        default: return VVFont.bodyLineSpacing
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .headline: return .headline
        case .transcript, .body: return .body
        case .subhead, .subheadMedium: return .subheadline
        case .footnote: return .footnote
        case .timer: return .title2
        case .timerLarge: return .largeTitle
        case .keyLabel, .keyLabelSmall: return .body
        }
    }
}

private struct VVTextModifier: ViewModifier {
    let style: VVTextStyle
    @ScaledMetric private var lineHeight: CGFloat

    init(style: VVTextStyle) {
        self.style = style
        _lineHeight = ScaledMetric(wrappedValue: style.lineHeight, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        styled(content)
            // Latin, digits, spaces and "·" resolve to SF first (as in the
            // mockups' `SF Pro, PingFang SC` stack); Han still falls back to
            // PingFang SC. Without this a zh-Hans device sets "·" and spaces
            // in PingFang, which is visibly wider.
            .typesettingLanguage(Locale.Language(identifier: "en"))
    }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        if style == .keyLabel || style == .keyLabelSmall {
            // Single-line key labels: centred on the glyph box, like `font: 16px/1`.
            content.font(style.font)
        } else if #available(iOS 26.0, macCatalyst 26.0, *) {
            content
                .font(style.font)
                .lineHeight(.exact(points: lineHeight))
                // CoreText puts less of the added leading above the first
                // line than CSS half-leading; measured 1.3pt at 17/26.
                .offset(y: style == .transcript ? 1.3 : 0)
        } else {
            content
                .font(style.font)
                .lineSpacing(style.fallbackSpacing)
        }
    }
}

extension View {
    /// Applies a DESIGN.md §5 text style (font + line height).
    func vvText(_ style: VVTextStyle) -> some View {
        modifier(VVTextModifier(style: style))
    }
}

/// `m:ss` as in the design ("0:07", "4:12").
enum VVClock {
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// The mockups track every glyph by the HIG value (−26/1000 em at 17pt);
/// iOS tracks SF glyphs itself but sets Han and full-width punctuation about
/// 0.24pt wider per glyph at 17pt, which moves line breaks in the
/// transcript. This applies the difference to CJK runs only.
enum VVCJK {
    static func tracked(_ string: String, _ tracking: CGFloat = -0.24) -> AttributedString {
        var out = AttributedString(string)
        var index = out.startIndex
        while index < out.endIndex {
            let next = out.characters.index(after: index)
            if let scalar = out.characters[index].unicodeScalars.first, isCJK(scalar) {
                out[index..<next].tracking = tracking
            }
            index = next
        }
        return out
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF: return true
        default: return false
        }
    }
}
