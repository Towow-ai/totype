#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
BUILD_DIR="$PROJECT_DIR/.build/aliyun-protocol-test"

mkdir -p "$BUILD_DIR/module-cache"
swiftc \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -parse-as-library \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/ContextBudgeter.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/TextJoinPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/PersonalLexicon.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift" \
    "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore/NetworkResilience.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppSettings.swift" \
    "$PROJECT_DIR/VerbatimVoice/Models/TranscriptionModels.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/ASRProvider.swift" \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/VerbatimVoice/Providers/AliyunASRProvider.swift" \
    "$PROJECT_DIR/scripts/aliyun-protocol-test/main.swift" \
    -o "$BUILD_DIR/aliyun-protocol-test"

"$BUILD_DIR/aliyun-protocol-test"
