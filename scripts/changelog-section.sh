#!/bin/bash
# Print the CHANGELOG.md section for one version (heading line excluded).
#
#   scripts/changelog-section.sh 0.4.0
#
# Sections start with "## [<version>]". Exits 1 if the version is missing or
# its section is empty.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version>" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECTION="$(awk -v ver="$1" '
    /^## \[/ { if (on) exit; on = (index($0, "## [" ver "]") == 1); next }
    on { print }
' "$ROOT/CHANGELOG.md")"
if [[ -z "${SECTION//[[:space:]]/}" ]]; then
    echo "CHANGELOG.md has no section for version $1" >&2
    exit 1
fi
printf '%s\n' "$SECTION"
