#!/usr/bin/env bash
# Compiles Shared/*.swift with the self-test and runs it on macOS.
set -euo pipefail

MOBILE="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${VERBATIM_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
OUT="$MOBILE/.build/self-test"
mkdir -p "$OUT"

swiftc \
  -module-cache-path "$MOBILE/.build/module-cache" \
  -sdk "$SDK" \
  -target arm64-apple-macosx15.0 \
  -parse-as-library \
  "$MOBILE"/Shared/*.swift \
  "$MOBILE/scripts/shared-self-test.swift" \
  -o "$OUT/shared-self-test"

"$OUT/shared-self-test"
