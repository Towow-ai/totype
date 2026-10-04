#!/usr/bin/env bash
# Type-checks the three iOS targets against the Mac Catalyst SDK, which is all
# that Command Line Tools provide (no iOS SDK without Xcode).
#
# Limits of this check:
#  - ActivityKit is unavailable under Catalyst; the code behind
#    `#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)` is not
#    checked until an iOS SDK build.
#  - Catalyst exposes a few macOS-only Foundation APIs that iOS lacks.
#  - The app group implicitly imports CoreAudio (see below).
#
# The macOS files reused by the app are read from project.yml (the
# `BEGIN mac-reuse` block), so this check and the Xcode build compile the
# same file set. TOTYPE_PRIVATE_HOST_RETURN follows Config/Local.xcconfig.
set -euo pipefail

MOBILE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MOBILE/.." && pwd)"
SDK="${VERBATIM_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
TARGET="arm64-apple-ios18.0-macabi"
CACHE="$MOBILE/.build/typecheck-module-cache"
LOGS="$MOBILE/.build/typecheck-logs"
mkdir -p "$CACHE" "$LOGS"

MAC_REUSE=()
while IFS= read -r line; do
  MAC_REUSE+=("$MOBILE/$line")
done < <(sed -n '/# BEGIN mac-reuse/,/# END mac-reuse/p' "$MOBILE/project.yml" \
          | sed -n 's/^[[:space:]]*- path:[[:space:]]*\(.*\.swift\)[[:space:]]*$/\1/p')
if [[ ${#MAC_REUSE[@]} -eq 0 ]]; then
  echo "project.yml 里没有找到 mac-reuse 文件列表" >&2
  exit 1
fi

# Same switch as the Xcode build (Config/Shared.xcconfig, default NO).
FLAGS=()
if grep -Eq '^[[:space:]]*TOTYPE_PRIVATE_HOST_RETURN[[:space:]]*=[[:space:]]*YES' "$MOBILE/Config/Local.xcconfig" 2>/dev/null; then
  FLAGS=(-D TOTYPE_PRIVATE_HOST_RETURN)
fi
echo "TOTYPE_PRIVATE_HOST_RETURN: $([[ ${#FLAGS[@]} -gt 0 ]] && echo YES || echo NO)"

swift_files() { find "$@" -name '*.swift' -print | sort; }

CORE=($(swift_files "$ROOT/VerbatimVoiceCore/Sources/VerbatimCore"))
SHARED=($(swift_files "$MOBILE/Shared"))
INTENTS=($(swift_files "$MOBILE/Intents"))
APP=($(swift_files "$MOBILE/App"))
KEYBOARD=($(swift_files "$MOBILE/Keyboard"))
WIDGETS=($(swift_files "$MOBILE/Widgets"))
# Design layer (tokens, type, mic control, waveform) is compiled into all
# three targets; the keyboard face (KeyboardUI) into the app and keyboard.
DESIGN=($(swift_files "$MOBILE/Design"))
KEYBOARD_UI=($(swift_files "$MOBILE/KeyboardUI"))

check() {
  local name="$1"; shift
  swiftc -typecheck \
    -sdk "$SDK" \
    -target "$TARGET" \
    -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -I "$SDK/System/iOSSupport/usr/include" \
    -L "$SDK/System/iOSSupport/usr/lib" \
    -module-cache-path "$CACHE" \
    -parse-as-library \
    -module-name "$name" \
    ${FLAGS[@]+"${FLAGS[@]}"} \
    "$@" >"$LOGS/${name}.log" 2>&1
}

# The three groups are independent; run them in parallel (~90 s each).
# Catalyst-only shim: on macOS and iOS, `import AVFoundation` also brings in
# the CoreAudio Swift overlay (UnsafeMutableAudioBufferListPointer, used by the
# reused PCMConverter.swift); under Catalyst it does not, so import it here.
check VerbatimVoiceMobile -D VERBATIM_MAIN_APP -Xfrontend -import-module -Xfrontend CoreAudio \
  "${CORE[@]}" "${MAC_REUSE[@]}" "${SHARED[@]}" "${INTENTS[@]}" "${DESIGN[@]}" "${KEYBOARD_UI[@]}" "${APP[@]}" &
APP_PID=$!
check VerbatimKeyboard -application-extension \
  -import-objc-header "$MOBILE/Keyboard/Keyboard-Bridging-Header.h" \
  "${SHARED[@]}" "${DESIGN[@]}" "${KEYBOARD_UI[@]}" "${KEYBOARD[@]}" &
KEYBOARD_PID=$!
check VerbatimWidgets -application-extension \
  "${SHARED[@]}" "${INTENTS[@]}" "${DESIGN[@]}" "${WIDGETS[@]}" &
WIDGETS_PID=$!

status=0
for pair in "VerbatimVoiceMobile:$APP_PID" "VerbatimKeyboard:$KEYBOARD_PID" "VerbatimWidgets:$WIDGETS_PID"; do
  name="${pair%%:*}"; pid="${pair##*:}"
  if wait "$pid"; then
    warnings=$(grep -c "warning:" "$LOGS/${name}.log" || true)
    echo "ok    ${name}（${warnings} 条警告，日志 .build/typecheck-logs/${name}.log）"
  else
    status=1
    echo "FAIL  ${name}"
    grep -E "error:" "$LOGS/${name}.log" | head -40
  fi
done
exit $status
