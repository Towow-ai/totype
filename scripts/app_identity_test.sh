#!/bin/bash
# Usage: app_identity_test.sh <built .app> [expected bundleID dataDir displayName [learnFromEditsDefault]]
# Runs AppIdentity inside a copy of the app bundle (its Info.plist, our binary
# as the executable) and prints or checks the three values.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
APP="${1:?path to a built app bundle}"
WORK="$(mktemp -d /private/tmp/verbatim-identity.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
mkdir -p "$WORK/t.app/Contents/MacOS" "$WORK/t.app/Contents/Resources"
cp "$APP/Contents/Info.plist" "$WORK/t.app/Contents/Info.plist"
[[ -d "$APP/Contents/Resources" ]] && for lproj in "$APP"/Contents/Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$WORK/t.app/Contents/Resources/"
done
swiftc -module-cache-path "$PROJECT_DIR/.build/module-cache" -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    "$PROJECT_DIR/VerbatimVoice/App/AppIdentity.swift" \
    "$PROJECT_DIR/scripts/app-identity-test/main.swift" \
    -o "$WORK/t.app/Contents/MacOS/$EXE_NAME" 2>&1 | grep -v "^$" || true
OUT="$("$WORK/t.app/Contents/MacOS/$EXE_NAME")"
echo "$OUT"

if [[ $# -ge 5 ]]; then
    [[ "$(echo "$OUT" | grep '^learnFromEditsDefault=')" == "learnFromEditsDefault=$5" ]] \
        || { echo "learnFromEditsDefault 与期望不符（期望 $5）" >&2; exit 1; }
fi
if [[ $# -ge 4 ]]; then
    expected="bundleID=$2
dataDirectoryName=$3
displayName=$4"
    if [[ "$(echo "$OUT" | head -3)" != "$expected" ]]; then
        echo "AppIdentity 与期望不符：" >&2
        echo "$expected" >&2
        exit 1
    fi
    echo "ok  AppIdentity matches"
fi
