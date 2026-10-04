#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Provides SDK_PATH, VERBATIM_BUNDLE_ID, VERBATIM_APP_NAME, VERBATIM_DATA_DIR_NAME, VERBATIM_SIGN_IDENTITY.
source "$PROJECT_DIR/scripts/lib/env.sh"
BUILD_CACHE_DIR="$PROJECT_DIR/.build/personal"
OUTPUT_DIR="${VERBATIM_APP_OUTPUT_DIR:-$PROJECT_DIR/build}"
OUTPUT_APP="$OUTPUT_DIR/$VERBATIM_APP_NAME.app.disabled"
STAGE_DIR="$(mktemp -d /private/tmp/verbatim-voice-build.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
# Build artifacts deliberately do not end in .app.  Otherwise Launch Services
# registers every temporary build as another copy of the product, which can
# make Accessibility/TCC resolve an obsolete ad-hoc identity.
APP_PATH="$STAGE_DIR/$VERBATIM_APP_NAME.app.disabled"
CONTENTS="$APP_PATH/Contents"
EXECUTABLE="$CONTENTS/MacOS/$VERBATIM_APP_NAME"
SENSEVOICE_DIR="${VERBATIM_SENSEVOICE_DIR:-}"
PROJECT_FILE="$PROJECT_DIR/VerbatimVoice.xcodeproj/project.pbxproj"

# Keep the direct Swift build's bundle metadata aligned with the Xcode project
# instead of maintaining a second hard-coded version here.
APP_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' "$PROJECT_FILE" | sort -u)"
APP_BUILD="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$PROJECT_FILE" | sort -u)"
if [[ -z "$APP_VERSION" || "$APP_VERSION" == *$'\n'* || -z "$APP_BUILD" || "$APP_BUILD" == *$'\n'* ]]; then
    echo "无法从 Xcode 工程确定唯一的应用版本。" >&2
    exit 1
fi

echo "使用 SDK：$SDK_PATH" >&2

rm -rf "$OUTPUT_APP"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
mkdir -p "$BUILD_CACHE_DIR/module-cache"

# VERBATIM_BUNDLE_MODEL=0 builds the "lite" app without the SenseVoice runtime and
# models; the app downloads them on first use (LocalModelStore).
if [[ "$VERBATIM_BUNDLE_MODEL" != "0" ]]; then
    if [[ -z "$SENSEVOICE_DIR" ]]; then
        SENSEVOICE_DIR="$("$PROJECT_DIR/scripts/setup_local_sensevoice.sh" | tail -n 1)"
    fi
    for required in llama-funasr-sensevoice sensevoice-small-q8.gguf fsmn-vad.gguf; do
        if [[ ! -f "$SENSEVOICE_DIR/$required" ]]; then
            echo "本地 SenseVoice 资源缺失：$SENSEVOICE_DIR/$required" >&2
            exit 1
        fi
    done
fi

APP_SOURCES=()
while IFS= read -r -d '' file; do APP_SOURCES+=("$file"); done < <(find "$PROJECT_DIR/VerbatimVoice" -name '*.swift' -print0 | sort -z)
CORE_SOURCES=()
while IFS= read -r -d '' file; do CORE_SOURCES+=("$file"); done < <(find "$PROJECT_DIR/VerbatimVoiceCore/Sources/VerbatimCore" -name '*.swift' -print0 | sort -z)

swiftc \
    -module-cache-path "$BUILD_CACHE_DIR/module-cache" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -parse-as-library \
    -O \
    -module-name VerbatimVoice \
    "${CORE_SOURCES[@]}" \
    "${APP_SOURCES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Carbon \
    -framework CoreGraphics \
    -framework Security \
    -framework ServiceManagement \
    -framework Speech \
    -framework SwiftUI \
    -o "$EXECUTABLE"

cp "$PROJECT_DIR/VerbatimVoice/Resources/Info.plist" "$CONTENTS/Info.plist"
# Permission prompts quote the app name through the template's $(VERBATIM_APP_NAME).
escaped_name="$(printf '%s' "$VERBATIM_APP_NAME" | sed -e 's/[\/&]/\\&/g')"
sed -i '' "s/\$(VERBATIM_APP_NAME)/$escaped_name/g" "$CONTENTS/Info.plist"
# App icon (design-v2; regenerate with scripts/make_app_icon.swift). Copied before
# signing so the sealed resources include it.
cp -X "$PROJECT_DIR/VerbatimVoice/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
install -m 644 "$PROJECT_DIR/VerbatimVoice/Resources/starter-glossary-developer.json" "$CONTENTS/Resources/starter-glossary-developer.json"
cp -X "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"
if [[ "$VERBATIM_BUNDLE_MODEL" != "0" ]]; then
    mkdir -p "$CONTENTS/Resources/SenseVoice"
    install -m 755 "$SENSEVOICE_DIR/llama-funasr-sensevoice" "$CONTENTS/Resources/SenseVoice/llama-funasr-sensevoice"
    cp -X "$SENSEVOICE_DIR/sensevoice-small-q8.gguf" "$CONTENTS/Resources/SenseVoice/sensevoice-small-q8.gguf"
    cp -X "$SENSEVOICE_DIR/fsmn-vad.gguf" "$CONTENTS/Resources/SenseVoice/fsmn-vad.gguf"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $VERBATIM_APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VERBATIM_BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :VVLearnFromEditsDefault $VERBATIM_LEARN_FROM_EDITS_DEFAULT" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :VVDataDirectoryName $VERBATIM_DATA_DIR_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $VERBATIM_APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $VERBATIM_APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$CONTENTS/Info.plist"
# UI strings and permission prompts: English and Simplified Chinese. Info.plist
# declares both (CFBundleLocalizations), so macOS shows Chinese on a Chinese system
# and English everywhere else. The .strings tables are plain resources: swiftc does
# not compile .xcstrings, so they are copied here (the Xcode project adds the same files).
for lang in en zh-Hans; do
    mkdir -p "$CONTENTS/Resources/$lang.lproj"
    cp -X "$PROJECT_DIR/VerbatimVoice/Resources/$lang.lproj/Localizable.strings" "$CONTENTS/Resources/$lang.lproj/Localizable.strings"
    sed "s/\$(VERBATIM_APP_NAME)/$escaped_name/g" "$PROJECT_DIR/VerbatimVoice/Resources/$lang.lproj/InfoPlist.strings" \
        > "$CONTENTS/Resources/$lang.lproj/InfoPlist.strings"
done
if [[ -n "$VERBATIM_APP_NAME_ZH" ]]; then
    # Localized display name.
    for lang in en:"$VERBATIM_APP_NAME" zh-Hans:"$VERBATIM_APP_NAME_ZH"; do
        printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "${lang#*:}" "${lang#*:}" \
            >> "$CONTENTS/Resources/${lang%%:*}.lproj/InfoPlist.strings"
    done
fi
plutil -lint "$CONTENTS/Resources/en.lproj/InfoPlist.strings" "$CONTENTS/Resources/zh-Hans.lproj/InfoPlist.strings" \
    "$CONTENTS/Resources/en.lproj/Localizable.strings" "$CONTENTS/Resources/zh-Hans.lproj/Localizable.strings" >&2
xattr -cr "$APP_PATH"

SIGN_IDENTITY="$VERBATIM_SIGN_IDENTITY"
if [[ -z "$SIGN_IDENTITY" ]] || ! security find-identity -v -p codesigning | grep -Fq "\"$SIGN_IDENTITY\""; then
    echo "警告：找不到本机签名身份「${SIGN_IDENTITY:-（未设置）}」，改用 ad-hoc 签名。" >&2
    echo "警告：ad-hoc 签名在每次重建后都会变化，系统可能撤销麦克风、辅助功能和输入监控授权，需到" >&2
    echo "      系统设置 → 隐私与安全性 中删除旧条目后重新授权。运行 scripts/install_local_signing_identity.sh" >&2
    echo "      可创建稳定的本机自签名身份。" >&2
    SIGN_IDENTITY="-"
fi
if [[ "$VERBATIM_BUNDLE_MODEL" != "0" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        "$CONTENTS/Resources/SenseVoice/llama-funasr-sensevoice"
fi
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$PROJECT_DIR/VerbatimVoice/Resources/VerbatimVoice.entitlements" \
    "$APP_PATH"

plutil -lint "$CONTENTS/Info.plist"
codesign --verify --strict "$APP_PATH"
cp -R -X "$APP_PATH" "$OUTPUT_APP"
codesign --verify --strict "$OUTPUT_APP"
echo "$OUTPUT_APP"
