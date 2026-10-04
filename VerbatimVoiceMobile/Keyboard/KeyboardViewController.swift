import SwiftUI
import UIKit

/// Root input view. Adopting `UIInputViewAudioFeedback` is what lets
/// `UIDevice.playInputClick()` make the system key click (it still follows
/// the user's Keyboard Clicks setting).
final class ClickableInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Keyboard extension entry point. Keeps memory small (no assets, one
/// SwiftUI view); the extension never records or touches the network.
final class KeyboardViewController: UIInputViewController {
    /// Status row 44 + four rows (43, gap 11) + 8 = 257 (DESIGN.md §6). The
    /// 34pt strip below belongs to the system on Face ID phones.
    static let portraitHeight: CGFloat = VVGrid(width: 0).contentHeight
    static let landscapeHeight: CGFloat = VVGrid(width: 0, compact: true).contentHeight

    private lazy var model = KeyboardModel(controller: self)
    private var heightConstraint: NSLayoutConstraint?

    override func loadView() {
        let inputView = ClickableInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardRootView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let height = view.heightAnchor.constraint(equalToConstant: currentHeight)
        height.priority = .defaultHigh
        heightConstraint = height
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _) in
            controller.heightConstraint?.constant = controller.currentHeight
        }
    }

    /// Close to the system keyboard: taller in portrait, shorter when the
    /// phone is landscape (compact height).
    private var currentHeight: CGFloat {
        traitCollection.verticalSizeClass == .compact ? Self.landscapeHeight : Self.portraitHeight
    }

    /// UIInputView keeps internal reference cycles (Keyman FB16499288);
    /// detaching the hosting child explicitly stops instances piling up
    /// across keyboard switches (KeyboardKit #434).
    deinit {
        MainActor.assumeIsolated {
            for child in children {
                child.willMove(toParent: nil)
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
        }
    }

    /// Nothing here may touch `textDocumentProxy` or the controller's
    /// input-mode state: when the keyboard comes back after the user swiped
    /// back from the app, the proxy still points at the previous host
    /// connection, and `needsInputModeSwitchKey` crashed in `objc_msgSend`
    /// (`-[_UITextDocumentInterface _controllerState]`, device crash log
    /// 2026-10-01). A crash makes iOS fall back to the system keyboard, and a
    /// SIGSEGV cannot be caught, so the only defence is timing: those reads
    /// happen after `viewDidAppear`.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        heightConstraint?.constant = currentHeight
        // Darwin notifications are only hints; always re-read on appearance.
        model.willAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.didAppear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Can fire while the keyboard is being re-presented; the model only
        // reads the proxy once it has appeared.
        model.textDidChange()
    }
}
