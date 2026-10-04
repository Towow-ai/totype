import SwiftUI
import UIKit

/// Maps `KeyboardModel` onto the design-v2 keyboard face
/// (`VoiceKeyboardView`, shared with the app's design preview). No protocol
/// or state-machine logic lives here; it only derives what to show.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.openURL) private var openURL
    /// Timer value held while recognising (the shared state has no stop time).
    @State private var frozenElapsed: TimeInterval?

    var body: some View {
        VoiceKeyboardView(state: state, actions: actions, globe: globe)
            .onAppear {
                let action = openURL
                model.openURL = { action($0) }
            }
            .onChange(of: model.phase) { old, new in
                if new == .finalizing, old == .recording, let start = model.session.recordingStartedAt {
                    frozenElapsed = Date().timeIntervalSince(start)
                } else if new != .finalizing {
                    frozenElapsed = nil
                }
            }
    }

    private var globe: GlobeKeySource {
        if model.needsGlobeKey, let controller = model.inputController { return .system(controller) }
        return .none
    }

    private var state: VoiceKeyboardState {
        var s = VoiceKeyboardState()
        s.layer = model.layer == .voice ? .voice : .letters
        s.returnTitle = model.returnTitle
        s.micEnabled = model.hasFullAccess
        s.micBusy = model.waitingForApp
        if model.hasFullAccess, !model.sessionLive, !model.waitingForApp {
            // No live session: opening the app is the only way, and `Link`
            // is the open path proven on the device.
            s.micLink = model.recordURL
        }

        switch model.phase {
        case .starting:
            // No "recording" before the first PCM buffer (README invariant):
            // same shapes, grey dots, timer at 0:00.
            s.mic = .listening
            s.wave = Waveform.waiting
        case .recording:
            s.mic = .listening
            s.wave = .live(model.levels.map { Float($0) / 255 })
            if let start = model.session.recordingStartedAt { s.elapsed = .running(since: start) }
        case .finalizing:
            s.mic = .finalizing
            s.wave = .line()
            if let frozenElapsed { s.elapsed = .frozen(frozenElapsed) }
        case .idle:
            s.mic = .ready
        }
        s.status = status
        s.fallbackNote = model.session.fallbackProviderName.map { "已用\($0)" }
        return s
    }

    /// One sentence per state; the dictation phase wins, then what the user
    /// can act on (undo, pending, failure), then the session.
    private var status: VoiceKeyboardState.Status {
        switch model.phase {
        case .starting: return .starting
        case .recording: return .listening
        case .finalizing: return .finalizing
        case .idle: break
        }
        if let offer = model.undoOffer { return .inserted(count: offer.text.count) }
        if let entry = model.pending { return .pending(preview: entry.text) }
        if let failure = model.failure {
            let reason = failure.failureReason ?? "没有得到可用的转写结果"
            if failure.state == .retrying { return .retrying }
            return (failure.retryCount ?? 0) > 0 ? .retryFailed(reason: reason) : .failed(reason: reason)
        }
        if let error = model.recentError { return .failed(reason: error) }
        if let notice = model.notice { return .notice(notice) }
        if !model.hasFullAccess { return .noFullAccess }
        if model.waitingForApp { return .waitingForApp }
        if model.sessionLive { return .quiet }
        if model.session.sessionPaused { return .paused }
        return .first
    }

    private var actions: VoiceKeyboardActions {
        let model = model
        return VoiceKeyboardActions(
            keys: KeyboardKeyActions(
                insert: { model.insert($0) },
                deleteBackward: { model.deleteBackward() },
                deleteWordBackward: { model.deleteWordBackward() },
                moveCursor: { model.moveCursor(by: $0) },
                returnKey: { model.returnKey() },
                click: { model.playClick() }
            ),
            mic: { model.micTapped() },
            cancel: { model.cancelTapped() },
            finish: { model.finishTapped() },
            undo: { model.undoInsert() },
            retry: { model.retryTapped() },
            deferRetry: { model.deferRetryTapped() },
            insertPending: { model.insertPending() },
            discardPending: { model.discardPending() },
            setLayer: { model.layer = $0 == .voice ? .voice : .letters }
        )
    }
}
