#!/bin/bash
# CI helper: pick an Xcode on a GitHub-hosted macOS runner.
#
# The code needs the macOS 15.4 SDK or later (Swift 6). Runner images carry
# several Xcode versions side by side. Pin the version already used by the
# verified pipeline; upgrade this one setting and validate a branch before release.
set -euo pipefail

CHOSEN="/Applications/Xcode_26.3.app"
[[ -d "$CHOSEN" ]] || { echo "CI requires $CHOSEN; update scripts/ci-select-xcode.sh for the runner image." >&2; exit 1; }
sudo xcode-select -s "$CHOSEN/Contents/Developer"
xcode-select -p
xcrun swift --version
echo "SDK: $(xcrun --sdk macosx --show-sdk-version) ($(xcrun --sdk macosx --show-sdk-path))"
