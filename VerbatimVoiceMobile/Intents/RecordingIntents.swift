import AppIntents
import Foundation

// Compiled into both the app and the widget extension (the Control widget
// needs the intent type). `VERBATIM_MAIN_APP` is defined only for the app.
// AudioRecordingIntent is a system intent that runs in the app process; if a
// device build shows it running in the extension instead, it is a no-op
// there. Whether a background/cold start can record is real-device probe H3.

enum RecordingControlKind {
    static let identifier = MobileIdentity.label("recording-control")
}

struct ToggleRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "开始或停止录音"
    static let description = IntentDescription("开始一次逐字听写；正在录音时结束并转写，结果进入键盘的待插入。")

    func perform() async throws -> some IntentResult {
        #if VERBATIM_MAIN_APP
        await DictationController.shared.toggle(trigger: .intent)
        #endif
        return .result()
    }
}

struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "开始录音"
    static let description = IntentDescription("开始一次逐字听写。")

    func perform() async throws -> some IntentResult {
        #if VERBATIM_MAIN_APP
        await DictationController.shared.start(trigger: .intent)
        #endif
        return .result()
    }
}

struct StopRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "停止录音"
    static let description = IntentDescription("结束当前录音并转写。")

    func perform() async throws -> some IntentResult {
        #if VERBATIM_MAIN_APP
        await DictationController.shared.stop(reason: .user)
        #endif
        return .result()
    }
}

/// "取消" on the Live Activity and Dynamic Island: drops the running
/// dictation (the audio stays in history). Runs in the app process.
struct CancelRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "取消录音"
    static let description = IntentDescription("取消这次录音，不插入；音频留在历史里。")

    func perform() async throws -> some IntentResult {
        #if VERBATIM_MAIN_APP
        await DictationController.shared.cancel()
        #endif
        return .result()
    }
}

/// "结束会话" on the Live Activity and Dynamic Island. LiveActivityIntent
/// runs in the app process, which owns the audio engine.
struct EndSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束录音会话"
    static let description = IntentDescription("停止后台麦克风；正在录的内容会先转写完。")

    func perform() async throws -> some IntentResult {
        #if VERBATIM_MAIN_APP
        await DictationController.shared.endSession(reason: .user)
        #endif
        return .result()
    }
}
