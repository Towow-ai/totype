#!/bin/bash
# Renders the design-preview snapshots with a DEBUG build of the app. The binary only
# renders fake sample data into PNGs and exits (VerbatimVoice/UI/Design/DesignPreview.swift):
# no hotkey, event tap, microphone, history or permission path is touched.
#
#   scripts/design_preview.sh docs [out-dir]        Chinese README/manual screenshots
#   scripts/design_preview.sh docs-en [out-dir]     English set (default docs/images/en)
#   scripts/design_preview.sh <targets> [out-dir]   any VERBATIM_DESIGN_PREVIEW target list
#                                                   (PREVIEW_LANG=en for the English interface)
#
# The bundle is staged in a temporary directory with both string tables, so the
# interface language follows -AppleLanguages like the real app does.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"

TARGETS="${1:-docs}"
APPLE_LANG="zh-Hans"
APPLE_LOCALE="zh_CN"
SAMPLE_LANG="zh"
OUT="${2:-/private/tmp/verbatim-design-preview}"
if [[ "$TARGETS" == "docs-en" || "${PREVIEW_LANG:-}" == "en" ]]; then
    [[ "$TARGETS" == "docs-en" ]] && TARGETS="docs"
    APPLE_LANG="en"
    APPLE_LOCALE="en_US"
    SAMPLE_LANG="en"
    OUT="${2:-$PROJECT_DIR/docs/images/en}"
fi

STAGE="$(mktemp -d /private/tmp/verbatim-design-preview-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Preview.app.disabled/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources" "$PROJECT_DIR/.build/preview/module-cache"

APP_SOURCES=()
while IFS= read -r -d '' file; do APP_SOURCES+=("$file"); done < <(find "$PROJECT_DIR/VerbatimVoice" -name '*.swift' -print0 | sort -z)
CORE_SOURCES=()
while IFS= read -r -d '' file; do CORE_SOURCES+=("$file"); done < <(find "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore" -name '*.swift' -print0 | sort -z)

swiftc \
    -module-cache-path "$PROJECT_DIR/.build/preview/module-cache" \
    -sdk "$SDK_PATH" -target arm64-apple-macosx15.0 \
    -parse-as-library -Onone -D DEBUG -module-name VerbatimVoice \
    "${CORE_SOURCES[@]}" "${APP_SOURCES[@]}" \
    -framework AppKit -framework ApplicationServices -framework AudioToolbox -framework AVFoundation \
    -framework Carbon -framework CoreGraphics -framework Security -framework ServiceManagement \
    -framework Speech -framework SwiftUI \
    -o "$APP/MacOS/Preview"

cp "$PROJECT_DIR/VerbatimVoice/Resources/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Preview" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.towow.design-preview" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $VERBATIM_APP_NAME" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $VERBATIM_APP_NAME" "$APP/Info.plist"
for lang in en zh-Hans; do
    mkdir -p "$APP/Resources/$lang.lproj"
    cp "$PROJECT_DIR/VerbatimVoice/Resources/$lang.lproj/Localizable.strings" "$APP/Resources/$lang.lproj/"
done

mkdir -p "$OUT"
VERBATIM_DESIGN_PREVIEW="$TARGETS" \
VERBATIM_DESIGN_PREVIEW_OUT="$OUT" \
VERBATIM_DESIGN_PREVIEW_LANG="$SAMPLE_LANG" \
    "$APP/MacOS/Preview" -AppleLanguages "($APPLE_LANG)" -AppleLocale "$APPLE_LOCALE"
