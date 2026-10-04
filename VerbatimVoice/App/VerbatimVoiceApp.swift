import SwiftUI

@main
struct VerbatimVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppReopenDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Design snapshots only (VERBATIM_DESIGN_PREVIEW set by hand). Renders fake
        // data to PNG files and exits before AppModel — hotkey, audio, history — exists.
        // Without the variable this is a single environment lookup and returns.
        // Compiled out of release builds.
        #if DEBUG
        DesignPreview.runAndExitIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: menuIcon)
                .accessibilityLabel(AppIdentity.displayName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    /// Template image from design-v2/icons: two quotation marks; a filled dot is
    /// added while the microphone is capturing. Monochrome, so the system inverts it.
    private var menuIcon: NSImage {
        switch model.state {
        case .starting, .listening:
            return BrandMark.menuBarRecording
        default:
            return BrandMark.menuBarIdle
        }
    }
}
