#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/lib/env.sh"
mkdir -p .build/self-test

swiftc \
  -module-cache-path .build/module-cache \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  VerbatimVoiceCore/Sources/VerbatimCore/ContextBudgeter.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/TextJoinPolicy.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/PersonalLexicon.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/PCMFrameBatcher.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/CompletionDeadline.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/RealtimeCompletionPolicy.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/ProviderAvailability.swift \
  VerbatimVoiceCore/Sources/VerbatimCore/NetworkResilience.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/Providers/ASRProvider.swift \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/Providers/SonioxProvider.swift \
  scripts/soniox-context-test/main.swift \
  -o .build/self-test/soniox-context-test

.build/self-test/soniox-context-test
