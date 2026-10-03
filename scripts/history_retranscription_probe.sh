#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
BUILD_DIR="$PROJECT_DIR/.build/history-retranscription-probe"

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <audio.flac> <session-uuid>" >&2
    exit 2
fi

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
    "$PROJECT_DIR/VerbatimVoice/Audio/SessionAudioArchive.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppSettings.swift" \
    "$PROJECT_DIR/VerbatimVoice/Models/TranscriptionModels.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/ASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/SonioxProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Storage/HistoryStore.swift" \
    "$PROJECT_DIR/VerbatimVoice/Storage/PersonalLexiconStore.swift" \
    "$PROJECT_DIR/VerbatimVoice/Utilities/KeychainStore.swift" \
    "$PROJECT_DIR/scripts/history-retranscription-probe/main.swift" \
    -framework Security \
    -framework AVFoundation \
    -o "$BUILD_DIR/history-retranscription-probe"

SIGN_IDENTITY="$VERBATIM_SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --identifier "$VERBATIM_BUNDLE_ID" \
    "$BUILD_DIR/history-retranscription-probe" >/dev/null

"$BUILD_DIR/history-retranscription-probe" "$1" "$2"
