import SwiftUI
import WidgetKit

@main
struct VerbatimWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingControl()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        RecordingLiveActivity()
        #endif
    }
}

/// Control Center / Lock Screen / Action Button control. The label follows
/// the app's shared session state; the action is the app's
/// AudioRecordingIntent.
struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: RecordingControlKind.identifier,
            provider: RecordingControlValueProvider()
        ) { isRecording in
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label(
                    isRecording ? "停止录音" : "开始录音",
                    systemImage: isRecording ? "stop.circle.fill" : "mic.fill"
                )
            }
        }
        .displayName("\(MobileIdentity.displayName) 录音")
        .description("开始或停止一次逐字听写，结果进入键盘的待插入。")
    }
}

struct RecordingControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let directory = AppGroup.sharedDirectory() else { return false }
        return SharedSessionStateStore(directory: directory).read().effectivePhase() != .idle
    }
}
