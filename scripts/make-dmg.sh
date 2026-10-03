#!/bin/bash
# Build the lite release dmg with the public default identity.
#
#   scripts/make-dmg.sh [output-dir]      (default: dist/)
#
# Produces <output-dir>/Totype-<version>-arm64.dmg and <output-dir>/SHA256SUMS.
# The app inside is the lite build (no speech model; the app downloads it on
# first use), signed ad-hoc: it is not notarized. The version is read from the
# built app's Info.plist. Prints the dmg path as the last line.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${1:-$ROOT/dist}"

# Release builds always use the public defaults, whatever the caller's shell or
# config/local.env says. The signing identity is a name that does not exist, so
# build.sh signs ad-hoc and the result does not depend on one machine's keychain.
export VERBATIM_LOCAL_ENV=/nonexistent
for key in VERBATIM_BUNDLE_ID VERBATIM_APP_NAME VERBATIM_APP_NAME_ZH VERBATIM_DATA_DIR_NAME \
    VERBATIM_LEARN_FROM_EDITS_DEFAULT VERBATIM_SDK_PATH VERBATIM_SENSEVOICE_DIR; do
    unset "$key"
done
export VERBATIM_BUNDLE_MODEL=0
export VERBATIM_SIGN_IDENTITY="Totype Release (ad-hoc)"

WORK="$(mktemp -d /private/tmp/totype-dmg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "== Build (lite) ==" >&2
VERBATIM_APP_OUTPUT_DIR="$WORK/build" scripts/build.sh >/dev/null
BUILT="$WORK/build/Totype.app.disabled"
[[ -d "$BUILT" ]] || { echo "build output missing: $BUILT" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "unexpected version: $VERSION" >&2; exit 1; }
DMG_NAME="Totype-$VERSION-arm64.dmg"

echo "== Stage $DMG_NAME ==" >&2
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$BUILT" "$STAGE/Totype.app"
ln -s /Applications "$STAGE/Applications"
codesign --verify --deep --strict "$STAGE/Totype.app"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$DMG_NAME" "$OUT_DIR/SHA256SUMS"
hdiutil create -quiet -volname "Totype $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT_DIR/$DMG_NAME"
(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)

echo "== SHA256SUMS ==" >&2
cat "$OUT_DIR/SHA256SUMS" >&2
echo "$OUT_DIR/$DMG_NAME"
