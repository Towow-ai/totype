#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="${VERBATIM_SENSEVOICE_DIR:-$PROJECT_DIR/.build/local-sensevoice}"
DOWNLOAD_DIR="$PROJECT_DIR/.build/downloads/sensevoice"
RUNTIME_ARCHIVE="$DOWNLOAD_DIR/funasr-llamacpp-macos-arm64.tar.gz"
MODEL_FILE="$DOWNLOAD_DIR/sensevoice-small-q8.gguf"
VAD_FILE="$DOWNLOAD_DIR/fsmn-vad.gguf"

RUNTIME_URL="https://github.com/QwenAudio/SenseVoice/releases/download/runtime-llamacpp-v0.1.9/funasr-llamacpp-macos-arm64.tar.gz"
MODEL_URL="https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF/resolve/main/sensevoice-small-q8.gguf"
VAD_URL="https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF/resolve/main/fsmn-vad.gguf"

RUNTIME_SHA256="2d5786784ad09d8f4def1d942f678728638fe601d00acf0dad7cf094a9328363"
MODEL_SHA256="4ae45c94422de949b387e2e0fb10d7e14e4c42c69db30c3444ecc7d4b844b7c5"
VAD_SHA256="1270f2559c495f4e7b6e739541151027d360761a3fda43fc147034f5719f5479"
EXECUTABLE_SHA256="49d66b2f79d439e2db7933627e1deb9eb7f3ebf0d708473757828130f3619435"

digest_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

fetch_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"

    if [[ -f "$destination" ]] && [[ "$(digest_of "$destination")" == "$expected" ]]; then
        return
    fi
    if [[ -e "$destination" ]]; then
        mv "$destination" "$destination.invalid.$(date +%Y%m%d-%H%M%S)"
    fi
    curl -L --fail --retry 3 -C - -o "$destination" "$url"
    local actual
    actual="$(digest_of "$destination")"
    if [[ "$actual" != "$expected" ]]; then
        echo "下载校验失败：$destination" >&2
        echo "expected=$expected actual=$actual" >&2
        exit 1
    fi
}

if [[ -x "$TARGET_DIR/llama-funasr-sensevoice" ]] \
    && [[ -f "$TARGET_DIR/sensevoice-small-q8.gguf" ]] \
    && [[ -f "$TARGET_DIR/fsmn-vad.gguf" ]] \
    && [[ "$(digest_of "$TARGET_DIR/llama-funasr-sensevoice")" == "$EXECUTABLE_SHA256" ]] \
    && [[ "$(digest_of "$TARGET_DIR/sensevoice-small-q8.gguf")" == "$MODEL_SHA256" ]] \
    && [[ "$(digest_of "$TARGET_DIR/fsmn-vad.gguf")" == "$VAD_SHA256" ]]; then
    echo "$TARGET_DIR"
    exit 0
fi

mkdir -p "$DOWNLOAD_DIR" "$TARGET_DIR"
fetch_verified "$RUNTIME_URL" "$RUNTIME_ARCHIVE" "$RUNTIME_SHA256"
fetch_verified "$MODEL_URL" "$MODEL_FILE" "$MODEL_SHA256"
fetch_verified "$VAD_URL" "$VAD_FILE" "$VAD_SHA256"

STAGE_DIR="$(mktemp -d /private/tmp/verbatim-sensevoice-runtime.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
tar -xzf "$RUNTIME_ARCHIVE" -C "$STAGE_DIR"

if [[ "$(digest_of "$STAGE_DIR/llama-funasr-sensevoice")" != "$EXECUTABLE_SHA256" ]]; then
    echo "官方运行程序校验失败" >&2
    exit 1
fi

install -m 755 "$STAGE_DIR/llama-funasr-sensevoice" "$TARGET_DIR/llama-funasr-sensevoice"
cp -X "$MODEL_FILE" "$TARGET_DIR/sensevoice-small-q8.gguf"
cp -X "$VAD_FILE" "$TARGET_DIR/fsmn-vad.gguf"
echo "$TARGET_DIR"
