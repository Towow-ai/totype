#!/bin/bash
# Copy the publishable part of the repository into a fresh directory (no .git)
# and scan the result.
#
#   scripts/export-public.sh <dest> [patterns-file]
#
# <dest> must not exist or must be empty. The patterns file (private words, kept
# outside the repository) defaults to $VERBATIM_OSS_PATTERNS, then to
# ../private/oss-scan-patterns.txt next to the checkout.
#
# Publication is a whitelist: anything not listed below is not exported.
# Deliberately left out: handoff/, planning documents in docs/, Probes/,
# Diagnostics/ (developer probes), VerbatimVoiceMobile/ (iOS is not published
# yet), local config (config/local.env, config/Local.xcconfig), build output, personal wrapper scripts.
# The audio fixture is generated locally by scripts/fixtures/make-fixture.sh
# (macOS `say`) and is never exported. docs/design/ holds only screenshots that were
# checked for private sample text.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DEST=""
PATTERNS="${VERBATIM_OSS_PATTERNS:-}"
for arg in "$@"; do
    if [[ -z "$DEST" ]]; then DEST="$arg"; else PATTERNS="$arg"; fi
done
if [[ -z "$DEST" ]]; then
    echo "usage: $0 <dest> [patterns-file]" >&2
    exit 2
fi
if [[ -z "$PATTERNS" ]]; then
    PATTERNS="$PROJECT_DIR/../private/oss-scan-patterns.txt"
fi
[[ -f "$PATTERNS" ]] || { echo "patterns file not found: $PATTERNS" >&2; exit 2; }

if [[ -e "$DEST" ]] && [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
    echo "destination exists and is not empty: $DEST" >&2
    exit 2
fi
mkdir -p "$DEST"

WHITELIST=(
    LICENSE
    NOTICE
    THIRD_PARTY_NOTICES.md
    README.md
    README.zh-CN.md
    .gitignore
    VerbatimVoice
    VerbatimVoiceCore
    VerbatimVoice.xcodeproj
    config/local.env.example
    config/Shared.xcconfig
    config/Local.xcconfig.example
    docs/ADR-0001-S0-Stability-First.md
    docs/DESIGN.md
    docs/design
    docs/manual
    scripts
    tools/history_report.py
)

EXCLUDES=(
    --exclude='.DS_Store'
    --exclude='.build/'
    --exclude='build/'
    --exclude='xcuserdata/'
    --exclude='*.dmg'
    --exclude='*.app'
    --exclude='*.app.disabled'
    --exclude='scripts/build_personal.sh'
    --exclude='scripts/install_personal.sh'
    --exclude='*.wav'
    --exclude='config/Local.xcconfig'
)

cd "$PROJECT_DIR"
for item in "${WHITELIST[@]}"; do
    if [[ ! -e "$item" ]]; then
        echo "whitelisted path missing: $item" >&2
        exit 1
    fi
    rsync -a --relative "${EXCLUDES[@]}" "./$item" "$DEST/"
done

echo "exported to $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files)" >&2
"$PROJECT_DIR/scripts/oss-scan.sh" "$PATTERNS" "$DEST"

cat >&2 <<'HINT'

To publish the snapshot as a fresh repository (local identity only, no global git config change):
  cd <dest> && git init -b main
  git add -A
  git -c user.name="NatureBlueee" -c user.email="177429696+NatureBlueee@users.noreply.github.com" \
      commit -m "Initial public release"
HINT
