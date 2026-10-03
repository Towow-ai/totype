#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

printf '== Core tests ==\n'
source "$ROOT/scripts/lib/env.sh"
mkdir -p .build/self-test
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  VerbatimVoiceCore/Sources/VerbatimCore/*.swift \
  scripts/core-self-test/main.swift \
  -o .build/self-test/verbatim-core-self-test
.build/self-test/verbatim-core-self-test

printf '\n== Profile equivalence (offline) ==\n'
scripts/profile_equivalence_test.sh

printf '\n== Completion deadline ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/CompletionDeadline.swift \
  scripts/completion-deadline-test/main.swift \
  -o .build/self-test/completion-deadline-test
.build/self-test/completion-deadline-test

printf '\n== S0 deterministic stability faults ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/CompletionDeadline.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift \
  scripts/stability-fault-test/main.swift \
  -o .build/self-test/stability-fault-test
.build/self-test/stability-fault-test

python3 scripts/session_timeline_report.py --help >/dev/null
printf 'ok  old/new JSONL timeline reader starts\n'

printf '\n== Personal secret store ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/Utilities/KeychainStore.swift \
  scripts/personal-secret-store-test/main.swift \
  -framework Security \
  -o .build/self-test/personal-secret-store-test
.build/self-test/personal-secret-store-test

printf '\n== Install runtime status ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/TextJoinPolicy.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/PersonalLexicon.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/NetworkResilience.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/App/InstallRuntimeStatusReporter.swift \
  scripts/install-status-test/main.swift \
  -o .build/self-test/install-runtime-status-test
.build/self-test/install-runtime-status-test

printf '\n== Retained archive round trip ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/*.swift \
  VerbatimVoice/Models/ProviderContextCompiler.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/Providers/ASRProvider.swift \
  VerbatimVoice/Audio/SessionAudioArchive.swift \
  scripts/archive-retention-test/main.swift \
  -framework AVFoundation \
  -framework AudioToolbox \
  -o .build/self-test/archive-retention-test
.build/self-test/archive-retention-test

python3 - <<'PY'
from pathlib import Path
source = Path('VerbatimVoice/App/ActiveDictationSession.swift').read_text()
method = source.split('func cancelTranscriptionPreservingArchive()', 1)[1].split('\n    }', 1)[0]
if 'archiveTask?.cancel()' in method or 'archive.cancel()' in method:
    raise SystemExit('retained cancellation must not cancel or delete the archive')
app = Path('VerbatimVoice/App/AppModel.swift').read_text()
if 'selectedReason: "user_cancelled_retained_draft"' not in app:
    raise SystemExit('retained draft history contract is missing')
print('ok  retained cancellation never destroys the archive')
PY

for script in scripts/make-dmg.sh scripts/publish-public.sh scripts/changelog-section.sh scripts/ci-select-xcode.sh scripts/install.sh scripts/build.sh scripts/lib/env.sh scripts/oss-scan.sh scripts/export-public.sh scripts/fixtures/make-fixture.sh \
    scripts/install_personal.sh scripts/build_personal.sh scripts/install-state-policy.sh; do
  [[ -f "$script" ]] && bash -n "$script"
done

source scripts/install-state-policy.sh
install_state_allows_exchange idle
for blocked_state in listening finalizing inserting criticalPersist preview failed unknown ""; do
  if install_state_allows_exchange "$blocked_state"; then
    printf 'install state policy incorrectly allowed: %s\n' "${blocked_state:-<empty>}" >&2
    exit 1
  fi
done
printf 'ok  only idle runtime state can be exchanged\n'

mkdir -p .build/install-tools
/usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=10.12 \
  scripts/install-atomic-swap/main.c -o .build/install-tools/atomic-swap

printf '\n== Swift parser ==\n'
while IFS= read -r -d '' file; do
  swiftc -frontend -parse "$file" >/dev/null
  printf 'ok  %s\n' "$file"
done < <(find VerbatimVoice VerbatimVoiceCore/Sources VerbatimVoiceCore/Tests -name '*.swift' -print0 | sort -z)

printf '\n== Local model download constants ==\n'
python3 - <<'PY'
import re
from pathlib import Path

script = Path('scripts/setup_local_sensevoice.sh').read_text()
swift = Path('VerbatimVoice/Providers/LocalModelStore.swift').read_text()
for name in ('RUNTIME_URL', 'MODEL_URL', 'VAD_URL', 'RUNTIME_SHA256', 'MODEL_SHA256', 'VAD_SHA256', 'EXECUTABLE_SHA256'):
    value = re.search(rf'^{name}="([^"]+)"', script, re.M).group(1)
    if f'"{value}"' not in swift:
        raise SystemExit(f'LocalModelStore.swift does not carry {name} from setup_local_sensevoice.sh')
print('ok  download URLs and SHA-256 values match setup_local_sensevoice.sh')
PY

printf '\n== Universal Clipboard guard ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/Input/PasteboardInserter.swift').read_text()
general_accesses = source.count('NSPasteboard.general')
if general_accesses != 1:
    raise SystemExit(
        'Automatic insertion must not touch NSPasteboard.general; '
        f'expected the explicit Copy action only, found {general_accesses} accesses'
    )
for forbidden in ('func paste(', 'postPasteShortcut(', 'ClipboardSnapshot'):
    if forbidden in source:
        raise SystemExit(f'Automatic clipboard fallback returned: {forbidden}')
print('ok  only the explicit Copy action can write the general pasteboard')

dispatch_branch = source.split('if await postUnicodeText', 1)[1].split('} else {', 1)[0]
if 'status: .dispatched' not in dispatch_branch:
    raise SystemExit(
        'A posted Unicode event must complete as dispatched'
    )
if 'switch await waitForVerification' in dispatch_branch:
    raise SystemExit('Accessibility verification returned to the user critical path')
print('ok  Unicode dispatch is terminal; Accessibility cannot reopen Preview')
PY

printf '\n== CoreAudio blocking-start isolation ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/Audio/WarmAudioEngine.swift').read_text()
candidate = source.split('private final class AudioEngineCandidate', 1)[1].split(
    'final class WarmAudioEngine', 1
)[0]
coordinator = source.split('private func startFreshEngine', 1)[1].split(
    '\n    func stop()', 1
)[0]

for required in (
    'controlQueue.async',
    'try engine.start()',
    'candidate.quarantine()',
    'CompletionDeadline.wait',
    'engineStartDeadlineNanoseconds',
    'outstandingStartAttemptIDs.insert(candidate.id)',
    'startedCandidate.accept()',
    'requiredRecoveryGeneration',
    'recoveryGeneration == scheduledGeneration',
    '系统麦克风启动请求已释放',
):
    if required not in source:
        raise SystemExit(f'CoreAudio start isolation contract missing: {required}')

if 'try engine.start()' not in candidate.split('controlQueue.async', 1)[1]:
    raise SystemExit('AVAudioEngine.start returned to the caller/main executor')
if coordinator.index('activeEngine = startedCandidate') < coordinator.index('startedCandidate.accept()'):
    raise SystemExit('candidate became active before deadline acceptance')
for required in (
    'bufferedBeforeAcceptance',
    'using prepared idle audio graph',
    'prepareStandbyEngine()',
    'await candidate.prepare()',
    'pendingCandidateCleanups == 0',
    'scheduleStandbyPreparationAfterCleanup()',
    'candidate.quarantine { [weak self] in',
):
    if required not in source:
        raise SystemExit(f'first-word startup guard missing: {required}')
print('ok  blocking AVAudioEngine.start is isolated, bounded, and late-safe')
PY

printf '\n== History retranscription and persistence isolation ==\n'
python3 - <<'PY'
from pathlib import Path

model = Path('VerbatimVoice/App/AppModel.swift').read_text()
view = Path('VerbatimVoice/UI/SettingsView.swift').read_text()
method = model.split('func retranscribeHistory(', 1)[1].split('\n    private func historyProvider', 1)[0]
persist = model.split('private func persist(', 1)[1].split('\n    private func finishCriticalPersistence', 1)[0]

for required in (
    'HistoryRetranscriptionPolicy.deadlineNanoseconds',
    'cloudReplayPacingNanoseconds',
    '音频已发送，等待',
):
    if required not in method:
        raise SystemExit(f'history retranscription guard missing: {required}')
if 'timeoutNanoseconds: 20_000_000_000' in method:
    raise SystemExit('fixed 20-second history retranscription deadline returned')
if persist.index('finishCriticalPersistence()') > persist.index('refreshHistory()'):
    raise SystemExit('critical persistence still includes UI history refresh')
history = view.split('private var history:', 1)[1].split('\n    private func historyRow', 1)[0]
if 'LazyVStack' in history or 'VStack(alignment: .leading, spacing: 12)' not in history:
    raise SystemExit('history view can still enter the macOS 26 lazy layout loop')
print('ok  history replay is duration-aware and persistence/UI work is isolated')
PY

printf '\n== Session-scoped microphone ownership ==\n'
python3 - <<'PY'
from pathlib import Path

model = Path('VerbatimVoice/App/AppModel.swift').read_text()
settings = Path('VerbatimVoice/App/AppSettings.swift').read_text()
settings_view = Path('VerbatimVoice/UI/SettingsView.swift').read_text()
audio = Path('VerbatimVoice/Audio/WarmAudioEngine.swift').read_text()

for forbidden in (
    'if settings.keepMicrophoneWarm',
    'guard audioEngine.hasRecentAudioFrames()',
    'func startMicrophone()',
    '麦克风常热（防止丢失第一句话）',
):
    if forbidden in model + settings_view:
        raise SystemExit(f'always-on microphone path returned: {forbidden}')

for required in (
    'try await self.audioEngine.requestPermissionAndStart()',
    'private func releaseAudioCapture()',
    'session.finishInput()\n                releaseAudioCapture()',
    '空闲时麦克风已释放',
):
    if required not in model:
        raise SystemExit(f'session-scoped microphone contract missing: {required}')

if 'defaults.set(false, forKey: "keepMicrophoneWarm")' not in settings:
    raise SystemExit('legacy always-on preference is not retired')
for required in ('prepareForNewCapture()', 'waitForFirstAudio()', 'ringBuffer.clear()'):
    if required not in audio:
        raise SystemExit(f'first-frame startup boundary missing: {required}')
standby = audio.split('private func prepareStandbyEngine()', 1)[1].split(
    'private func discardStandbyEngine()', 1
)[0]
if '.start()' in standby or 'startWarm()' in standby:
    raise SystemExit('idle standby graph started microphone I/O')
print('ok  idle releases audio; capture opens on demand and waits for fresh PCM')
PY

printf '\n== Global Escape cancellation ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/Input/RightOptionMonitor.swift').read_text()
modifier = source.split('private func installModifierTapOnTapThread()', 1)[1].split(
    'private func removeModifierTapOnTapThread()', 1
)[0]
escape = source.split('private func installEscapeTapOnTapThread()', 1)[1].split(
    'private func removeEscapeTapOnTapThread()', 1
)[0]
handler = source.split('private func handleEscapeTap(', 1)[1].split('\n    }', 1)[0]
if 'guard type == .keyDown' not in handler:
    raise SystemExit('Escape tap may consume non-keyDown events')
# Right Option: flagsChanged only, never consumes, Accessibility-authorised
# (.listenOnly needs Input Monitoring, whose TCC record here is a stale cdhash).
for required in ('CGEventType.flagsChanged.rawValue', 'options: .defaultTap', 'CGEvent.tapIsEnabled(tap: tap)'):
    if required not in modifier:
        raise SystemExit(f'right Option tap contract missing: {required}')
for forbidden in ('CGEventType.keyDown.rawValue', 'options: .listenOnly', '? nil'):
    if forbidden in modifier:
        raise SystemExit(f'right Option tap must stay flagsChanged-only and pass-through: {forbidden}')
# Escape: the only active tap, keyDown only.
for required in ('CGEventType.keyDown.rawValue', 'options: .defaultTap', '? nil'):
    if required not in escape:
        raise SystemExit(f'Escape tap contract missing: {required}')
# 2026-10-01: a wider Escape mask was accepted without Input Monitoring but never
# received keyDown, hiding the missing grant. Escape must stay keyDown-only and
# gate on the Input Monitoring preflight; unavailability must be surfaced.
if 'flagsChanged' in escape:
    raise SystemExit('Escape tap mask must not include flagsChanged (no wide-mask fallback)')
make_escape = escape.split('private func makeEscapeTap()', 1)[1]
if 'eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue)' not in make_escape:
    raise SystemExit('Escape tap must be created with the keyDown-only mask')
if 'Self.hasInputMonitoringAccess' not in escape or 'CGPreflightListenEventAccess()' not in source:
    raise SystemExit('Escape self-check must preflight Input Monitoring (CGPreflightListenEventAccess)')
for required in (
    'escape cancel unavailable: input monitoring not granted',
    'private func probeEscapeCancelOnTapThread()',
    'escape session: tapActive=',
):
    if required not in source:
        raise SystemExit(f'Escape self-check / health log missing: {required}')
app_model = Path('VerbatimVoice/App/AppModel.swift').read_text()
if 'Privacy_ListenEvent' not in app_model or 'hotkey.refreshEscapeCancelAvailability()' not in app_model:
    raise SystemExit('Escape unavailability is not surfaced or re-checked')
for required in (
    'Self.escapeKeyCode',
    'self?.onCancel?()',
    'setCancelCaptureActive(_ active: Bool)',
    'self.installEscapeTapOnTapThread()',
    'self.removeEscapeTapOnTapThread()',
    'handle(event, canConsumeCancel: false)',
    'return consumed ? nil : event',
    'rightOptionDeviceMask',
    'EventTapThread',
):
    if required not in source:
        raise SystemExit(f'Escape cancellation contract missing: {required}')
if 'CFRunLoopGetMain()' in source:
    raise SystemExit('event taps returned to the main run loop')
app = Path('VerbatimVoice/App/AppModel.swift').read_text()
if 'setCancelCaptureActive(state == .starting || state == .listening)' not in app:
    raise SystemExit('Escape capture is not scoped to active recording states')
print('ok  right Option tap is flagsChanged-only off-main; Escape tap exists only while recording')
PY

printf '\n== Right Option lost-release recovery ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/Input/RightOptionMonitor.swift').read_text()
policy = Path(
    'VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift'
).read_text()
for required in (
    'ModifierPressEdgePolicy()',
    'DispatchTime.now().uptimeNanoseconds',
    'case .acceptedPress:',
):
    if required not in source:
        raise SystemExit(f'right Option recovery integration missing: {required}')
for required in (
    'duplicateWindowNanoseconds',
    'Accept a later press even if `isPressed` is still true',
):
    if required not in policy:
        raise SystemExit(f'right Option recovery policy missing: {required}')
if 'guard pressed != isPressed else { return }' in source:
    raise SystemExit('brittle modifier boolean latch returned')
print('ok  right Option recovers after a missing modifier-up event')
PY

printf '\n== Late dispatch and main-thread load guards ==\n'
python3 - <<'PY'
from pathlib import Path

app = Path('VerbatimVoice/App/AppModel.swift').read_text()
menu = Path('VerbatimVoice/UI/MenuBarView.swift').read_text()
if '@Published private(set) var audioLevel' in app:
    raise SystemExit('audio level is published through AppModel again')
finish = app.split('private func finish(', 1)[1].split('private func persist(', 1)[0]
if finish.find('lateDispatchHazard(') < 0 or finish.find('lateDispatchHazard(') > finish.find('inserter.insertAtApplication('):
    raise SystemExit('late automatic insertion is not guarded before dispatch')
begin = app.split('func beginDictation()', 1)[1].split('\n    }', 1)[0]
if 'stopRequestedUptime = nil' not in begin:
    raise SystemExit('stale stop time from a previous utterance can withhold insertion')
undo = app.split('func undoCancel()', 1)[1].split('\n    }', 1)[0]
if 'stopRequestedUptime = ProcessInfo.processInfo.systemUptime' not in undo:
    raise SystemExit('undo-cancel finalization must reset the typing guard baseline')
if '.hidSystemState' not in app:
    raise SystemExit('late dispatch guard must count only physical keyboard input')
if 'closing.contentViewController = nil' not in menu:
    raise SystemExit('closed console window keeps observing AppModel')
capture = app.split('private func scheduleBackgroundCorrectionCapture(', 1)[1].split('\n    }\n', 1)[0]
if 'Task.detached' not in capture or 'generation == self.correctionCaptureGeneration' not in capture:
    raise SystemExit('post-insertion AX capture must stay off-main and yield to newer utterances')
monitor = Path('VerbatimVoice/Input/AccessibilityTarget.swift').read_text()
if 'AXEnhancedUserInterface" as CFString,\n            kCFBooleanTrue' in monitor:
    raise SystemExit('VoiceOver-mode AXEnhancedUserInterface must not be forced on target apps')
if 'secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)' not in monitor:
    raise SystemExit('correction observation must pause while the user is typing')
print('ok  late insertion yields to the user; level/console updates stay off AppModel observers')
PY

printf '\n== Critical-path latency isolation ==\n'
python3 - <<'PY'
from pathlib import Path

hotkey = Path('VerbatimVoice/Input/RightOptionMonitor.swift').read_text()
startup = Path('VerbatimVoice/App/AppModel.swift').read_text()
insertion = Path('VerbatimVoice/Input/PasteboardInserter.swift').read_text()

success_branch = hotkey.split('if created {', 1)[1].split(
    'installNSEventFallback()', 1
)[0]
if 'installNSEventFallback()' in success_branch or 'return' not in success_branch:
    raise SystemExit('CGEventTap and NSEvent are running concurrently again')
if 'targetTask = Task.detached' in startup:
    raise SystemExit('Accessibility target capture returned to audio startup')
if 'CloudSelectionPolicy.preferenceWindowNanoseconds' not in startup:
    raise SystemExit('provider preference window is not policy-driven')
if 'CloudLocalRacePolicy.decide(' not in startup or 'session.startLocalFallback(' not in startup:
    raise SystemExit('post-stop local race is not policy-driven')
for provider in ('VerbatimVoice/Providers/SonioxProvider.swift', 'VerbatimVoice/Providers/AliyunASRProvider.swift'):
    if 'invalidateAndCancel' in Path(provider).read_text():
        raise SystemExit(f'{provider} must not invalidate the shared URLSession')
finish_path = startup.split('private func finish(', 1)[1].split(
    'private func persist(', 1
)[0]
for forbidden in (
    'targetService.capture(processIdentifier:',
    'Task.sleep(nanoseconds: 220_000_000)',
):
    if forbidden in finish_path:
        raise SystemExit(f'AX/activation wait returned after result selection: {forbidden}')
direct_path = insertion.split('func insertAtApplication(', 1)[1].split(
    'private func waitForVerification', 1
)[0]
for forbidden in ('for attempt in 0..<8', 'targetService.capture(processIdentifier:'):
    if forbidden in direct_path:
        raise SystemExit(f'AX scan returned to direct insertion path: {forbidden}')
for required in ('postUnicodeText(text, targetPID: expectedPID)', 'onDispatched?()'):
    if required not in direct_path:
        raise SystemExit(f'direct Unicode dispatch contract missing: {required}')
print('ok  one hotkey backend; audio startup, result selection and direct insertion do not await AX')
PY

printf '\n== History one-click copy UX ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/UI/SettingsView.swift').read_text()
for forbidden in (
    '逐字输入 · 个人模式',
    'Text(model.statusMessage)',
    'healthMetric(',
    'Image(systemName: record.disposition',
):
    if forbidden in source:
        raise SystemExit(f'overview diagnostic clutter returned: {forbidden}')
for required in (
    'activateHistoryRecord(record, revealDetailsForEmpty: true)',
    'model.copyHistoryRecord(record)',
    'return copiedRecordID == record.id ? "已复制" : "复制"',
    'Button(expandedHistoryIDs.contains(record.id) ? "收起" : "详情")',
):
    if required not in source:
        raise SystemExit(f'one-click history contract missing: {required}')
print('ok  record click copies directly; details remain a secondary explicit action')
PY

printf '\n== Soniox bounded recovery ==\n'
python3 - <<'PY'
from pathlib import Path

source = Path('VerbatimVoice/Providers/SonioxProvider.swift').read_text()
policy = Path('VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift').read_text()
finalize = source.split('private func finalizeCurrentConnection()', 1)[1].split(
    'private func sendFinalizationRequest', 1
)[0]
continuation_position = finalize.find('finalizeContinuation = continuation')
send_position = finalize.find('sendFinalizationRequest(')
if continuation_position < 0 or send_position < 0 or continuation_position > send_position:
    raise SystemExit('Soniox finalize frame can race ahead of its continuation')
for required in (
    'recoverAndFinalize(after:',
    'SonioxRecoveryPolicy.maximumRecoveryAttempts',
    'sendMessage(',
    'generation == connectionGeneration',
    'replayAudioTruncated',
    'notify: !isRetryable(error)',
    'failActiveRequest(failure, notify: false)',
):
    if required not in source:
        raise SystemExit(f'Soniox recovery contract missing: {required}')
for required in ('request_timeout', 'service_unavailable', 'internal_error'):
    if required not in policy:
        raise SystemExit(f'Soniox retry classification missing: {required}')
print('ok  continuation-before-finalize; bounded send deadlines and one full-audio recovery')
PY

printf '\n== Local provider integration ==\n'
scripts/provider_integration_test.sh

printf '\n== Aliyun realtime protocol ==\n'
scripts/aliyun_protocol_test.sh

printf '\n== Soniox personal context routing ==\n'
scripts/soniox_context_test.sh

printf '\n== Soniox hedged connect (local WebSocket server) ==\n'
swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/*.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/Providers/ASRProvider.swift \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/Providers/SonioxProvider.swift \
  scripts/soniox-hedge-test/main.swift \
  -o .build/self-test/soniox-hedge-test
.build/self-test/soniox-hedge-test

printf '\n== Property lists ==\n'
plutil -lint VerbatimVoice/Resources/Info.plist
plutil -lint VerbatimVoice/Resources/VerbatimVoice.entitlements
plutil -lint VerbatimVoice.xcodeproj/project.pbxproj

printf '\n== Xcode source references ==\n'
python3 - <<'PY'
import re
from collections import Counter
from pathlib import Path

root = Path.cwd()
pbx = (root / 'VerbatimVoice.xcodeproj/project.pbxproj').read_text()
actual = {
    str(path.relative_to(root))
    for path in (root / 'VerbatimVoice').rglob('*.swift')
} | {
    str(path.relative_to(root))
    for path in (root / 'VerbatimVoiceCore/Sources').rglob('*.swift')
}

# File references are stored with a path relative to their owning PBXGroup.
# Compare basenames as a compact integrity check, then fail on duplicate build entries.
referenced_names = re.findall(r'path = ([^;]+\.swift);', pbx)
actual_names = [Path(path).name for path in actual]
missing_names = sorted(set(actual_names) - set(referenced_names))
unknown_names = sorted(set(referenced_names) - set(actual_names))
source_phase_names = re.findall(r'/\* ([^*/]+\.swift) in Sources \*/', pbx)
counts = Counter(source_phase_names)
duplicates = sorted(name for name, count in counts.items() if count > 2)
# Each source appears once as a PBXBuildFile comment and once in PBXSourcesBuildPhase.
phase_missing = sorted(set(actual_names) - set(source_phase_names))

if missing_names or unknown_names or duplicates or phase_missing:
    print('missing file references:', missing_names)
    print('unknown file references:', unknown_names)
    print('duplicate source entries:', duplicates)
    print('not in Sources phase:', phase_missing)
    raise SystemExit(1)

print(f'ok  {len(actual_names)} Swift source files are referenced')
PY

printf '\n== App build ==\n'
APP_PATH="$(scripts/build.sh | tail -n 1)"
if [[ "$APP_PATH" != *.app.disabled ]]; then
  echo "构建产物必须使用 .app.disabled，避免污染 Launch Services/TCC 身份解析：$APP_PATH" >&2
  exit 1
fi
echo "$APP_PATH"

printf '\n== Bundled local SenseVoice smoke test ==\n'
scripts/local_sensevoice_smoke_test.sh "$APP_PATH"

printf '\nAll checks and the macOS app build passed.\n'
