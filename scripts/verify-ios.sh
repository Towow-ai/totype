#!/usr/bin/env bash
# Public iOS compilation and shared behavior. Does not sign, install, seed
# personal data, or claim that microphone/keyboard behavior passed on a device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE="$ROOT/VerbatimVoiceMobile"
cd "$MOBILE"

command -v xcodegen >/dev/null || { echo "Install XcodeGen (CI uses 2.46.0); see docs/CI-CD.md." >&2; exit 1; }
xcodebuild -version
xcodegen --version
xcrun --sdk iphoneos --show-sdk-version

printf '\n== iOS shared behavior ==\n'
scripts/shared-self-test.sh

printf '\n== iOS app, keyboard and widgets (unsigned Release) ==\n'
xcodegen -q
mkdir -p .build
LOG="$MOBILE/.build/ci-ios-build.log"
if ! xcodebuild -project VerbatimVoiceMobile.xcodeproj -scheme VerbatimVoiceMobile \
    -destination 'generic/platform=iOS' -configuration Release \
    -derivedDataPath .build/ci-ios -quiet build \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= \
    TOTYPE_BUNDLE_ID=ai.towow.totype TOTYPE_APP_GROUP=group.ai.towow.totype \
    TOTYPE_URL_SCHEME=totype TOTYPE_DISPLAY_NAME=Totype \
    TOTYPE_PRIVATE_HOST_RETURN=NO >"$LOG" 2>&1; then
    tail -n 100 "$LOG"
    echo "Native iOS build failed. Full log: $LOG" >&2
    exit 1
fi

APP="$MOBILE/.build/ci-ios/Build/Products/Release-iphoneos/VerbatimVoiceMobile.app"
for bundle in "$APP" "$APP/PlugIns/VerbatimKeyboard.appex" "$APP/PlugIns/VerbatimWidgets.appex"; do
    plutil -lint "$bundle/Info.plist"
done
printf 'All iOS shared tests and native targets passed. Unsigned build: %s\n' "$APP"
printf 'Device signing, installation and real input acceptance: VerbatimVoiceMobile/scripts/install-device.sh\n'
