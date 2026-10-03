# Shared build settings. Source this file; do not execute it.
#
# Order of precedence for every setting: environment variable, then
# config/local.env (git-ignored), then the built-in default below.

_VV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_VV_KEYS=(VERBATIM_SDK_PATH VERBATIM_BUNDLE_ID VERBATIM_SIGN_IDENTITY VERBATIM_APP_NAME VERBATIM_APP_NAME_ZH VERBATIM_DATA_DIR_NAME VERBATIM_BUNDLE_MODEL VERBATIM_LEARN_FROM_EDITS_DEFAULT)

# Remember what the caller exported so local.env cannot override it.
for _vv_key in "${_VV_KEYS[@]}"; do
    if [[ -n "${!_vv_key+x}" ]]; then
        eval "_VV_PRESET_$_vv_key=\"\${$_vv_key}\""
    fi
done

VERBATIM_LOCAL_ENV="${VERBATIM_LOCAL_ENV:-$_VV_ROOT/config/local.env}"
if [[ -f "$VERBATIM_LOCAL_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$VERBATIM_LOCAL_ENV"
fi

for _vv_key in "${_VV_KEYS[@]}"; do
    _vv_preset="_VV_PRESET_$_vv_key"
    if [[ -n "${!_vv_preset+x}" ]]; then
        eval "$_vv_key=\"\${$_vv_preset}\""
    fi
done
unset _vv_key _vv_preset

# Identity defaults for a public checkout: the one place that holds the project
# name. Repository: Towow-ai/totype.
VERBATIM_BUNDLE_ID="${VERBATIM_BUNDLE_ID:-ai.towow.totype}"
# English display name, executable name and install path component.
VERBATIM_APP_NAME="${VERBATIM_APP_NAME:-Totype}"
# Chinese display name; set to empty (VERBATIM_APP_NAME_ZH="") to skip localization.
VERBATIM_APP_NAME_ZH="${VERBATIM_APP_NAME_ZH-}"
# Folder name under ~/Library/Application Support: the app's data directory
# (history, audio, lexicon, models) and the folder install.sh watches. build.sh
# writes it into Info.plist as VVDataDirectoryName.
VERBATIM_DATA_DIR_NAME="${VERBATIM_DATA_DIR_NAME:-Totype}"
# 1 (default) packs the SenseVoice runtime and models into the app (full build);
# 0 leaves them out (lite build) and the app downloads them on first use.
VERBATIM_BUNDLE_MODEL="${VERBATIM_BUNDLE_MODEL:-1}"
# Starting value of the "observe manual edits after insertion" setting for users
# who have never changed it: 0 off, 1 (default) on. An existing choice is kept.
VERBATIM_LEARN_FROM_EDITS_DEFAULT="${VERBATIM_LEARN_FROM_EDITS_DEFAULT:-1}"
# If this identity is not in the keychain the build falls back to ad-hoc signing.
VERBATIM_SIGN_IDENTITY="${VERBATIM_SIGN_IDENTITY:-Totype Local Code Signing}"

if [[ -z "${VERBATIM_SDK_PATH:-}" ]]; then
    VERBATIM_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "$VERBATIM_SDK_PATH" || ! -d "$VERBATIM_SDK_PATH" ]]; then
    echo "找不到 macOS SDK（xcrun --sdk macosx --show-sdk-path 无结果）。" >&2
    echo "请安装 Xcode 或 Command Line Tools，或设置 VERBATIM_SDK_PATH（需 macOS 15.4 或更高 SDK）。" >&2
    exit 1
fi
SDK_PATH="$VERBATIM_SDK_PATH"
export VERBATIM_SDK_PATH VERBATIM_BUNDLE_ID VERBATIM_APP_NAME VERBATIM_APP_NAME_ZH VERBATIM_DATA_DIR_NAME VERBATIM_BUNDLE_MODEL VERBATIM_LEARN_FROM_EDITS_DEFAULT VERBATIM_SIGN_IDENTITY
