#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/install-state-policy.sh"
source "$PROJECT_DIR/scripts/lib/env.sh"
# VERBATIM_INSTALL_STRICT=1 (set by install_personal.sh) refuses to replace a
# running app unless the app's runtime status handshake validates. Without it,
# a missing handshake falls back to a normal quit after confirmation.
STRICT="${VERBATIM_INSTALL_STRICT:-0}"
APP_NAME="$VERBATIM_APP_NAME"
DESTINATION="${VERBATIM_DESTINATION:-/Applications/$APP_NAME.app}"
DATA_DIR="${VERBATIM_DATA_DIR:-$HOME/Library/Application Support/$VERBATIM_DATA_DIR_NAME}"
STATUS_FILE="$DATA_DIR/install-runtime-status.json"
PROTOCOL_FILE="$DATA_DIR/install-protocol.json"
TRANSACTION_LOG="$DATA_DIR/install-transactions.log"
# Before the build the installed app (if any) defines the identity; after the
# build it is read from the built artifact's Info.plist.
BUNDLE_ID="$VERBATIM_BUNDLE_ID"
if [[ -f "$DESTINATION/Contents/Info.plist" ]]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || echo "$VERBATIM_BUNDLE_ID")"
fi
MAX_STATUS_AGE_SECONDS=6
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DESTINATION_DIR="$(dirname "$DESTINATION")"
STAGING="$DESTINATION_DIR/$APP_NAME.staging.$TIMESTAMP.$$.app.disabled"
BACKUP="$DESTINATION_DIR/$APP_NAME.backup.$TIMESTAMP.app.disabled"
SWAP_HELPER="$PROJECT_DIR/.build/install-tools/atomic-swap"
# Renaming the app (VERBATIM_APP_NAME) moves it to a new path. When the copy at
# the previous name has the same bundle ID, the installer quits it, installs the
# new name and keeps the old bundle as the rollback backup. Bundle ID, signing
# identity and data directory stay the same, so privacy grants and data carry over.
LEGACY_APP_NAME="${VERBATIM_LEGACY_APP_NAME:-}"
LEGACY_DESTINATION=""
if [[ -n "$LEGACY_APP_NAME" && "$LEGACY_APP_NAME" != "$APP_NAME" && ! -e "$DESTINATION" ]]; then
    candidate="$(dirname "$DESTINATION")/$LEGACY_APP_NAME.app"
    if [[ -f "$candidate/Contents/Info.plist" ]]; then
        LEGACY_DESTINATION="$candidate"
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || echo "$VERBATIM_BUNDLE_ID")"
    fi
fi

die() {
    printf '安装已安全停止：%s\n' "$1" >&2
    log_event "stopped" "$1"
    exit 1
}

log_event() {
    local event="$1"
    local detail="${2:-}"
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR" 2>/dev/null || true
    detail="${detail//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$detail" >> "$TRANSACTION_LOG"
    chmod 600 "$TRANSACTION_LOG" 2>/dev/null || true
}

json_field() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

candidate_pids() {
    local output
    local result
    set +e
    output="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null)"
    result=$?
    set -e
    if [[ $result -eq 0 ]]; then
        printf '%s\n' "$output"
    elif [[ $result -eq 1 ]]; then
        return 0
    else
        die "无法读取 ${APP_NAME} 进程列表；按 fail-closed 规则不覆盖应用。"
    fi
}

process_start_identity() {
    /bin/ps -p "$1" -o lstart= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

process_executable_path() {
    /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

validate_live_status() {
    local pid="$1"
    [[ -f "$STATUS_FILE" ]] || die "运行中的应用没有状态握手；请从菜单正常退出后重新运行安装器。"

    local protocol status_pid state updated_ms expected_start expected_path
    protocol="$(json_field "$STATUS_FILE" installProtocolVersion)" || die "状态握手不可读。"
    status_pid="$(json_field "$STATUS_FILE" pid)" || die "状态握手缺少 PID。"
    state="$(json_field "$STATUS_FILE" state)" || die "状态握手缺少 session state。"
    updated_ms="$(json_field "$STATUS_FILE" updatedAtUnixMilliseconds)" || die "状态握手缺少更新时间。"
    expected_start="$(json_field "$STATUS_FILE" processStartIdentity)" || die "状态握手缺少进程启动身份。"
    expected_path="$(json_field "$STATUS_FILE" executablePath)" || die "状态握手缺少可执行路径。"

    [[ "$protocol" == "1" ]] || die "不支持的安装握手版本：${protocol}。"
    [[ "$status_pid" == "$pid" ]] || die "状态文件 PID 与运行进程不一致。"
    install_state_allows_exchange "$state" \
        || die "应用当前状态为 ${state}；结束或取消本次口述后再更新。"

    local now_ms age_ms
    now_ms=$(( $(date +%s) * 1000 ))
    age_ms=$(( now_ms - updated_ms ))
    [[ $age_ms -ge -1000 && $age_ms -le $((MAX_STATUS_AGE_SECONDS * 1000)) ]] \
        || die "状态握手已经过期或时间异常；不覆盖应用。"

    local actual_start actual_path
    actual_start="$(process_start_identity "$pid")"
    actual_path="$(process_executable_path "$pid")"
    [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] \
        || die "进程启动身份无法验证；不相信可能陈旧的状态文件。"
    [[ "$actual_path" == "$expected_path" && "$actual_path" == "$DESTINATION/Contents/MacOS/$APP_NAME" ]] \
        || die "运行进程不是正式安装路径：${actual_path}。"
}

quit_running_app() {
    local pid="$1"
    local missing_protocol_message="$2"
    if [[ "$STRICT" != "1" && ( ! -f "$PROTOCOL_FILE" || ! -f "$STATUS_FILE" ) ]]; then
        printf '警告：没有找到应用的运行状态握手，无法确认当前没有在录音。\n' >&2
        if [[ -t 0 ]]; then
            local answer
            read -r -p "现在没有在口述吗？继续并请求应用正常退出 [y/N] " answer
            [[ "$answer" == "y" || "$answer" == "Y" ]] || die "已取消；请结束口述后重试。"
        else
            [[ "${VERBATIM_INSTALL_ASSUME_IDLE:-0}" == "1" ]] \
                || die "非交互环境下无法确认应用空闲；确认没有在口述后设置 VERBATIM_INSTALL_ASSUME_IDLE=1 重试。"
        fi
        request_normal_quit "$pid"
        return
    fi
    [[ -f "$PROTOCOL_FILE" ]] || die "$missing_protocol_message"
    validate_live_status "$pid"
    request_normal_quit "$pid"
}

wait_for_process_exit() {
    local pid="$1"
    local attempt=0
    while /bin/kill -0 "$pid" 2>/dev/null; do
        attempt=$((attempt + 1))
        [[ $attempt -le 30 ]] || die "应用没有在 15 秒内正常退出；未强杀、未覆盖。"
        sleep 0.5
    done
}

request_normal_quit() {
    local pid="$1"
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 \
        || die "无法请求应用正常退出；请从菜单点击“退出”后重新运行。"
    wait_for_process_exit "$pid"
}

bundle_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}

designated_requirement() {
    /usr/bin/codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p'
}

certificate_sha256() {
    local app="$1"
    local cert_dir
    cert_dir="$(mktemp -d /private/tmp/verbatim-cert.XXXXXX)"
    (
        cd "$cert_dir"
        /usr/bin/codesign -d --extract-certificates "$app" >/dev/null 2>&1
    )
    local result="unavailable"
    if [[ -f "$cert_dir/codesign0" ]]; then
        result="$(/usr/bin/shasum -a 256 "$cert_dir/codesign0" | awk '{print $1}')"
    fi
    rm -rf "$cert_dir"
    printf '%s\n' "$result"
}

verify_bundle() {
    local app="$1"
    [[ -d "$app" ]] || die "找不到待验证应用：$app"
    /usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null || die "Info.plist 验证失败：$app"
    /usr/bin/codesign --verify --strict "$app" || die "代码签名验证失败：$app"
    [[ "$(bundle_value "$app" CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
        || die "bundle ID 不一致：$app"
}

compile_swap_helper() {
    mkdir -p "$(dirname "$SWAP_HELPER")"
    /usr/bin/clang -Wall -Wextra -Werror -mmacosx-version-min=10.12 \
        "$PROJECT_DIR/scripts/install-atomic-swap/main.c" -o "$SWAP_HELPER"
}

rollback_to() {
    local old_location="$1"
    if [[ -n "$LEGACY_DESTINATION" ]]; then
        # Undo a rename: the previous name goes back to its own path.
        [[ -d "$old_location" ]] || die "回滚所需 bundle 不完整；保留现场：$old_location"
        [[ ! -d "$DESTINATION" ]] || mv "$DESTINATION" "$DESTINATION_DIR/$APP_NAME.failed.$TIMESTAMP.app.disabled"
        mv "$old_location" "$LEGACY_DESTINATION" || die "回滚失败；旧版本保留在：$old_location"
        verify_bundle "$LEGACY_DESTINATION"
        /usr/bin/open "$LEGACY_DESTINATION" >/dev/null 2>&1 || true
        log_event "rolled-back" "restored=$LEGACY_DESTINATION"
        return
    fi
    [[ -d "$old_location" && -d "$DESTINATION" ]] || die "回滚所需 bundle 不完整；保留现场：$old_location"
    "$SWAP_HELPER" "$DESTINATION" "$old_location" || die "原子回滚失败；保留现场。"
    verify_bundle "$DESTINATION"
    log_event "rolled-back" "restored=$DESTINATION failed=$old_location"
}

wait_for_new_handshake() {
    local expected_executable="$DESTINATION/Contents/MacOS/$APP_NAME"
    local attempt=0
    while [[ $attempt -lt 40 ]]; do
        attempt=$((attempt + 1))
        if [[ -f "$STATUS_FILE" ]]; then
            local protocol path state updated_ms now_ms age_ms
            protocol="$(json_field "$STATUS_FILE" installProtocolVersion 2>/dev/null || true)"
            path="$(json_field "$STATUS_FILE" executablePath 2>/dev/null || true)"
            state="$(json_field "$STATUS_FILE" state 2>/dev/null || true)"
            updated_ms="$(json_field "$STATUS_FILE" updatedAtUnixMilliseconds 2>/dev/null || true)"
            now_ms=$(( $(date +%s) * 1000 ))
            if [[ -n "$updated_ms" ]]; then age_ms=$((now_ms - updated_ms)); else age_ms=999999; fi
            if [[ "$protocol" == "1" && "$path" == "$expected_executable" && "$state" == "idle" && $age_ms -ge -1000 && $age_ms -le 6000 ]]; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

commit_protocol() {
    local temp="$PROTOCOL_FILE.tmp.$$"
    printf '{"installProtocolVersion":1,"committedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$temp"
    chmod 600 "$temp"
    mv "$temp" "$PROTOCOL_FILE"
}

if [[ "${1:-}" == "--status" ]]; then
    if [[ -f "$STATUS_FILE" ]]; then
        /bin/cat "$STATUS_FILE"
    else
        printf '{"status":"unavailable"}\n'
    fi
    exit 0
fi

if [[ "${1:-}" == "--preflight" ]]; then
    PIDS="$(candidate_pids)"
    [[ -n "$PIDS" ]] || die "正式 App 当前没有运行；无法验证实时握手。"
    [[ "$(printf '%s\n' "$PIDS" | wc -l | tr -d ' ')" == "1" ]] \
        || die "检测到多个 ${APP_NAME} 进程。"
    [[ -f "$PROTOCOL_FILE" ]] || die "安装协议尚未提交。"
    validate_live_status "$PIDS"
    printf '安装前检查通过：PID %s，状态 idle，进程身份与正式路径一致。\n' "$PIDS"
    exit 0
fi

log_event "started" "destination=$DESTINATION"

legacy_pids() {
    [[ -n "$LEGACY_DESTINATION" ]] || return 0
    local output result
    set +e
    output="$(/usr/bin/pgrep -x "$LEGACY_APP_NAME" 2>/dev/null)"
    result=$?
    set -e
    [[ $result -le 1 ]] || die "无法读取 ${LEGACY_APP_NAME} 进程列表；不覆盖应用。"
    [[ -z "$output" ]] || printf '%s\n' "$output"
}

# Quits the copy under the previous name after the same idle checks as a normal
# update, but against its own executable path.
quit_legacy_app() {
    local pids pid
    pids="$(legacy_pids)"
    [[ -n "$pids" ]] || return 0
    [[ "$(printf '%s\n' "$pids" | wc -l | tr -d ' ')" == "1" ]] || die "检测到多个 ${LEGACY_APP_NAME} 进程。"
    pid="$pids"
    if [[ -f "$STATUS_FILE" ]]; then
        local status_pid state expected_path
        status_pid="$(json_field "$STATUS_FILE" pid || true)"
        state="$(json_field "$STATUS_FILE" state || true)"
        expected_path="$(json_field "$STATUS_FILE" executablePath || true)"
        [[ "$status_pid" == "$pid" && "$expected_path" == "$LEGACY_DESTINATION/Contents/MacOS/$LEGACY_APP_NAME" ]] \
            || die "旧名称应用的状态握手与运行进程不一致；请从菜单退出后重试。"
        install_state_allows_exchange "$state" || die "应用当前状态为 ${state}；结束或取消本次口述后再更新。"
    elif [[ "$STRICT" == "1" ]]; then
        die "旧名称应用没有状态握手；请从菜单退出后重试。"
    fi
    request_normal_quit "$pid"
}

if [[ -n "$LEGACY_DESTINATION" ]]; then
    log_event "rename" "from=$LEGACY_DESTINATION to=$DESTINATION"
    quit_legacy_app
fi

PIDS="$(candidate_pids)"
if [[ -n "$PIDS" ]]; then
    if [[ "$(printf '%s\n' "$PIDS" | wc -l | tr -d ' ')" != "1" ]]; then
        die "检测到多个 ${APP_NAME} 进程；请全部正常退出后重试。"
    fi
    PID="$PIDS"
    quit_running_app "$PID" "首次安全安装需要先确认当前没有录音，并从菜单正常退出 ${APP_NAME}；旧版没有可验证握手，安装器不会代替判断。"
fi

# Building can take long enough for runtime state to change.  Build first, then
# repeat the complete process/state validation immediately before exchange.
APP_PATH="$("$PROJECT_DIR/scripts/build.sh" | tail -n 1)"
BUNDLE_ID="$(bundle_value "$APP_PATH" CFBundleIdentifier)"
[[ -n "$BUNDLE_ID" ]] || die "无法从构建产物读取 CFBundleIdentifier。"
verify_bundle "$APP_PATH"

PIDS="$(candidate_pids)"
if [[ -n "$PIDS" ]]; then
    [[ "$(printf '%s\n' "$PIDS" | wc -l | tr -d ' ')" == "1" ]] \
        || die "构建期间出现多个 ${APP_NAME} 进程。"
    PID="$PIDS"
    quit_running_app "$PID" "构建期间旧版被重新打开；首次 bootstrap 已停止。"
fi

[[ -z "$LEGACY_DESTINATION" ]] || quit_legacy_app

compile_swap_helper
cp -R -X "$APP_PATH" "$STAGING"
verify_bundle "$STAGING"

NEW_REQUIREMENT="$(designated_requirement "$STAGING")"
NEW_CERT_SHA="$(certificate_sha256 "$STAGING")"
NEW_VERSION="$(bundle_value "$STAGING" CFBundleShortVersionString)"
NEW_BUILD="$(bundle_value "$STAGING" CFBundleVersion)"
IS_ADHOC=0
if /usr/bin/codesign -dv "$STAGING" 2>&1 | grep -q 'Signature=adhoc'; then IS_ADHOC=1; fi
if [[ "$STRICT" != "1" && $IS_ADHOC -eq 1 ]]; then
    printf '警告：新版本是 ad-hoc 签名，代码身份每次重建都会变化；系统可能撤销麦克风、辅助功能、输入监控授权，需要重新授权。\n' >&2
else
    [[ -n "$NEW_REQUIREMENT" && "$NEW_CERT_SHA" != "unavailable" ]] \
        || die "无法读取新版本代码身份。"
fi

OLD_LOCATION=""
if [[ -n "$LEGACY_DESTINATION" ]]; then
    verify_bundle "$LEGACY_DESTINATION"
    if [[ "$STRICT" == "1" || $IS_ADHOC -eq 0 ]]; then
        [[ "$(designated_requirement "$LEGACY_DESTINATION")" == "$NEW_REQUIREMENT" ]] || die "designated requirement 发生变化；拒绝污染 TCC 身份。"
        [[ "$(certificate_sha256 "$LEGACY_DESTINATION")" == "$NEW_CERT_SHA" ]] || die "签名证书指纹发生变化；拒绝覆盖。"
    fi
    mv "$STAGING" "$DESTINATION"
    mv "$LEGACY_DESTINATION" "$BACKUP" || { mv "$DESTINATION" "$STAGING"; die "无法移走旧名称应用；已撤回新版本。"; }
    OLD_LOCATION="$BACKUP"
elif [[ -d "$DESTINATION" ]]; then
    verify_bundle "$DESTINATION"
    OLD_REQUIREMENT="$(designated_requirement "$DESTINATION")"
    OLD_CERT_SHA="$(certificate_sha256 "$DESTINATION")"
    if [[ "$STRICT" == "1" || $IS_ADHOC -eq 0 ]]; then
        [[ "$OLD_REQUIREMENT" == "$NEW_REQUIREMENT" ]] || die "designated requirement 发生变化；拒绝污染 TCC 身份。"
        [[ "$OLD_CERT_SHA" == "$NEW_CERT_SHA" ]] || die "签名证书指纹发生变化；拒绝覆盖。"
    fi

    "$SWAP_HELPER" "$DESTINATION" "$STAGING" || die "原子交换失败；正式 App 未改变。"
    OLD_LOCATION="$STAGING"
    if mv "$OLD_LOCATION" "$BACKUP"; then
        OLD_LOCATION="$BACKUP"
    fi
else
    mv "$STAGING" "$DESTINATION"
fi

if ! /usr/bin/codesign --verify --strict "$DESTINATION"; then
    [[ -n "$OLD_LOCATION" ]] && rollback_to "$OLD_LOCATION"
    die "交换后签名验证失败，已尝试恢复上一版。"
fi

log_event "swapped" "version=$NEW_VERSION build=$NEW_BUILD cert=$NEW_CERT_SHA backup=$OLD_LOCATION"
/usr/bin/open "$DESTINATION" || {
    [[ -n "$OLD_LOCATION" ]] && rollback_to "$OLD_LOCATION"
    die "新版本无法启动，已恢复上一版。"
}

if ! wait_for_new_handshake; then
    NEW_PIDS="$(candidate_pids)"
    if [[ -n "$NEW_PIDS" && "$(printf '%s\n' "$NEW_PIDS" | wc -l | tr -d ' ')" == "1" ]]; then
        /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        wait_for_process_exit "$NEW_PIDS" || true
    fi
    if [[ -n "$OLD_LOCATION" ]]; then
        rollback_to "$OLD_LOCATION"
        /usr/bin/open "$DESTINATION" >/dev/null 2>&1 || true
    fi
    die "新版本没有在 20 秒内提供可信 idle 握手；未提交安装协议。"
fi

NEW_PIDS="$(candidate_pids)"
if [[ -z "$NEW_PIDS" || "$(printf '%s\n' "$NEW_PIDS" | wc -l | tr -d ' ')" != "1" ]]; then
    if [[ -n "$OLD_LOCATION" ]]; then
        rollback_to "$OLD_LOCATION"
        /usr/bin/open "$DESTINATION" >/dev/null 2>&1 || true
    fi
    die "新版本握手后无法确认唯一正式进程；未提交安装协议。"
fi
validate_live_status "$NEW_PIDS"

commit_protocol
log_event "committed" "version=$NEW_VERSION build=$NEW_BUILD destination=$DESTINATION"

# Keep exactly one rollback point: the version this install just replaced.
# Older backups from earlier installs are removed once the new one is committed.
for stale in "$DESTINATION_DIR/$APP_NAME".backup.*.app.disabled ${LEGACY_APP_NAME:+"$DESTINATION_DIR/$LEGACY_APP_NAME".backup.*.app.disabled}; do
    [[ -d "$stale" && "$stale" != "$OLD_LOCATION" ]] || continue
    if /bin/rm -rf -- "$stale"; then
        log_event "pruned_backup" "path=$stale"
    fi
done

printf '已安全安装：%s（版本 %s，构建 %s）\n' "$DESTINATION" "$NEW_VERSION" "$NEW_BUILD"
if [[ -n "$OLD_LOCATION" ]]; then
    printf '上一版可恢复备份：%s\n' "$OLD_LOCATION"
fi
