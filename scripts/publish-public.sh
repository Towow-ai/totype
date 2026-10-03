#!/bin/bash
# Sync the publishable snapshot into the local copy of the public repository.
#
#   scripts/publish-public.sh <public-repo-dir> [--commit "<message>"]
#
# Steps: export to a temporary directory (export-public.sh scans it for private
# words and stops on findings) -> rsync --delete into <public-repo-dir>, keeping
# its .git -> show git status -> with --commit, commit with the NatureBlueee
# noreply identity (git -c, global config untouched).
# It never pushes; pushing is a separate, deliberate step.
#
# The private-words file defaults as in export-public.sh (VERBATIM_OSS_PATTERNS,
# then ../private/oss-scan-patterns.txt).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_DIR=""
MESSAGE=""
COMMIT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit)
            [[ $# -ge 2 && -n "$2" ]] || { echo "--commit needs a message" >&2; exit 2; }
            COMMIT=1
            MESSAGE="$2"
            shift 2
            ;;
        -*)
            echo "unknown option: $1" >&2
            exit 2
            ;;
        *)
            [[ -z "$PUBLIC_DIR" ]] || { echo "unexpected argument: $1" >&2; exit 2; }
            PUBLIC_DIR="$1"
            shift
            ;;
    esac
done
if [[ -z "$PUBLIC_DIR" ]]; then
    echo "usage: $0 <public-repo-dir> [--commit \"<message>\"]" >&2
    exit 2
fi
[[ -d "$PUBLIC_DIR/.git" ]] || { echo "not a git working copy: $PUBLIC_DIR" >&2; exit 2; }
PUBLIC_DIR="$(cd "$PUBLIC_DIR" && pwd)"
[[ "$PUBLIC_DIR" != "$ROOT" ]] || { echo "refusing to sync into the source repository" >&2; exit 2; }
# Every commit in the public copy must come from this script: refuse when it
# carries local commits or edits nobody reviewed (they would be pushed as-is).
if git -C "$PUBLIC_DIR" rev-parse -q --verify '@{upstream}' >/dev/null; then
    ahead="$(git -C "$PUBLIC_DIR" rev-list --count '@{upstream}..HEAD')"
    [[ "$ahead" == 0 ]] || { echo "public copy has $ahead unpushed commit(s); review them first" >&2; exit 2; }
fi
[[ -z "$(git -C "$PUBLIC_DIR" status --porcelain)" ]] || { echo "public copy has uncommitted changes; review them first" >&2; exit 2; }

TMP="$(mktemp -d /private/tmp/totype-public-export.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== Export and scan ==" >&2
"$ROOT/scripts/export-public.sh" "$TMP/export" >&2

echo "== Sync into $PUBLIC_DIR ==" >&2
rsync -a --delete --exclude .git "$TMP/export/" "$PUBLIC_DIR/"

echo "== git status ==" >&2
git -C "$PUBLIC_DIR" status --short

if [[ "$COMMIT" == 1 ]]; then
    if [[ -z "$(git -C "$PUBLIC_DIR" status --porcelain)" ]]; then
        echo "nothing to commit" >&2
        exit 0
    fi
    git -C "$PUBLIC_DIR" add -A
    git -C "$PUBLIC_DIR" \
        -c user.name="NatureBlueee" \
        -c user.email="177429696+NatureBlueee@users.noreply.github.com" \
        commit -m "$MESSAGE"
    echo "committed (not pushed): $(git -C "$PUBLIC_DIR" log -1 --format='%h %s')" >&2
fi
