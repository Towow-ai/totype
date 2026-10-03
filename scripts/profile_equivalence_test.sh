#!/usr/bin/env bash
# Offline: builds the Soniox/Aliyun start requests from an exported profile and
# compares them with a capture taken before personal content left the code.
# Reads private fixtures from VERBATIM_PRIVATE_DIR (see the test source); skips
# the parts whose files are missing. Never touches the network or API keys.
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
  VerbatimVoiceCore/Sources/VerbatimCore/*.swift \
  VerbatimVoice/Models/ProviderContextCompiler.swift \
  VerbatimVoice/Models/TranscriptionModels.swift \
  VerbatimVoice/Providers/ASRProvider.swift \
  VerbatimVoice/Providers/ProviderProbe.swift \
  VerbatimVoice/App/AppIdentity.swift \
  VerbatimVoice/Providers/SonioxProvider.swift \
  VerbatimVoice/Providers/AliyunASRProvider.swift \
  VerbatimVoice/App/AppSettings.swift \
  VerbatimVoice/App/AppSettingsProfile.swift \
  VerbatimVoice/Storage/PersonalLexiconStore.swift \
  scripts/profile-equivalence-test/main.swift \
  -o .build/self-test/profile-equivalence-test
.build/self-test/profile-equivalence-test
