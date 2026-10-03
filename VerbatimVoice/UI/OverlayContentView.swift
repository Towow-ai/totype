import SwiftUI

/// Bottom overlay (DESIGN.md §7.6, §13.3): one 28pt capsule on the lightest system material
/// with an almost invisible rim and a 1pt contact shadow. Four designed states share it —
/// 正在听 / 识别中 / 已插入 / 失败 — plus the two operational states the design does not
/// draw (cancel-pending undo, insertion preview), which reuse the same family.
struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel
    let meter: OverlayLevelMeter

    static let escapeUnavailableNote = "Esc 不可用"

    var body: some View {
        Group {
            if viewModel.mode == .preview {
                previewCard
            } else {
                pill
            }
        }
        .padding(VVMac.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.message)
    }

    // MARK: - Pill

    private var pill: some View {
        HStack(spacing: VVMac.pillGap) {
            pillContent
        }
        .font(VVMac.pillFont)
        .tracking(VVMac.pillTracking)
        .foregroundStyle(VVColor.fgPrimary)
        .lineLimit(1)
        .padding(.leading, VVMac.pillLeading)
        .padding(.trailing, VVMac.pillTrailing)
        .frame(height: VVMac.pillHeight)
        .fixedSize()
        .overlaySurface(cornerRadius: VVMac.pillHeight / 2)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.mode {
        case .listening:
            WaveformBars(meter: meter)
            if let startedAt = viewModel.recordingStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedText(from: startedAt, at: viewModel.recordingEndedAt ?? context.date))
                        .font(VVMac.numberFont.monospacedDigit())
                }
            }
            if viewModel.escapeCancelUnavailable {
                // Escape cannot reach us, so say so up front instead of failing silently.
                PillSeparator()
                Text(Self.escapeUnavailableNote).foregroundStyle(VVMac.pillSecondary)
            }
        case .finalizing:
            CollapsedWaveform(animated: viewModel.animatesProgress)
            Text("识别中").foregroundStyle(VVMac.pillSecondary)
        case .success:
            glyph("checkmark")
            if let count = viewModel.insertedCharacterCount {
                // No text-level undo exists, so the design's "⌘Z 撤销" half is omitted
                // rather than promising an action that would not happen.
                Text("已插入 \(count) 字")
                if let notice = viewModel.insertedNotice {
                    // Which engine wrote this, and why (DESIGN.md: text only, no new hue).
                    PillSeparator()
                    Text(notice).foregroundStyle(VVMac.pillSecondary)
                }
            } else {
                Text(viewModel.message)
            }
        case .failure:
            glyph("exclamationmark")
            Text(viewModel.message)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)
        case .cancelPending:
            glyph("xmark").foregroundStyle(VVMac.pillSecondary)
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                (Text("已取消 · ") + Text("\(remainingSeconds(at: context.date))").font(VVMac.numberFont.monospacedDigit()) + Text(" 秒内可撤销"))
                    .foregroundStyle(VVMac.pillSecondary)
            }
            PillSeparator()
            Button("撤销") { viewModel.onUndoCancel() }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
        case .preview:
            EmptyView()
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 13, height: 13)
    }

    private func remainingSeconds(at date: Date) -> Int {
        guard let deadline = viewModel.cancelDeadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    private func elapsedText(from startedAt: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Preview card (insertion could not be confirmed; user decides)

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                glyph("exclamationmark")
                Text(viewModel.message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            if !viewModel.text.isEmpty {
                ScrollView {
                    Text(viewModel.text)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxHeight: 88)
                .background(VVMac.quoteFill, in: RoundedRectangle(cornerRadius: VVMetric.radiusKey, style: .continuous))
            }

            HStack(spacing: 8) {
                Button("插入当前输入框") { viewModel.onInsertCurrent() }
                    .buttonStyle(VVButtonStyle(prominent: true))
                Button("复制") { viewModel.onCopy() }
                    .buttonStyle(VVButtonStyle())
                Spacer()
                Button("关闭") { viewModel.onDismiss() }
                    .buttonStyle(VVButtonStyle())
            }
        }
        .foregroundStyle(VVColor.fgPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlaySurface(cornerRadius: VVMetric.radiusCard)
    }
}

struct PillSeparator: View {
    var body: some View {
        Rectangle()
            .fill(VVMac.pillSeparator)
            .frame(width: 1, height: 14)
    }
}

/// Preview-only stand-in for the material: a pre-blurred desktop image. `ImageRenderer` and
/// `cacheDisplay` draw no behind-window blur, so DesignPreview supplies one. Nil in the app.
struct OverlayBackdropPreview {
    var image: Image
    /// Frame of the image in the coordinate space named `OverlayBackdropPreview.space`.
    var frame: CGRect
    static let space = "overlay-backdrop"
}

private struct OverlayBackdropPreviewKey: EnvironmentKey {
    static let defaultValue: OverlayBackdropPreview? = nil
}

extension EnvironmentValues {
    var overlayBackdropPreview: OverlayBackdropPreview? {
        get { self[OverlayBackdropPreviewKey.self] }
        set { self[OverlayBackdropPreviewKey.self] = newValue }
    }
}

private struct OverlaySurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.overlayBackdropPreview) private var backdropPreview
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    // Contact shadow only (1pt down, 2.5pt blur), masked to the outside of the
                    // shape so it never darkens the translucent surface. The layer gets a
                    // canvas larger than the surface before blurring: blur and mask rasterise
                    // within the view's own frame.
                    shape.fill(VVMac.shadowColor).offset(y: VVMac.shadowOffset)
                        .padding(VVMac.shadowInset).blur(radius: VVMac.shadowBlur)
                        .mask {
                            ZStack {
                                Rectangle()
                                shape.padding(VVMac.shadowInset).blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                        .padding(-VVMac.shadowInset)
                    // The lightest system grade: it keeps the desktop readable through the pill.
                    if let backdropPreview {
                        GeometryReader { proxy in
                            let frame = proxy.frame(in: .named(OverlayBackdropPreview.space))
                            backdropPreview.image
                                .resizable()
                                .frame(width: backdropPreview.frame.width, height: backdropPreview.frame.height)
                                .offset(x: backdropPreview.frame.minX - frame.minX, y: backdropPreview.frame.minY - frame.minY)
                                .blur(radius: 18)
                        }
                        .clipShape(shape)
                        // ultraThinMaterial ≈ blur + ~50% luminosity base; the base is drawn
                        // here so the composite is not darker than the real surface.
                        shape.fill(colorScheme == .dark ? Color(nsColor: VVColor.hex(0x1C1C1E, alpha: 0.5)) : Color.white.opacity(0.5))
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(VVMac.pillTint)
                }
            }
            .overlay {
                shape.strokeBorder(VVMac.pillStroke, lineWidth: VVMetric.hairline(displayScale))
            }
    }
}

extension View {
    func overlaySurface(cornerRadius: CGFloat) -> some View {
        modifier(OverlaySurface(cornerRadius: cornerRadius))
    }
}
