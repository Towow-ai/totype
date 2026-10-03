#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
BUILD_DIR="$PROJECT_DIR/.build/cloud-live-probe"

if [[ $# -lt 1 || $# -gt 2 || ( "$1" != "soniox" && "$1" != "aliyun" ) ]]; then
    echo "usage: $0 <soniox|aliyun> [audio.wav|audio.flac]" >&2
    exit 2
fi

"$PROJECT_DIR/scripts/fixtures/make-fixture.sh"
mkdir -p "$BUILD_DIR/module-cache"
swiftc \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -parse-as-library \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/TextJoinPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/ContextBudgeter.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/PersonalLexicon.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/PCMFrameBatcher.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/CompletionDeadline.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/NetworkResilience.swift" \
    "$PROJECT_DIR/VerbatimVoice/Audio/PCMConverter.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppSettings.swift" \
    "$PROJECT_DIR/VerbatimVoice/Models/TranscriptionModels.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/ASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/AliyunASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/SonioxProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Utilities/KeychainStore.swift" \
    "$PROJECT_DIR/scripts/cloud-live-probe/main.swift" \
    -framework Security \
    -framework AVFoundation \
    -o "$BUILD_DIR/cloud-live-probe"

# The API keys were created by the stable-signed app. Give the diagnostic
# binary the same local designated identity so Keychain does not stall on a
# new one-off command-line identity during an automated probe.
SIGN_IDENTITY="$VERBATIM_SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --identifier "$VERBATIM_BUNDLE_ID" \
    "$BUILD_DIR/cloud-live-probe" >/dev/null

if [[ $# -eq 2 ]]; then
    "$BUILD_DIR/cloud-live-probe" "$1" "$2"
elif [[ "$1" == "aliyun" ]]; then
    "$BUILD_DIR/cloud-live-probe" "$1" "$PROJECT_DIR/scripts/fixtures/literal-repetition.wav"
else
    "$BUILD_DIR/cloud-live-probe" "$1"
fi
