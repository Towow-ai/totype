#!/bin/bash
# Generates scripts/fixtures/literal-repetition.wav on this machine with macOS
# `say` (a Chinese voice) and converts it to 16 kHz mono 16-bit WAV.
# The file is git-ignored: the output of the system voice is not redistributed.
#
#   make-fixture.sh [--force]
#
# Override the voice with VERBATIM_FIXTURE_VOICE (default Tingting, then any
# installed zh_CN voice).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/literal-repetition.wav"
SENTENCE="我我觉得这个方案呃，不对不对，先不要改我的原话。"

if [[ -f "$OUT" && "${1:-}" != "--force" ]]; then
    exit 0
fi

VOICE="${VERBATIM_FIXTURE_VOICE:-}"
if [[ -z "$VOICE" ]]; then
    if say -v '?' | grep -q '^Tingting '; then
        VOICE="Tingting"
    else
        VOICE="$(say -v '?' | awk '/zh_CN/ {print $1; exit}')"
    fi
fi
[[ -n "$VOICE" ]] || { echo "没有可用的中文 say 语音；请在 系统设置 → 辅助功能 → 朗读内容 里安装，或设置 VERBATIM_FIXTURE_VOICE。" >&2; exit 1; }

TMP="$(mktemp -d /private/tmp/verbatim-fixture.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
say -v "$VOICE" -o "$TMP/speech.aiff" "$SENTENCE"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/speech.aiff" "$OUT"
echo "generated $OUT (voice: $VOICE)" >&2
