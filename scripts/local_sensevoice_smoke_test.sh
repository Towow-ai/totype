#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/lib/env.sh"
APP_PATH="${1:-$PROJECT_DIR/build/$VERBATIM_APP_NAME.app.disabled}"
RUNTIME="$APP_PATH/Contents/Resources/SenseVoice"

for required in llama-funasr-sensevoice sensevoice-small-q8.gguf fsmn-vad.gguf; do
    if [[ ! -f "$RUNTIME/$required" ]]; then
        echo "缺少已打包的本地转写资源：$RUNTIME/$required" >&2
        exit 1
    fi
done

# The fixture is synthesized locally with macOS `say` (not stored in git).
"$PROJECT_DIR/scripts/fixtures/make-fixture.sh"
WAV="$PROJECT_DIR/scripts/fixtures/literal-repetition.wav"

TEXT="$("$RUNTIME/llama-funasr-sensevoice" \
    -m "$RUNTIME/sensevoice-small-q8.gguf" \
    --vad "$RUNTIME/fsmn-vad.gguf" \
    -a "$WAV")"

for literal in "我我" "不对不对" "不要改我的原话"; do
    if [[ "$TEXT" != *"$literal"* ]]; then
        echo "本地 SenseVoice 冒烟测试未保留关键原话：$literal" >&2
        echo "实际结果：$TEXT" >&2
        exit 1
    fi
done

echo "ok  local SenseVoice preserved repetitions and literal wording"
echo "    $TEXT"
