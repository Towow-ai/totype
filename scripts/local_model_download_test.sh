#!/bin/bash
# Downloads the local model through LocalModelStore (real network, public hosts,
# about 251 MB) into a temporary folder and transcribes the fixture with it.
#
#   local_model_download_test.sh <lite .app> [--cancel-first]
#
# The harness replaces the executable of a copy of the bundle, so Bundle.main and
# the background URLSession identifier come from the app's own Info.plist, and the
# copy is ad-hoc signed with hardened runtime like a released app. The GUI app is
# never started and the real data folder is not touched.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
APP="${1:?path to a lite app bundle (VERBATIM_BUNDLE_MODEL=0 scripts/build.sh)}"
shift || true
[[ ! -d "$APP/Contents/Resources/SenseVoice" ]] || { echo "这是 full 版（已内置模型），请传入 lite 构建" >&2; exit 1; }

WORK="$(mktemp -d /private/tmp/verbatim-model-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
mkdir -p "$WORK/t.app/Contents/MacOS" "$WORK/t.app/Contents/Resources"
cp "$APP/Contents/Info.plist" "$WORK/t.app/Contents/Info.plist"

CORE="$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore"
swiftc \
    -module-cache-path "$PROJECT_DIR/.build/module-cache" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -parse-as-library \
    "$CORE/TextJoinPolicy.swift" \
    "$CORE/PersonalLexicon.swift" \
    "$CORE/RealtimeCompletionPolicy.swift" \
    "$CORE/ProviderAvailability.swift" \
    "$CORE/NetworkResilience.swift" \
    "$PROJECT_DIR/VerbatimVoice/Models/TranscriptionModels.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/ASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/LocalSenseVoiceProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/LocalModelStore.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/scripts/local-model-download-test/main.swift" \
    -o "$WORK/t.app/Contents/MacOS/$EXE_NAME"
codesign --force --sign - --options runtime "$WORK/t.app"

"$PROJECT_DIR/scripts/fixtures/make-fixture.sh"
"$WORK/t.app/Contents/MacOS/$EXE_NAME" \
    "$PROJECT_DIR/scripts/fixtures/literal-repetition.wav" "不要改我的原话" "$@"
