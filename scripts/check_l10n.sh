#!/usr/bin/env bash
# Localization check for the macOS app: the two string tables must agree and every
# localized call in the code must have an entry. Chinese literals that bypass
# localization are listed as warnings only. See scripts/l10n.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib/env.sh"

KEYS_DIR="$ROOT/.build/l10n-keys"
rm -rf "$KEYS_DIR"
mkdir -p "$KEYS_DIR" "$ROOT/.build/module-cache"

# Compiling is the only way to see the keys of interpolated strings exactly as
# Foundation builds them (`%lld`, `%@`); the compiler records them per source file.
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find VerbatimVoiceCore/Sources/VerbatimCore VerbatimVoice -name '*.swift' -print0 | sort -z)
# -D DEBUG so the design-preview views (which share the real views' strings) count too.
( cd "$KEYS_DIR" && swiftc -c -Onone -parse-as-library -module-name VerbatimVoice \
    -module-cache-path "$ROOT/.build/module-cache" \
    -sdk "$SDK_PATH" -target arm64-apple-macosx15.0 -D DEBUG \
    -emit-localized-strings -emit-localized-strings-path "$KEYS_DIR" \
    "${SOURCES[@]/#/$ROOT/}" )
rm -f "$KEYS_DIR"/*.o

status=0
python3 scripts/l10n.py check --keys-dir "$KEYS_DIR" || status=$?
python3 scripts/l10n.py warn-hardcoded --keys-dir "$KEYS_DIR"
exit "$status"
