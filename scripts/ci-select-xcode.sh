#!/bin/bash
# CI helper: pick an Xcode on a GitHub-hosted macOS runner.
#
# The code needs the macOS 15.4 SDK or later (Swift 6). Runner images carry
# several Xcode versions side by side, and the default one can be older than
# that. This chooses the newest Xcode_26* if present, otherwise keeps the
# default, then prints the Swift version and SDK so the log shows what was used.
set -euo pipefail

CHOSEN="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n 1 || true)"
if [[ -n "$CHOSEN" ]]; then
    sudo xcode-select -s "$CHOSEN/Contents/Developer"
fi
xcode-select -p
xcrun swift --version
echo "SDK: $(xcrun --sdk macosx --show-sdk-version) ($(xcrun --sdk macosx --show-sdk-path))"
