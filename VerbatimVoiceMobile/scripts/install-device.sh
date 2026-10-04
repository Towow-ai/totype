#!/bin/bash
# Build, sign with the team in Config/Local.xcconfig and install on the first
# connected iPhone. Free (Personal Team) profiles expire after 7 days: rerun.
set -euo pipefail
cd "$(dirname "$0")/.."
# The public defaults (ai.towow.totype) are not signable by anyone else, and an
# install under a different bundle ID is a different app on the phone.
if ! grep -Eq '^[[:space:]]*TOTYPE_BUNDLE_ID[[:space:]]*=' Config/Local.xcconfig 2>/dev/null \
   || ! grep -Eq '^[[:space:]]*TOTYPE_APP_GROUP[[:space:]]*=' Config/Local.xcconfig; then
    echo "Config/Local.xcconfig 里没有 TOTYPE_BUNDLE_ID 和 TOTYPE_APP_GROUP：先复制 Config/Local.xcconfig.example，填写 Team ID 和你自己的 Bundle ID（见 docs/manual/zh-CN/11-iphone.md）" >&2
    exit 1
fi
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/(connected|available)/ && /iPhone/ && /physical/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}"
[[ -n "$DEVICE" ]] || { echo "没有找到已连接的 iPhone（数据线连接并解锁）" >&2; exit 1; }
scripts/prepare-seed.sh
xcodegen -q
xcodebuild -project VerbatimVoiceMobile.xcodeproj -scheme VerbatimVoiceMobile \
  -destination "id=$DEVICE" -configuration Debug -derivedDataPath build/DD \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
xcrun devicectl device install app --device "$DEVICE" \
  build/DD/Build/Products/Debug-iphoneos/VerbatimVoiceMobile.app >/dev/null
echo "已安装到 $DEVICE"
