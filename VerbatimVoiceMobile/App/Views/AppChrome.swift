import SwiftUI
import UIKit

/// Vertical placement shared by every app page. The mockups put the nav row
/// at y 54 on a 393×852 phone whose safe-area top is 59; pages are laid out
/// from `safeTop − 5`, so they match the mockup there and follow the status
/// bar on other phones.
enum VVLayout {
    static func top(_ safeTop: CGFloat) -> CGFloat { max(0, safeTop - 5) }
    static let navHeight: CGFloat = 44
}

/// Custom nav row (44): leading "‹ <app name>", centred headline title,
/// trailing 44×44 icon buttons. Matches the mockup's `.nav`.
struct VVNavBar<Trailing: View>: View {
    var title: String?
    var back: (() -> Void)?
    var backTitle = MobileIdentity.displayName
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .vvText(.headline)
                    .foregroundStyle(VVColor.fgPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 100)
            }
            HStack(spacing: 0) {
                if let back {
                    Button(action: back) {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 22, height: 22)
                            Text(backTitle).vvText(.body)
                        }
                        .foregroundStyle(VVColor.fgPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: VVLayout.navHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                    .accessibilityLabel("返回")
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) { trailing() }
                    .padding(.trailing, 8)
            }
        }
        .frame(height: VVLayout.navHeight)
    }
}

extension VVNavBar where Trailing == EmptyView {
    init(title: String?, back: (() -> Void)?) {
        self.init(title: title, back: back, trailing: { EmptyView() })
    }
}

/// 44×44 icon button for the nav row.
struct VVNavIcon: View {
    let systemName: String
    let label: String
    var size: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(VVColor.fgPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A page with the custom nav row, laid out from the measured top.
struct VVPage<Content: View, Trailing: View>: View {
    var title: String?
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                VVNavBar(title: title, back: back, trailing: trailing)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, VVLayout.top(proxy.safeAreaInsets.top))
            .ignoresSafeArea(edges: .top)
        }
        .background(VVColor.bgCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension VVPage where Trailing == EmptyView {
    init(title: String?, back: (() -> Void)?, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, back: back, trailing: { EmptyView() }, content: content)
    }
}

/// List section header (`.sec`): footnote, secondary, label left and a
/// tabular summary right; 24 above (12 for the first), 6 below.
struct VVSectionHeader: View {
    let title: String
    var detail: String?
    var first = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            if let detail { Text(detail).monospacedDigit() }
        }
        .vvText(.footnote)
        .foregroundStyle(VVColor.fgSecondary)
        .padding(.horizontal, 16)
        .padding(.top, first ? 12 : 24)
        .padding(.bottom, 6)
    }
}

/// Settings-style cell (`.cell`): min 44, 10/16 padding, body label with an
/// optional footnote under it, value and chevron on the right.
struct VVCell<Accessory: View>: View {
    let title: String
    var subtitle: String?
    /// 2 in settings rows, 3 in lexicon rows (`.term .lbl{gap:3px}`).
    var subtitleSpacing: CGFloat = 2
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: subtitleSpacing) {
                Text(title).vvText(.body).foregroundStyle(VVColor.fgPrimary)
                if let subtitle {
                    Text(subtitle).vvText(.footnote).foregroundStyle(VVColor.fgSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension VVCell where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, subtitleSpacing: CGFloat = 2) {
        self.init(title: title, subtitle: subtitle, subtitleSpacing: subtitleSpacing, accessory: { EmptyView() })
    }
}

struct VVChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(VVColor.fgTertiary)
            .frame(width: 16, height: 16)
    }
}

/// Value text in a cell (`.val`): body, secondary, tabular.
struct VVCellValue: View {
    let text: String
    var check = false

    var body: some View {
        HStack(spacing: 6) {
            if check {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VVColor.fgPrimary)
            }
            if !text.isEmpty { Text(text).monospacedDigit() }
        }
        .vvText(.body)
        .foregroundStyle(VVColor.fgSecondary)
    }
}

/// Rows separated by a hairline inset 16 from the leading edge.
struct VVRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                // Drawn over the row's top edge, taking no height (as the
                // mockup's `.row + .row:before`).
                row(element)
                    .overlay(alignment: .top) { if index > 0 { HairlineDivider(leadingInset: 16) } }
            }
        }
    }
}

/// Bottom mic bar (`.micbar`): 56 key row + 8 + the home area, with the
/// circle / capsule on the keyboard's column grid and centre line.
struct MicBar: View {
    let phase: MicControl.Phase
    var wave: Waveform.Mode = .line()
    var lined = true
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            MicControl(
                phase: phase,
                style: .bar,
                grid: VVGrid(width: proxy.size.width),
                scale: .bar,
                bandHeight: VVMetric.micAppBarHeight,
                wave: wave,
                ready: .perform(onStart),
                onCancel: onCancel,
                onFinish: onFinish
            )
        }
        .frame(height: VVMetric.micAppBarHeight)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            VVColor.bgCanvas
                .overlay(alignment: .top) { if lined { HairlineDivider() } }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Number with grouping separators ("1,284").
enum VVNumber {
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// The custom nav rows hide the system bar, which also disables the edge
/// swipe back. This re-enables it on the enclosing navigation controller,
/// beginning only when there is a page to go back to.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let pop = navigationController?.interactivePopGestureRecognizer else { return }
            pop.delegate = self
            pop.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
