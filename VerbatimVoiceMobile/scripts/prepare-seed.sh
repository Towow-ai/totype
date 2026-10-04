#!/bin/bash
# Puts an optional personal lexicon and speaker profile into the iOS bundle
# seed (Seed/, git-ignored). By default nothing is copied and any seed left
# from an earlier run is removed, so a build never ships someone's words by
# accident. The phone imports the lexicon once on first launch with an empty
# lexicon, and the profile once per install. API keys are never copied.
#
#   VERBATIM_LEXICON_SEED=<file.jsonl>   lexicon events, e.g. the Mac app's
#       ~/Library/Application Support/<data folder>/personal-lexicon-v1.jsonl
#   VERBATIM_PROFILE_SEED=<file.json>    an exported profile
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

copy_seed() {
    local label="$1" source="$2" target="$HERE/Seed/$3"
    if [[ -z "$source" ]]; then
        rm -f "$target"
        echo "$label seed: not set, skipped"
    elif [[ -f "$source" ]]; then
        cp "$source" "$target"
        echo "$label seed: copied $(basename "$source")"
    else
        echo "$label seed: $source not found" >&2
        exit 1
    fi
}

copy_seed lexicon "${VERBATIM_LEXICON_SEED:-}" personal-lexicon-seed.jsonl
copy_seed profile "${VERBATIM_PROFILE_SEED:-}" personal-profile-seed.json
