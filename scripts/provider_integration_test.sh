#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
BUILD_DIR="$PROJECT_DIR/.build/provider-integration-test"
# A fresh clone has no runtime yet: fetch and verify it the same way build.sh does.
RUNTIME_DIR="$("$PROJECT_DIR/scripts/setup_local_sensevoice.sh" | tail -n 1)"
FIXTURE="$PROJECT_DIR/scripts/fixtures/literal-repetition.wav"

"$PROJECT_DIR/scripts/fixtures/make-fixture.sh"
mkdir -p "$BUILD_DIR/module-cache"
swiftc \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -parse-as-library \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/TextJoinPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/PersonalLexicon.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/NetworkResilience.swift" \
    "$PROJECT_DIR/VerbatimVoice/Models/TranscriptionModels.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/ASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/LocalSenseVoiceProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/LocalModelStore.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/scripts/provider-integration-test/main.swift" \
    -o "$BUILD_DIR/local-provider-integration-test"

"$BUILD_DIR/local-provider-integration-test" "$RUNTIME_DIR" "$FIXTURE"
