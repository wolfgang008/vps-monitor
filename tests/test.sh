#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # Test cases intentionally isolate global overrides in subshells.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export VPS_MONITOR_NO_MAIN=1
# shellcheck source=TG-check-notify.sh
source "${ROOT_DIR}/TG-check-notify.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
DATA_DIR="$TEST_DIR"
STATE_FILE="${DATA_DIR}/state.tsv"
SAMPLES_FILE="${DATA_DIR}/samples.tsv"
export SERVER_NAME="测试服务器"
export TZ=UTC

assert_equal() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s\nExpected:\n%s\nActual:\n%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

test_supported_os() (
    # shellcheck disable=SC2317,SC2329 # Used by command -v inside the sourced check.
    systemctl() { :; }
    # shellcheck disable=SC2317,SC2329 # Used by command -v inside the sourced check.
    apt-get() { :; }
    # shellcheck disable=SC2317,SC2329 # Used by command -v inside the sourced check.
    dpkg-query() { :; }
    local os_release="${TEST_DIR}/os-release"
    export VPS_MONITOR_OS_RELEASE_FILE="$os_release"

    printf 'ID=ubuntu\nVERSION_ID="22.04"\nPRETTY_NAME="Ubuntu 22.04 LTS"\n' > "$os_release"
    verify_supported_os >/dev/null
    printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$os_release"
    verify_supported_os >/dev/null
    printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$os_release"
    verify_supported_os >/dev/null
    printf 'ID=debian\nVERSION_ID="11"\nPRETTY_NAME="Debian GNU/Linux 11 (bullseye)"\n' > "$os_release"
    if (verify_supported_os) >/dev/null 2>&1; then
        printf 'FAIL: unsupported Debian version was accepted\n' >&2
        exit 1
    fi
    printf 'ID=debian\nVERSION_ID="13"\nPRETTY_NAME="Debian GNU/Linux 13 (trixie)"\n' > "$os_release"
    if (verify_supported_os) >/dev/null 2>&1; then
        printf 'FAIL: Debian 13 was accepted\n' >&2
        exit 1
    fi
    printf 'ID=ubuntu\nVERSION_ID="20.04"\nPRETTY_NAME="Ubuntu 20.04 LTS"\n' > "$os_release"
    if (verify_supported_os) >/dev/null 2>&1; then
        printf 'FAIL: unsupported Ubuntu version was accepted\n' >&2
        exit 1
    fi
    printf 'ID=ubuntu\nVERSION_ID="26.04"\nPRETTY_NAME="Ubuntu 26.04 LTS"\n' > "$os_release"
    if (verify_supported_os) >/dev/null 2>&1; then
        printf 'FAIL: Ubuntu 26.04 was accepted\n' >&2
        exit 1
    fi
)
test_supported_os

is_telegram_uid "123456789" || { printf 'FAIL: valid Telegram UID rejected\n' >&2; exit 1; }
if is_telegram_uid "@example" || is_telegram_uid "012345" || is_telegram_uid "-100123"; then
    printf 'FAIL: invalid Telegram UID accepted\n' >&2
    exit 1
fi

is_server_name "测试服务器" || { printf 'FAIL: valid Chinese server name rejected\n' >&2; exit 1; }
is_server_name "My VPS 01" || { printf 'FAIL: valid spaced server name rejected\n' >&2; exit 1; }
long_server_name="$(printf '%081d' 0)"
if is_server_name "" || is_server_name "   " || is_server_name $'bad\tname' \
    || is_server_name "$long_server_name"; then
    printf 'FAIL: invalid server name accepted\n' >&2
    exit 1
fi
if declare -F detect_server_name >/dev/null; then
    printf 'FAIL: automatic server naming function still exists\n' >&2
    exit 1
fi

test_rename_server() (
    CONFIG_DIR="${TEST_DIR}/rename-config"
    SERVER_NAME_FILE="${CONFIG_DIR}/server_name"
    SERVICE_USER=vpsmonitor
    mkdir -p "$CONFIG_DIR"
    printf '%s' '旧名称' > "$SERVER_NAME_FILE"

    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    is_managed_service_account() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    load_config() { SERVER_NAME="$(<"$SERVER_NAME_FILE")"; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    has_interactive_terminal() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    prompt_server_name() { printf '%s' '手动输入的新名称'; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    chown() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced rename function.
    chmod() { :; }

    rename_server >/dev/null
    assert_equal "手动输入的新名称" "$(<"$SERVER_NAME_FILE")" "manual server rename"

    printf '%s' '应当保留的名称' > "$SERVER_NAME_FILE"
    # shellcheck disable=SC2317,SC2329 # Simulates a failed atomic configuration write.
    chmod() { return 1; }
    if (rename_server) >/dev/null 2>&1; then
        printf 'FAIL: failed server rename was reported as successful\n' >&2
        exit 1
    fi
    assert_equal "应当保留的名称" "$(<"$SERVER_NAME_FILE")" "failed rename preserves old name"
)
(test_rename_server)

if (run_as_service_user_if_needed collect) >/dev/null 2>&1; then
    printf 'FAIL: non-service user was allowed to run a state-writing command\n' >&2
    exit 1
fi

printf '%s' 'vps_0123456789abcdef0123456789abcdef' > "${TEST_DIR}/bind-nonce"
printf '%s\n' '{"ok":true,"result":[{"update_id":7,"message":{"text":"/start wrong","from":{"id":111,"is_bot":false},"chat":{"id":111,"type":"private"}}},{"update_id":9,"message":{"text":"/start vps_0123456789abcdef0123456789abcdef","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}}]}' > "${TEST_DIR}/telegram-updates.json"
assert_equal "10" "$(telegram_updates_cursor "${TEST_DIR}/telegram-updates.json")" "Telegram update cursor"
IFS=$'\t' read -r update_cursor matched_uid <<< "$(telegram_start_match "${TEST_DIR}/telegram-updates.json" "${TEST_DIR}/bind-nonce" 0)"
assert_equal "10" "$update_cursor" "Telegram start cursor"
assert_equal "987654321" "$matched_uid" "Telegram secure start UID"

command_now=2000000000
printf '%s\n' '{"ok":true,"result":[{"update_id":10,"message":{"date":1999999900,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}}]}' > "${TEST_DIR}/telegram-reboot-valid.json"
IFS=$'\t' read -r command_cursor reboot_match <<< "$(telegram_reboot_match "${TEST_DIR}/telegram-reboot-valid.json" 987654321 10 "$command_now" 180)"
assert_equal "11" "$command_cursor" "Telegram reboot cursor"
assert_equal "1" "$reboot_match" "authorized Telegram reboot command"
IFS=$'\t' read -r command_cursor reboot_match <<< "$(telegram_reboot_match "${TEST_DIR}/telegram-reboot-valid.json" 987654321 11 "$command_now" 180)"
assert_equal "11" "$command_cursor" "Telegram reboot replay cursor"
assert_equal "0" "$reboot_match" "Telegram reboot replay prevention"

printf '%s\n' '{"ok":true,"result":[{"update_id":11,"message":{"date":1999999900,"text":"/reboot","from":{"id":111111111,"is_bot":false},"chat":{"id":111111111,"type":"private"}}},{"update_id":12,"message":{"date":1999999900,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":-100987654321,"type":"supergroup"}}},{"update_id":13,"message":{"date":1999999900,"text":"/reboot","forward_origin":{"type":"user"},"from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}},{"update_id":14,"message":{"date":1999999000,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}},{"update_id":15,"message":{"date":1999999900,"text":"/reboot now","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}},{"update_id":16,"edited_message":{"date":1999999900,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}},{"update_id":17,"message":{"date":2000000031,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}},{"update_id":18,"message":{"date":1999999900,"text":"/reboot","from":{"id":987654321,"is_bot":true},"chat":{"id":987654321,"type":"private"}}}]}' > "${TEST_DIR}/telegram-reboot-rejected.json"
IFS=$'\t' read -r command_cursor reboot_match <<< "$(telegram_reboot_match "${TEST_DIR}/telegram-reboot-rejected.json" 987654321 11 "$command_now" 180)"
assert_equal "19" "$command_cursor" "rejected Telegram commands advance cursor"
assert_equal "0" "$reboot_match" "unauthorized Telegram reboot commands"
printf '%s\n' '{"ok":true,"result":{}}' > "${TEST_DIR}/telegram-reboot-invalid.json"
if telegram_reboot_match "${TEST_DIR}/telegram-reboot-invalid.json" 987654321 0 "$command_now" 180 >/dev/null 2>&1; then
    printf 'FAIL: malformed Telegram command response was accepted\n' >&2
    exit 1
fi

test_command_poll() (
    CONFIG_DIR="${TEST_DIR}/command-config"
    COMMAND_OFFSET_FILE="${CONFIG_DIR}/command_offset"
    UPDATE_LOCK_FILE="${TEST_DIR}/command-update.lock"
    TOKEN='123456:abcdefghijklmnopqrstuvwxyzABCDE_12345'
    CHAT_ID=987654321
    SERVER_NAME=测试服务器
    WORK_DIR=""
    mkdir -p "$CONFIG_DIR"
    printf '10\n' > "$COMMAND_OFFSET_FILE"
    local now command_response_fixture="${TEST_DIR}/command-poll-response.json"
    now="$(date +%s)"
    printf '{"ok":true,"result":[{"update_id":10,"message":{"date":%s,"text":"/reboot","from":{"id":987654321,"is_bot":false},"chat":{"id":987654321,"type":"private"}}}]}\n' "$now" > "$command_response_fixture"

    # shellcheck disable=SC2317,SC2329 # Command-poll dependency stubs.
    require_root() { :; }
    load_config() { :; }
    flock() { return 0; }
    chown() { :; }
    stat() { printf '0:0:600\n'; }
    sync() { :; }
    setup_api_call() { command cp -- "$command_response_fixture" "$3"; }
    send_message() { printf '%s' "$1" > "${TEST_DIR}/command-ack"; }
    systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/command-systemctl"; }

    (run_command_poll) >/dev/null
    assert_equal "11" "$(<"$COMMAND_OFFSET_FILE")" "successful reboot command cursor"
    assert_equal "--no-block reboot" "$(<"${TEST_DIR}/command-systemctl")" "systemd reboot request"
    grep -Fqx '♻️ 已收到安全重启命令，VPS 将在数秒内重启。' "${TEST_DIR}/command-ack"

    printf '10\n' > "$COMMAND_OFFSET_FILE"
    : > "${TEST_DIR}/command-systemctl"
    systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/command-systemctl"; return 1; }
    if (run_command_poll) >/dev/null 2>&1; then
        printf 'FAIL: failed system reboot was reported as successful\n' >&2
        exit 1
    fi
    assert_equal "10" "$(<"$COMMAND_OFFSET_FILE")" "failed reboot restores command cursor"

    : > "${TEST_DIR}/command-systemctl"
    systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/command-systemctl"; }
    sync() { return 1; }
    if (run_command_poll) >/dev/null 2>&1; then
        printf 'FAIL: failed disk sync was reported as successful\n' >&2
        exit 1
    fi
    assert_equal "10" "$(<"$COMMAND_OFFSET_FILE")" "failed disk sync restores command cursor"
    [[ ! -s "${TEST_DIR}/command-systemctl" ]] \
        || { printf 'FAIL: failed disk sync requested reboot\n' >&2; exit 1; }
    sync() { :; }

    printf '10\n' > "$COMMAND_OFFSET_FILE"
    printf '{"ok":true,"result":[{"update_id":10,"message":{"date":%s,"text":"/reboot","from":{"id":111111111,"is_bot":false},"chat":{"id":111111111,"type":"private"}}}]}\n' "$now" > "$command_response_fixture"
    : > "${TEST_DIR}/command-systemctl"
    systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/command-systemctl"; }
    assert_equal "command-poll: checked" "$(run_command_poll)" "unauthorized command poll"
    assert_equal "11" "$(<"$COMMAND_OFFSET_FILE")" "unauthorized command advances cursor"
    [[ ! -s "${TEST_DIR}/command-systemctl" ]] \
        || { printf 'FAIL: unauthorized command requested reboot\n' >&2; exit 1; }

    # shellcheck disable=SC2317,SC2329 # Simulates an insecure command cursor.
    stat() { printf '0:0:640\n'; }
    if (run_command_poll) >/dev/null 2>&1; then
        printf 'FAIL: insecure command cursor permissions were accepted\n' >&2
        exit 1
    fi
    [[ ! -s "${TEST_DIR}/command-systemctl" ]] \
        || { printf 'FAIL: insecure command cursor requested reboot\n' >&2; exit 1; }
)
(test_command_poll)

test_command_offset_initialization() (
    CONFIG_DIR="${TEST_DIR}/command-init-config"
    COMMAND_OFFSET_FILE="${CONFIG_DIR}/command_offset"
    WORK_DIR="${TEST_DIR}/command-init-work"
    TOKEN='123456:abcdefghijklmnopqrstuvwxyzABCDE_12345'
    mkdir -p "$CONFIG_DIR" "$WORK_DIR"
    printf '%s\n' '{"ok":true,"result":[{"update_id":41}]}' > "${TEST_DIR}/command-init-response.json"
    # shellcheck disable=SC2317,SC2329 # Command cursor initialization stubs.
    chown() { :; }
    setup_api_call() { command cp -- "${TEST_DIR}/command-init-response.json" "$3"; }
    initialize_command_offset
    assert_equal "42" "$(<"$COMMAND_OFFSET_FILE")" "initial Telegram reboot cursor"
    setup_api_call() { printf 'FAIL: valid command cursor was unnecessarily reset\n' >&2; return 1; }
    initialize_command_offset
    assert_equal "42" "$(<"$COMMAND_OFFSET_FILE")" "existing Telegram reboot cursor"
)
(test_command_offset_initialization)

expected_two_hour=$'测试服务器\n进站速度: 10.15 MB/s\n出站速度: 10.07 MB/s\n总流量: 2.51 TB\nCPU利用率: 29%'
actual_two_hour="$(format_two_hour_message 73080000000 72504000000 29 100 7200 2510000000000)"
assert_equal "$expected_two_hour" "$actual_two_hour" "two-hour message format"
partial_coverage_message="$(format_two_hour_message 64800000000 32400000000 29 100 6480 1000000000000)"
grep -Fqx '进站速度: 10.00 MB/s' <<< "$partial_coverage_message"
grep -Fqx '出站速度: 5.00 MB/s' <<< "$partial_coverage_message"
if grep -Fq 'protect_content' "${ROOT_DIR}/TG-check-notify.sh"; then
    printf 'FAIL: Telegram messages are still protected from copying or forwarding\n' >&2
    exit 1
fi
if grep -Fq '月底预计' "${ROOT_DIR}/TG-check-notify.sh"; then
    printf 'FAIL: month-end forecast text still exists\n' >&2
    exit 1
fi

expected_month=$'测试服务器 2026年8月流量报告\n进站流量: 1.42 TB\n出站流量: 1.09 TB\n总流量: 2.51 TB\n平均CPU利用率: 29%'
actual_month="$(format_month_message 2026-08 1420000000000 1090000000000 29 100)"
assert_equal "$expected_month" "$actual_month" "monthly message format"

expected_week=$'测试服务器\n上一周的流量使用情况为：\n进站流量: 0.12 TB\n出站流量: 0.08 TB\n总流量: 0.20 TB'
actual_week="$(format_week_message 120000000000 80000000000)"
assert_equal "$expected_week" "$actual_week" "weekly message format"
assert_equal "2025-W52" "$(previous_week_key 2026-W01)" "previous ISO week key"

boot_epoch="$(date -d '2026-08-05 10:00:00 UTC' +%s)"
boot_now="$(date -d '2026-08-05 12:30:00 UTC' +%s)"
boot_message="$(format_boot_message "$boot_epoch" "$boot_now")"
grep -Fqx '状态: 已启动并恢复监控' <<< "$boot_message"
grep -Fqx '预计离线: 2 小时 30 分钟' <<< "$boot_message"

version_is_newer 1.5.0 1.4.9 || { printf 'FAIL: newer version was rejected\n' >&2; exit 1; }
if version_is_newer 1.5.0 1.5.0 || version_is_newer 1.4.9 1.5.0; then
    printf 'FAIL: equal or older version was accepted as newer\n' >&2
    exit 1
fi

downloaded_script="${TEST_DIR}/downloaded-script"
downloaded_checksum="${TEST_DIR}/downloaded-checksum"
printf '#!/usr/bin/env bash\n# VPS_TELEGRAM_MONITOR_SCRIPT=1\nVERSION="9.8.7"\n' > "$downloaded_script"
printf '%s  TG-check-notify.sh\n' "$(sha256sum "$downloaded_script" | awk '{print $1}')" > "$downloaded_checksum"
verify_downloaded_script "$downloaded_script" "$downloaded_checksum" \
    || { printf 'FAIL: valid download checksum was rejected\n' >&2; exit 1; }
printf '%064d  TG-check-notify.sh\n' 0 > "$downloaded_checksum"
if verify_downloaded_script "$downloaded_script" "$downloaded_checksum"; then
    printf 'FAIL: invalid download checksum was accepted\n' >&2
    exit 1
fi

archive_source="${TEST_DIR}/${GITHUB_ARCHIVE_ROOT}"
mkdir -p "$archive_source"
cp -- "$downloaded_script" "${archive_source}/TG-check-notify.sh"
printf '%s  TG-check-notify.sh\n' \
    "$(sha256sum "$downloaded_script" | awk '{print $1}')" > "${archive_source}/TG-check-notify.sh.sha256"
tar -czf "${TEST_DIR}/main.tar.gz" -C "$TEST_DIR" "$GITHUB_ARCHIVE_ROOT"
extract_verified_main_archive "${TEST_DIR}/main.tar.gz" \
    "${TEST_DIR}/archive-script" "${TEST_DIR}/archive-checksum" \
    || { printf 'FAIL: valid GitHub main archive was rejected\n' >&2; exit 1; }
assert_equal "9.8.7" "$(script_version "${TEST_DIR}/archive-script")" "GitHub main archive script"

login_epoch="$(date -d '2026-08-05 12:34:56 UTC' +%s)"
login_time="$(date -d "@${login_epoch}" '+%F %T %Z')"
expected_login="$(printf '⚠️ VPS 登录提醒\n服务器: 测试服务器\n登录用户: root\n来源IP: 203.0.113.8\n登录时间: %s' "$login_time")"
actual_login="$(format_login_message root 203.0.113.8 "$login_epoch")"
assert_equal "$expected_login" "$actual_login" "SSH login alert format"

(
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Must remain unused by the login-alert path.
    acquire_lock() { printf 'FAIL: login alert used the statistics lock\n' >&2; return 1; }
    send_message() { printf '%s' "$1" > "${TEST_DIR}/captured-login-alert"; }
    VPS_LOGIN_USER=root VPS_LOGIN_IP=203.0.113.8 run_login_alert >/dev/null
)
login_prefix=$'⚠️ VPS 登录提醒\n服务器: 测试服务器\n登录用户: root\n来源IP: 203.0.113.8\n登录时间: '
[[ "$(<"${TEST_DIR}/captured-login-alert")" == "${login_prefix}"* ]] \
    || { printf 'FAIL: SSH login alert delivery\n' >&2; exit 1; }

test_boot_alert_delivery() (
    DATA_DIR="${TEST_DIR}/boot-alert"
    STATE_FILE="${DATA_DIR}/state.tsv"
    LOCK_FILE="${DATA_DIR}/monitor.lock"
    BOOT_ID_FILE="${DATA_DIR}/boot-id"
    mkdir -p "$DATA_DIR"
    printf '%s' 11111111-2222-3333-4444-555555555555 > "$BOOT_ID_FILE"
    reset_state_defaults
    LAST_TS=$(( $(date +%s) - 600 ))
    LAST_BOOT=00000000-0000-0000-0000-000000000001
    LAST_INTERFACE=eth0
    BOOT_ALERTED="$LAST_BOOT"
    save_state
    # shellcheck disable=SC2317,SC2329 # Called by the boot alert command.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Captures boot alert delivery.
    send_message() {
        printf '%s' "$1" > "${DATA_DIR}/captured-message"
        printf 'sent\n' >> "${DATA_DIR}/send-count"
    }
    assert_equal "boot-alert: sent" "$(run_boot_alert)" "boot recovery alert delivery"
    grep -Fqx '状态: 已启动并恢复监控' "${DATA_DIR}/captured-message"
    assert_equal "boot-alert: duplicate-skipped" "$(run_boot_alert)" "boot alert duplicate prevention"
    assert_equal "1" "$(wc -l < "${DATA_DIR}/send-count")" "boot alert send count"
)
(test_boot_alert_delivery)

render_login_hook > "${TEST_DIR}/login-alert-hook"
sh -n "${TEST_DIR}/login-alert-hook"
grep -Fq -- '--no-block' "${TEST_DIR}/login-alert-hook"
grep -Fq -- '/usr/bin/date +%s%N' "${TEST_DIR}/login-alert-hook"
grep -Fq -- "VPS_LOGIN_IP=\$PAM_RHOST" "${TEST_DIR}/login-alert-hook"

SSHD_BIN="${TEST_DIR}/sshd"
printf '#!/usr/bin/env sh\nprintf "usepam yes\\n"\n' > "$SSHD_BIN"
chmod 0700 "$SSHD_BIN"
sshd_pam_is_enabled || { printf 'FAIL: enabled SSH PAM was rejected\n' >&2; exit 1; }
printf '#!/usr/bin/env sh\nprintf "usepam no\\n"\n' > "$SSHD_BIN"
if sshd_pam_is_enabled; then
    printf 'FAIL: disabled SSH PAM was accepted\n' >&2
    exit 1
fi

PAM_SSHD_FILE="${TEST_DIR}/pam-sshd"
printf 'session required pam_unix.so\n' > "$PAM_SSHD_FILE"
ensure_pam_login_line
ensure_pam_login_line
assert_equal "1" "$(grep -Fxc "$(pam_login_line)" "$PAM_SSHD_FILE")" "PAM hook is idempotent"
remove_pam_login_line
if grep -Fqx "$(pam_login_line)" "$PAM_SSHD_FILE"; then
    printf 'FAIL: PAM hook was not removed\n' >&2
    exit 1
fi

test_status() {
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    load_state() { LAST_TS="$(date +%s)"; LAST_REPORT=0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    systemctl() { [[ "${1:-}" != is-failed ]]; }
    # shellcheck disable=SC2317,SC2329 # Simulates a secure root-only command cursor.
    stat() { printf '0:0:600\n'; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    sshd_pam_is_enabled() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced status function.
    monitored_interface_is_readable() { return 0; }
    local DATA_DIR="${TEST_DIR}/status"
    local STATE_FILE="${DATA_DIR}/state.tsv"
    local SAMPLES_FILE="${DATA_DIR}/samples.tsv"
    local LOGIN_HOOK_PATH="${DATA_DIR}/login-alert-hook"
    local PAM_SSHD_FILE="${DATA_DIR}/pam-sshd"
    local COMMAND_OFFSET_FILE="${DATA_DIR}/command_offset"
    mkdir -p "$DATA_DIR"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$LOGIN_HOOK_PATH"; chmod 0700 "$LOGIN_HOOK_PATH"
    pam_login_line > "$PAM_SSHD_FILE"
    printf '42\n' > "$COMMAND_OFFSET_FILE"
    status_output="$(run_status)"
    grep -Fqx '定时任务: 正常' <<< "$status_output"
    grep -Fqx '自动更新: 正常' <<< "$status_output"
    grep -Fqx '远程重启: 正常' <<< "$status_output"
    grep -Fqx '登录提醒: 正常' <<< "$status_output"
    # shellcheck disable=SC2317,SC2329 # Replaces the healthy state for the stale-state check.
    load_state() { LAST_TS=0; LAST_REPORT=0; }
    status_output="$(run_status)"
    grep -Fqx '定时任务: 异常' <<< "$status_output"
    # shellcheck disable=SC2317,SC2329 # Replaces the stale state for the service-result check.
    load_state() { LAST_TS="$(date +%s)"; LAST_REPORT=0; }
    # shellcheck disable=SC2317,SC2329 # Simulates a service waiting to restart after failure.
    systemctl() {
        case "${1:-}" in
            is-failed) return 1 ;;
            show) printf 'exit-code\n' ;;
            *) return 0 ;;
        esac
    }
    status_output="$(run_status)"
    grep -Fqx '定时任务: 异常' <<< "$status_output"
}
(test_status)

printf '1000\t1060\t6000\t3000\t25\t100\n' > "$SAMPLES_FILE"
read -r rx tx busy total coverage <<< "$(calculate_window 1060)"
assert_equal "6000.000000" "$rx" "window rx"
assert_equal "3000.000000" "$tx" "window tx"
assert_equal "25.000000" "$busy" "window busy"
assert_equal "100.000000" "$total" "window total"
assert_equal "60.000000" "$coverage" "window coverage"

(
    DATA_DIR="${TEST_DIR}/lock-contention"
    LOCK_FILE="${DATA_DIR}/monitor.lock"
    mkdir -p "$DATA_DIR"
    # shellcheck disable=SC2317,SC2329 # Called by the sourced collector/report paths.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Simulates a busy statistics lock.
    flock() { return 1; }
    collector_busy_output="$(run_collect 2>/dev/null)"
    [[ "$collector_busy_output" == *$'\ncollect: lock-busy-skipped' ]] \
        || { printf 'FAIL: collector did not safely skip lock contention\n' >&2; exit 1; }
    if (run_report) >/dev/null 2>&1; then
        printf 'FAIL: report lock contention was reported as success\n' >&2
        exit 1
    fi
)

pwned="${TEST_DIR}/pwned"
# shellcheck disable=SC2016 # Literal payload verifies that state is never executed.
printf 'month_rx\t$(touch %s)\nmonth_tx\t42\n' "$pwned" > "$STATE_FILE"
load_state
assert_equal "0" "$MONTH_RX" "invalid state rejected"
assert_equal "42" "$MONTH_TX" "valid state accepted"
assert_equal "" "$STATE_WEEK" "legacy state starts without weekly key"
assert_equal "0" "$WEEK_RX" "legacy state starts with zero weekly rx"
assert_equal "0" "$PREVIOUS_BOOT_LAST_TS" "legacy state starts without previous boot timestamp"
assert_equal "" "$BOOT_ALERTED" "legacy state starts without boot alert marker"
[[ ! -e "$pwned" ]] || { printf 'FAIL: state file was executed\n' >&2; exit 1; }

STATE_MONTH="2026-07"
MONTH_RX=100; MONTH_TX=200; MONTH_CPU_BUSY=10; MONTH_CPU_TOTAL=50; MONTH_SECONDS=60
LAST_TS="$(date -d '2026-07-31 23:55:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-08-01 00:05:00 UTC' +%s)"
add_month_delta 2026-08 600 6000 8000 300 600
read -r archived_rx archived_tx archived_busy archived_total archived_seconds < "${DATA_DIR}/month-2026-07.tsv"
assert_equal "3100" "$archived_rx" "previous month rx split"
assert_equal "4200" "$archived_tx" "previous month tx split"
assert_equal "160" "$archived_busy" "previous month cpu split"
assert_equal "350" "$archived_total" "previous month cpu total split"
assert_equal "360" "$archived_seconds" "previous month duration split"
assert_equal "2026-08" "$STATE_MONTH" "new month selected"
assert_equal "3000" "$MONTH_RX" "new month rx split"
assert_equal "4000" "$MONTH_TX" "new month tx split"
assert_equal "150" "$MONTH_CPU_BUSY" "new month cpu split"
assert_equal "300" "$MONTH_CPU_TOTAL" "new month cpu total split"
assert_equal "300" "$MONTH_SECONDS" "new month duration split"

STATE_MONTH="2026-07"
MONTH_RX=100; MONTH_TX=200; MONTH_CPU_BUSY=10; MONTH_CPU_TOTAL=50; MONTH_SECONDS=60
LAST_TS="$(date -d '2026-07-31 23:00:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-08-01 01:00:00 UTC' +%s)"
add_month_delta 2026-08 7200 7200 14400 3600 7200
read -r archived_rx archived_tx archived_busy archived_total archived_seconds < "${DATA_DIR}/month-2026-07.tsv"
assert_equal "3700" "$archived_rx" "long-gap previous month rx split"
assert_equal "7400" "$archived_tx" "long-gap previous month tx split"
assert_equal "1810" "$archived_busy" "long-gap previous month cpu split"
assert_equal "3650" "$archived_total" "long-gap previous month cpu total split"
assert_equal "3660" "$archived_seconds" "long-gap previous month duration split"
assert_equal "3600" "$MONTH_RX" "long-gap new month rx split"
assert_equal "7200" "$MONTH_TX" "long-gap new month tx split"
assert_equal "1800" "$MONTH_CPU_BUSY" "long-gap new month cpu split"
assert_equal "3600" "$MONTH_CPU_TOTAL" "long-gap new month cpu total split"
assert_equal "3600" "$MONTH_SECONDS" "long-gap new month duration split"

STATE_MONTH="2026-06"
MONTH_RX=0; MONTH_TX=0; MONTH_CPU_BUSY=0; MONTH_CPU_TOTAL=0; MONTH_SECONDS=0
LAST_TS="$(date -d '2026-06-30 23:00:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-08-01 01:00:00 UTC' +%s)"
multi_elapsed=$((CURRENT_TS - LAST_TS))
multi_rx=$((multi_elapsed * 10000000)); multi_tx=$((multi_elapsed * 5000000))
add_month_delta 2026-08 "$multi_elapsed" "$multi_rx" "$multi_tx" \
    "$multi_elapsed" "$((multi_elapsed * 2))"
read -r archived_rx archived_tx archived_busy archived_total archived_seconds < "${DATA_DIR}/month-2026-06.tsv"
assert_equal "36000000000" "$archived_rx" "multi-month June rx without overflow"
assert_equal "18000000000" "$archived_tx" "multi-month June tx without overflow"
assert_equal "3600" "$archived_seconds" "multi-month June duration"
read -r archived_rx archived_tx archived_busy archived_total archived_seconds < "${DATA_DIR}/month-2026-07.tsv"
assert_equal "26784000000000" "$archived_rx" "multi-month July rx archive"
assert_equal "13392000000000" "$archived_tx" "multi-month July tx archive"
assert_equal "2678400" "$archived_seconds" "multi-month July duration"
assert_equal "2026-08" "$STATE_MONTH" "multi-month current month"
assert_equal "36000000000" "$MONTH_RX" "multi-month August rx"
assert_equal "18000000000" "$MONTH_TX" "multi-month August tx"
assert_equal "3600" "$MONTH_SECONDS" "multi-month August duration"

empty_month_archive="${DATA_DIR}/month-2025-01.tsv"
rm -f -- "$empty_month_archive"
STATE_MONTH="2025-01"; MONTH_RX=0; MONTH_TX=0; MONTH_CPU_BUSY=0; MONTH_CPU_TOTAL=0; MONTH_SECONDS=0
archive_current_month
[[ ! -e "$empty_month_archive" ]] \
    || { printf 'FAIL: empty month created a false zero archive\n' >&2; exit 1; }

STATE_MONTH="2026-05"
MONTH_RX=100; MONTH_TX=200; MONTH_CPU_BUSY=10; MONTH_CPU_TOTAL=50; MONTH_SECONDS=60
STATE_WEEK="2026-W22"
WEEK_RX=100; WEEK_TX=200; WEEK_SECONDS=60
LAST_TS="$(date -d '2026-05-31 23:55:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-06-01 00:05:00 UTC' +%s)"
add_month_delta 2026-06 600 6000 8000 300 600
add_week_delta 2026-W23 600 6000 8000
read -r archived_rx archived_tx _ _ archived_seconds < "${DATA_DIR}/month-2026-05.tsv"
assert_equal "3100" "$archived_rx" "month-and-week boundary monthly rx"
assert_equal "4200" "$archived_tx" "month-and-week boundary monthly tx"
assert_equal "360" "$archived_seconds" "month-and-week boundary monthly duration"
read -r archived_rx archived_tx archived_seconds < "${DATA_DIR}/week-2026-W22.tsv"
assert_equal "3100" "$archived_rx" "month-and-week boundary weekly rx"
assert_equal "4200" "$archived_tx" "month-and-week boundary weekly tx"
assert_equal "360" "$archived_seconds" "month-and-week boundary weekly duration"
assert_equal "2026-W23" "$STATE_WEEK" "new week selected"
assert_equal "3000" "$WEEK_RX" "new week rx split"
assert_equal "4000" "$WEEK_TX" "new week tx split"
assert_equal "300" "$WEEK_SECONDS" "new week duration split"

STATE_WEEK=""
WEEK_RX=0; WEEK_TX=0; WEEK_SECONDS=0
LAST_TS="$(date -d '2026-08-09 23:55:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-08-10 00:05:00 UTC' +%s)"
add_week_delta 2026-W33 600 6000 8000
read -r archived_rx archived_tx archived_seconds < "${DATA_DIR}/week-2026-W32.tsv"
assert_equal "3000" "$archived_rx" "first partial week archived rx"
assert_equal "4000" "$archived_tx" "first partial week archived tx"
assert_equal "300" "$archived_seconds" "first partial week duration"
assert_equal "2026-W33" "$STATE_WEEK" "first partial week rolls forward"
assert_equal "3000" "$WEEK_RX" "first current week rx"
assert_equal "4000" "$WEEK_TX" "first current week tx"

STATE_WEEK="2026-W53"
WEEK_RX=0; WEEK_TX=0; WEEK_SECONDS=0
LAST_TS="$(date -d '2027-01-03 23:00:00 UTC' +%s)"
CURRENT_TS="$(date -d '2027-01-04 01:00:00 UTC' +%s)"
add_week_delta 2027-W01 7200 72000 36000
read -r archived_rx archived_tx archived_seconds < "${DATA_DIR}/week-2026-W53.tsv"
assert_equal "36000" "$archived_rx" "ISO year boundary previous week rx"
assert_equal "18000" "$archived_tx" "ISO year boundary previous week tx"
assert_equal "3600" "$archived_seconds" "ISO year boundary previous week duration"
assert_equal "2027-W01" "$STATE_WEEK" "ISO year boundary current week"
assert_equal "36000" "$WEEK_RX" "ISO year boundary current rx"
assert_equal "18000" "$WEEK_TX" "ISO year boundary current tx"

STATE_WEEK="2026-W31"
WEEK_RX=0; WEEK_TX=0; WEEK_SECONDS=0
LAST_TS="$(date -d '2026-08-02 23:00:00 UTC' +%s)"
CURRENT_TS="$(date -d '2026-08-17 01:00:00 UTC' +%s)"
multi_week_elapsed=$((CURRENT_TS - LAST_TS))
multi_week_rx=$((multi_week_elapsed * 10000000))
multi_week_tx=$((multi_week_elapsed * 5000000))
add_week_delta 2026-W34 "$multi_week_elapsed" "$multi_week_rx" "$multi_week_tx"
read -r archived_rx archived_tx archived_seconds < "${DATA_DIR}/week-2026-W31.tsv"
assert_equal "36000000000" "$archived_rx" "multi-week first rx without overflow"
assert_equal "18000000000" "$archived_tx" "multi-week first tx without overflow"
assert_equal "3600" "$archived_seconds" "multi-week first duration"
for archived_week in 2026-W32 2026-W33; do
    read -r archived_rx archived_tx archived_seconds < "${DATA_DIR}/week-${archived_week}.tsv"
    assert_equal "6048000000000" "$archived_rx" "multi-week full rx ${archived_week}"
    assert_equal "3024000000000" "$archived_tx" "multi-week full tx ${archived_week}"
    assert_equal "604800" "$archived_seconds" "multi-week full duration ${archived_week}"
done
assert_equal "2026-W34" "$STATE_WEEK" "multi-week current week"
assert_equal "36000000000" "$WEEK_RX" "multi-week current rx"
assert_equal "18000000000" "$WEEK_TX" "multi-week current tx"
assert_equal "3600" "$WEEK_SECONDS" "multi-week current duration"
save_state
STATE_WEEK=""; WEEK_RX=0; WEEK_TX=0; WEEK_SECONDS=0
load_state
assert_equal "2026-W34" "$STATE_WEEK" "weekly state survives reload"
assert_equal "36000000000" "$WEEK_RX" "weekly rx survives reload"
assert_equal "18000000000" "$WEEK_TX" "weekly tx survives reload"
assert_equal "3600" "$WEEK_SECONDS" "weekly duration survives reload"

empty_week_archive="${DATA_DIR}/week-2025-W01.tsv"
rm -f -- "$empty_week_archive"
STATE_WEEK="2025-W01"; WEEK_RX=0; WEEK_TX=0; WEEK_SECONDS=0
archive_current_week
[[ ! -e "$empty_week_archive" ]] \
    || { printf 'FAIL: empty week created a false zero archive\n' >&2; exit 1; }

weekly_queue="${TEST_DIR}/weekly-queue"
mkdir -p "$weekly_queue"
DATA_DIR="$weekly_queue"
printf '1\t2\t60\n' > "${DATA_DIR}/week-2020-W02.tsv"
printf '1\t2\t60\n' > "${DATA_DIR}/week-2020-W01.tsv"
assert_equal "2020-W01" "$(oldest_unsent_week)" "oldest weekly report is retried first"
: > "${DATA_DIR}/sent-week-2020-W01"
assert_equal "2020-W02" "$(oldest_unsent_week)" "weekly queue advances after marker"

test_weekly_delivery() (
    DATA_DIR="${TEST_DIR}/weekly-delivery"
    mkdir -p "$DATA_DIR"
    printf '120000000000\t80000000000\t3600\n' > "${DATA_DIR}/week-2020-W01.tsv"
    # shellcheck disable=SC2317,SC2329 # Called by the sourced weekly command.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced weekly command.
    acquire_lock() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced weekly command.
    collect_locked() { :; }
    # shellcheck disable=SC2317,SC2329 # Captures weekly Telegram delivery.
    send_message() {
        printf '%s' "$1" > "${DATA_DIR}/captured-message"
        printf 'sent\n' >> "${DATA_DIR}/send-count"
    }

    assert_equal "weekly: sent" "$(run_weekly)" "weekly report delivery"
    [[ -e "${DATA_DIR}/sent-week-2020-W01" ]] \
        || { printf 'FAIL: successful weekly report did not create marker\n' >&2; exit 1; }
    assert_equal "$expected_week" "$(<"${DATA_DIR}/captured-message")" "weekly delivered message"
    assert_equal "weekly: nothing-pending" "$(run_weekly)" "weekly duplicate prevention"
    assert_equal "1" "$(wc -l < "${DATA_DIR}/send-count")" "weekly send count"
)
(test_weekly_delivery)

monthly_queue="${TEST_DIR}/monthly-queue"
mkdir -p "$monthly_queue"
DATA_DIR="$monthly_queue"
queue_current="$(date +%Y-%m)"
queue_recent="$(date -d "${queue_current}-01 -1 month" +%Y-%m)"
queue_oldest="$(date -d "${queue_current}-01 -2 months" +%Y-%m)"
: > "${DATA_DIR}/month-${queue_recent}.tsv"
: > "${DATA_DIR}/month-${queue_oldest}.tsv"
assert_equal "$queue_oldest" "$(oldest_unsent_month)" "oldest monthly report is retried first"
: > "${DATA_DIR}/sent-${queue_oldest}"
assert_equal "$queue_recent" "$(oldest_unsent_month)" "monthly queue advances after marker"

trend_dir="${TEST_DIR}/weekly-trend"
mkdir -p "$trend_dir"
DATA_DIR="$trend_dir"
printf '60000000000\t40000000000\t604800\n' > "${DATA_DIR}/week-2026-W32.tsv"
assert_equal "+100.0%" "$(calculate_week_trend 2026-W33 120000000000 80000000000)" "weekly trend"
trend_message="$(format_week_message 120000000000 80000000000 '+100.0%')"
grep -Fqx '较前一周: +100.0%' <<< "$trend_message"
DATA_DIR="$TEST_DIR"
STATE_FILE="${DATA_DIR}/state.tsv"
SAMPLES_FILE="${DATA_DIR}/samples.tsv"

SYSTEMD_DIR="${TEST_DIR}/systemd"
BIN_PATH="/bin/true"
install_systemd_units
grep -Fxq 'OnCalendar=*-*-* 0/2:00:00' "${SYSTEMD_DIR}/vps-monitor-report.timer"
grep -Fxq 'Persistent=true' "${SYSTEMD_DIR}/vps-monitor-report.timer"
grep -Fxq 'OnBootSec=10s' "${SYSTEMD_DIR}/vps-monitor-collect.timer"
grep -Fxq 'StandardOutput=null' "${SYSTEMD_DIR}/vps-monitor-collect.service"
grep -Fxq 'StandardError=journal' "${SYSTEMD_DIR}/vps-monitor-collect.service"
grep -Fxq 'OnCalendar=Mon *-*-* 12:00:00' "${SYSTEMD_DIR}/vps-monitor-weekly.timer"
grep -Fxq 'Persistent=true' "${SYSTEMD_DIR}/vps-monitor-weekly.timer"
grep -Fxq 'ExecStart=/bin/true weekly' "${SYSTEMD_DIR}/vps-monitor-weekly.service"
grep -Fxq 'NoNewPrivileges=yes' "${SYSTEMD_DIR}/vps-monitor-weekly.service"
grep -Fxq 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "${SYSTEMD_DIR}/vps-monitor-weekly.service"
grep -Fxq 'OnCalendar=*-*-* 00:05:00' "${SYSTEMD_DIR}/vps-monitor-monthly.timer"
grep -Fxq 'ExecStart=/bin/true boot-alert' "${SYSTEMD_DIR}/vps-monitor-boot.service"
grep -Fxq 'WantedBy=multi-user.target' "${SYSTEMD_DIR}/vps-monitor-boot.service"
grep -Fxq 'Restart=on-failure' "${SYSTEMD_DIR}/vps-monitor-boot.service"
grep -Fxq 'ExecStart=/bin/true auto-update' "${SYSTEMD_DIR}/vps-monitor-auto-update.service"
grep -Fxq 'OnCalendar=*-*-* 04:15:00' "${SYSTEMD_DIR}/vps-monitor-auto-update.timer"
grep -Fxq 'RandomizedDelaySec=30min' "${SYSTEMD_DIR}/vps-monitor-auto-update.timer"
grep -Fxq 'Persistent=true' "${SYSTEMD_DIR}/vps-monitor-auto-update.timer"
grep -Fxq 'ProtectSystem=strict' "${SYSTEMD_DIR}/vps-monitor-auto-update.service"
if grep -Eq '^(User|Group)=' "${SYSTEMD_DIR}/vps-monitor-auto-update.service"; then
    printf 'FAIL: automatic updater is not running as root\n' >&2
    exit 1
fi
grep -Fxq 'ExecStart=/bin/true command-poll' "${SYSTEMD_DIR}/vps-monitor-command.service"
grep -Fxq 'OnBootSec=1min' "${SYSTEMD_DIR}/vps-monitor-command.timer"
grep -Fxq 'OnUnitActiveSec=1min' "${SYSTEMD_DIR}/vps-monitor-command.timer"
grep -Fxq 'NoNewPrivileges=yes' "${SYSTEMD_DIR}/vps-monitor-command.service"
grep -Fxq 'ProtectSystem=strict' "${SYSTEMD_DIR}/vps-monitor-command.service"
grep -Fxq 'CapabilityBoundingSet=CAP_SYS_BOOT' "${SYSTEMD_DIR}/vps-monitor-command.service"
grep -Fxq "ReadWritePaths=${CONFIG_DIR} /run/lock" "${SYSTEMD_DIR}/vps-monitor-command.service"
if grep -Eq '^(User|Group)=' "${SYSTEMD_DIR}/vps-monitor-command.service"; then
    printf 'FAIL: Telegram reboot command service is not running as root\n' >&2
    exit 1
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer
fi

(
    SYSTEMD_DIR="${TEST_DIR}/failed-v162-apply"
    APPLY_UPDATE_WEEKLY_SERVICE_EXISTED=0
    APPLY_UPDATE_WEEKLY_TIMER_EXISTED=0
    APPLY_UPDATE_BOOT_SERVICE_EXISTED=0
    APPLY_UPDATE_AUTO_SERVICE_EXISTED=0
    APPLY_UPDATE_AUTO_TIMER_EXISTED=0
    APPLY_UPDATE_COMMAND_SERVICE_EXISTED=0
    APPLY_UPDATE_COMMAND_TIMER_EXISTED=0
    APPLY_UPDATE_MANAGED_MARKER_EXISTED=0
    mkdir -p "$SYSTEMD_DIR"
    : > "${SYSTEMD_DIR}/vps-monitor-weekly.service"
    : > "${SYSTEMD_DIR}/vps-monitor-weekly.timer"
    : > "${SYSTEMD_DIR}/vps-monitor-boot.service"
    : > "${SYSTEMD_DIR}/vps-monitor-auto-update.service"
    : > "${SYSTEMD_DIR}/vps-monitor-auto-update.timer"
    : > "${SYSTEMD_DIR}/vps-monitor-command.service"
    : > "${SYSTEMD_DIR}/vps-monitor-command.timer"
    MANAGED_MARKER_PATH="${SYSTEMD_DIR}/managed-marker"
    : > "$MANAGED_MARKER_PATH"
    # shellcheck disable=SC2317,SC2329 # Called by failed apply cleanup.
    systemctl() { return 0; }
    cleanup_failed_apply_units
    for unit_name in vps-monitor-weekly.{service,timer} vps-monitor-boot.service \
        vps-monitor-auto-update.{service,timer} vps-monitor-command.{service,timer}; do
        [[ ! -e "${SYSTEMD_DIR}/${unit_name}" ]] \
            || { printf 'FAIL: v1.6.2 failed apply left %s\n' "$unit_name" >&2; exit 1; }
    done
    [[ ! -e "$MANAGED_MARKER_PATH" ]] \
        || { printf 'FAIL: failed apply left managed marker\n' >&2; exit 1; }
)

(
    ROLLBACK_ROOT="${TEST_DIR}/failed-install"
    SYSTEMD_DIR="${ROLLBACK_ROOT}/systemd"
    BIN_PATH="${ROLLBACK_ROOT}/bin/vps-monitor"
    INSTALL_DIR="${ROLLBACK_ROOT}/lib/vps-monitor"
    CONFIG_DIR="${ROLLBACK_ROOT}/etc/vps-monitor"
    DATA_DIR="${ROLLBACK_ROOT}/var/vps-monitor"
    PAM_SSHD_FILE="${ROLLBACK_ROOT}/pam-sshd"
    UPDATE_LOCK_FILE="${ROLLBACK_ROOT}/update.lock"
    INSTALL_CREATED_SERVICE_ACCOUNT=1
    INSTALL_CREATED_SERVICE_GROUP=1
    mkdir -p "$SYSTEMD_DIR" "$(dirname -- "$BIN_PATH")" "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
    : > "$BIN_PATH"; : > "$PAM_SSHD_FILE"; : > "$UPDATE_LOCK_FILE"
    : > "${SYSTEMD_DIR}/vps-monitor-command.service"
    : > "${SYSTEMD_DIR}/vps-monitor-command.timer"
    ensure_pam_login_line
    # shellcheck disable=SC2317,SC2329 # Called by failed install cleanup.
    systemctl() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Records account cleanup without touching the runner.
    userdel() { : > "${ROLLBACK_ROOT}/user-removed"; }
    # shellcheck disable=SC2317,SC2329 # Records group cleanup without touching the runner.
    groupdel() { : > "${ROLLBACK_ROOT}/group-removed"; }
    cleanup_failed_install
    for removed_path in "$BIN_PATH" "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$UPDATE_LOCK_FILE"; do
        [[ ! -e "$removed_path" && ! -L "$removed_path" ]] \
            || { printf 'FAIL: failed install rollback left %s\n' "$removed_path" >&2; exit 1; }
    done
    [[ ! -e "${SYSTEMD_DIR}/vps-monitor-command.service" \
        && ! -e "${SYSTEMD_DIR}/vps-monitor-command.timer" ]] \
        || { printf 'FAIL: failed install rollback left Telegram command units\n' >&2; exit 1; }
    [[ -e "${ROLLBACK_ROOT}/user-removed" && -e "${ROLLBACK_ROOT}/group-removed" ]] \
        || { printf 'FAIL: failed install rollback left service account\n' >&2; exit 1; }
    grep -Fqx "$(pam_login_line)" "$PAM_SSHD_FILE" \
        && { printf 'FAIL: failed install rollback left PAM line\n' >&2; exit 1; }
    true
)

if ! (
    # shellcheck disable=SC2317,SC2329 # Called by the sourced account ownership check.
    getent() {
        case "${1}:${2}" in
            passwd:vpsmonitor) printf 'vpsmonitor:x:999:999::%s:/usr/sbin/nologin\n' "$DATA_DIR" ;;
            group:vpsmonitor) printf 'vpsmonitor:x:999:\n' ;;
            *) return 2 ;;
        esac
    }
    is_managed_service_account
); then
    printf 'FAIL: managed service account was not recognized\n' >&2
    exit 1
fi

if (
    # shellcheck disable=SC2317,SC2329 # Called by the sourced account ownership check.
    getent() {
        case "${1}:${2}" in
            passwd:vpsmonitor) printf 'vpsmonitor:x:999:999::/srv/existing-service:/usr/sbin/nologin\n' ;;
            group:vpsmonitor) printf 'vpsmonitor:x:999:\n' ;;
            *) return 2 ;;
        esac
    }
    is_managed_service_account
); then
    printf 'FAIL: unrelated system account was treated as managed\n' >&2
    exit 1
fi

(
    UPDATE_ROOT="${TEST_DIR}/update-rollback"
    SCRIPT_PATH="${UPDATE_ROOT}/installed.sh"
    BIN_PATH="${UPDATE_ROOT}/bin/vps-monitor"
    INSTALL_DIR="${UPDATE_ROOT}/lib"
    LOGIN_HOOK_PATH="${INSTALL_DIR}/login-alert-hook"
    SYSTEMD_DIR="${UPDATE_ROOT}/systemd"
    UPDATE_LOCK_FILE="${UPDATE_ROOT}/update.lock"
    PAM_SSHD_FILE="${UPDATE_ROOT}/pam-sshd"
    candidate="${UPDATE_ROOT}/candidate.sh"
    mkdir -p "$(dirname -- "$BIN_PATH")" "$INSTALL_DIR" "$SYSTEMD_DIR"
    printf '#!/usr/bin/env bash\n# VPS_TELEGRAM_MONITOR_SCRIPT=1\nVERSION="1.5.1"\nexit 0\n' > "$SCRIPT_PATH"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$LOGIN_HOOK_PATH"
    printf '#!/usr/bin/env bash\n# VPS_TELEGRAM_MONITOR_SCRIPT=1\nVERSION="1.5.2"\nexit 1\n' > "$candidate"
    chmod 0700 "$SCRIPT_PATH" "$LOGIN_HOOK_PATH" "$candidate"
    : > "$PAM_SSHD_FILE"
    for unit_name in vps-monitor-{collect,report,monthly}.{service,timer}; do
        printf 'old unit %s\n' "$unit_name" > "${SYSTEMD_DIR}/${unit_name}"
    done

    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    verify_supported_os() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    ensure_dependencies() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    is_managed_service_account() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    download_verified_main() { command cp -- "$candidate" "$1"; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    flock() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    systemctl() { [[ "${1:-}" != is-active ]]; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    ln() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    install() {
        while (( $# > 2 )); do
            case "$1" in
                -o|-g|-m) shift 2 ;;
                --) shift; break ;;
                *) break ;;
            esac
        done
        command cp -- "$1" "$2"
        command chmod 0700 "$2"
    }

    if (run_update) > "${UPDATE_ROOT}/update-output.log" 2>&1; then
        printf 'FAIL: failed update was reported as successful\n' >&2
        exit 1
    fi
    if [[ "$(script_version "$SCRIPT_PATH")" != 1.5.1 ]]; then
        cat "${UPDATE_ROOT}/update-output.log" >&2
        printf 'FAIL: failed update script rollback\n' >&2
        exit 1
    fi
    for unit_name in vps-monitor-{collect,report,monthly}.{service,timer}; do
        grep -Fqx "old unit ${unit_name}" "${SYSTEMD_DIR}/${unit_name}" \
            || { printf 'FAIL: failed update did not restore %s\n' "$unit_name" >&2; exit 1; }
    done
    for unit_name in vps-monitor-weekly.{service,timer} vps-monitor-boot.service \
        vps-monitor-auto-update.{service,timer} vps-monitor-command.{service,timer}; do
        [[ ! -e "${SYSTEMD_DIR}/${unit_name}" ]] \
            || { printf 'FAIL: failed pre-weekly update left %s\n' "$unit_name" >&2; exit 1; }
    done
)

(
    REPAIR_ROOT="${TEST_DIR}/same-version-repair"
    SCRIPT_PATH="${REPAIR_ROOT}/installed.sh"
    BIN_PATH="${REPAIR_ROOT}/bin/vps-monitor"
    INSTALL_DIR="${REPAIR_ROOT}/lib"
    LOGIN_HOOK_PATH="${INSTALL_DIR}/login-alert-hook"
    SYSTEMD_DIR="${REPAIR_ROOT}/systemd"
    UPDATE_LOCK_FILE="${REPAIR_ROOT}/update.lock"
    PAM_SSHD_FILE="${REPAIR_ROOT}/pam-sshd"
    candidate="${REPAIR_ROOT}/candidate.sh"
    export REPAIR_HOOK="$LOGIN_HOOK_PATH"
    mkdir -p "$(dirname -- "$BIN_PATH")" "$INSTALL_DIR" "$SYSTEMD_DIR"
    # shellcheck disable=SC2016 # The generated candidate expands these values when it runs.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# VPS_TELEGRAM_MONITOR_SCRIPT=1' \
        'VERSION="1.10.0"' \
        'if [[ "${1:-}" == "__apply-update" ]]; then : > "$REPAIR_HOOK"; fi' > "$candidate"
    cp -- "$candidate" "$SCRIPT_PATH"
    chmod 0700 "$SCRIPT_PATH" "$candidate"
    : > "$PAM_SSHD_FILE"

    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    verify_supported_os() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    ensure_dependencies() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    is_managed_service_account() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    download_verified_main() { command cp -- "$candidate" "$1"; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    flock() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    systemctl() { [[ "${1:-}" != is-active ]]; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    ln() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced updater.
    install() {
        while (( $# > 2 )); do
            case "$1" in
                -o|-g|-m) shift 2 ;;
                --) shift; break ;;
                *) break ;;
            esac
        done
        command cp -- "$1" "$2"
        command chmod 0700 "$2"
    }

    run_update >/dev/null
    [[ -f "$LOGIN_HOOK_PATH" ]] \
        || { printf 'FAIL: same-version update did not repair a missing login hook\n' >&2; exit 1; }
)

(
    AUTO_ROOT="${TEST_DIR}/automatic-same-version"
    SCRIPT_PATH="${AUTO_ROOT}/installed.sh"
    UPDATE_LOCK_FILE="${AUTO_ROOT}/update.lock"
    candidate="${AUTO_ROOT}/candidate.sh"
    mkdir -p "$AUTO_ROOT"
    printf '#!/usr/bin/env bash\n# VPS_TELEGRAM_MONITOR_SCRIPT=1\nVERSION="1.10.0"\n' > "$SCRIPT_PATH"
    cp -- "$SCRIPT_PATH" "$candidate"
    chmod 0700 "$SCRIPT_PATH" "$candidate"

    # shellcheck disable=SC2317,SC2329 # Called by the automatic updater.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the automatic updater.
    verify_supported_os() { :; }
    # shellcheck disable=SC2317,SC2329 # Confirms unattended updates never invoke apt repair.
    dependencies_ready() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Must not be called in automatic mode.
    ensure_dependencies() { : > "${AUTO_ROOT}/unexpected-dependency-repair"; }
    # shellcheck disable=SC2317,SC2329 # Called by the automatic updater.
    is_managed_service_account() { return 0; }
    # shellcheck disable=SC2317,SC2329 # Called by the automatic updater.
    load_config() { :; }
    # shellcheck disable=SC2317,SC2329 # Supplies the same verified version.
    download_verified_main() { command cp -- "$candidate" "$1"; }
    # shellcheck disable=SC2317,SC2329 # Called by the automatic updater.
    flock() { return 0; }

    auto_output="$(run_update automatic)"
    grep -Fq '未重复安装' <<< "$auto_output"
    [[ ! -e "${AUTO_ROOT}/unexpected-dependency-repair" ]] \
        || { printf 'FAIL: automatic update tried to install dependencies\n' >&2; exit 1; }
)

(
    DOCTOR_ROOT="${TEST_DIR}/doctor"
    UPDATE_LOCK_FILE="${DOCTOR_ROOT}/update.lock"
    CONFIG_DIR="${DOCTOR_ROOT}/etc"
    DATA_DIR="${DOCTOR_ROOT}/data"
    SCRIPT_PATH="${DOCTOR_ROOT}/installed.sh"
    BIN_PATH="${DOCTOR_ROOT}/bin/vps-monitor"
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$(dirname -- "$BIN_PATH")"
    : > "$SCRIPT_PATH"
    # shellcheck disable=SC2317,SC2329 # Doctor orchestration test stubs privileged operations.
    require_root() { :; }
    verify_supported_os() { :; }
    ensure_dependencies() { :; }
    installed_script_is_managed() { return 0; }
    ensure_service_account_for_doctor() { :; }
    load_and_repair_config_for_doctor() { TOKEN=x; CHAT_ID=1; SERVER_NAME=测试服务器; INTERFACE=eth0; }
    ensure_bin_link() { :; }
    install_managed_marker() { :; }
    initialize_command_offset() { : > "${DOCTOR_ROOT}/command-offset-repaired"; }
    install_systemd_units() { : > "${DOCTOR_ROOT}/units-repaired"; }
    install_login_alert_hook() { : > "${DOCTOR_ROOT}/pam-repaired"; }
    run_status() { printf 'doctor-status-ok\n'; }
    flock() { return 0; }
    install() { return 0; }
    chown() { return 0; }
    chmod() { return 0; }
    systemctl() { [[ "${1:-}" != is-active ]]; }
    runuser() { printf '%s\n' "$*" >> "${DOCTOR_ROOT}/runuser-calls"; }
    doctor_output="$(doctor_app)"
    grep -Fq '[完成] 自检和一键修复完成' <<< "$doctor_output"
    grep -Fq ' collect' "${DOCTOR_ROOT}/runuser-calls"
    grep -Fq ' init-boot-alert' "${DOCTOR_ROOT}/runuser-calls"
    grep -Fq ' doctor-notify' "${DOCTOR_ROOT}/runuser-calls"
    [[ -e "${DOCTOR_ROOT}/units-repaired" && -e "${DOCTOR_ROOT}/pam-repaired" \
        && -e "${DOCTOR_ROOT}/command-offset-repaired" ]] \
        || { printf 'FAIL: doctor did not rebuild managed resources\n' >&2; exit 1; }
)

(
    UNINSTALL_ROOT="${TEST_DIR}/uninstall"
    SYSTEMD_DIR="${UNINSTALL_ROOT}/systemd"
    BIN_PATH="${UNINSTALL_ROOT}/bin/vps-monitor"
    INSTALL_DIR="${UNINSTALL_ROOT}/lib/vps-monitor"
    SCRIPT_PATH="${INSTALL_DIR}/TG-check-notify.sh"
    CONFIG_DIR="${UNINSTALL_ROOT}/etc/vps-monitor"
    DATA_DIR="${UNINSTALL_ROOT}/var/vps-monitor"
    LOGIN_HOOK_PATH="${INSTALL_DIR}/login-alert-hook"
    PAM_SSHD_FILE="${UNINSTALL_ROOT}/pam-sshd"
    UPDATE_LOCK_FILE="${UNINSTALL_ROOT}/vps-monitor-update.lock"

    # shellcheck disable=SC2317,SC2329 # Called by the sourced uninstaller.
    require_root() { :; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced uninstaller.
    getent() { return 2; }
    # shellcheck disable=SC2317,SC2329 # Called by the sourced uninstaller.
    systemctl() {
        case "${1:-}" in
            disable)
                rm -f -- "${SYSTEMD_DIR}/timers.target.wants"/vps-monitor-*.timer
                return 0
                ;;
            is-active|is-enabled) return 1 ;;
            list-units) return 0 ;;
            *) return 0 ;;
        esac
    }

    mkdir -p "$SYSTEMD_DIR/timers.target.wants" "$(dirname -- "$BIN_PATH")" \
        "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"
    printf '#!/usr/bin/env bash\n# VPS_TELEGRAM_MONITOR_SCRIPT=1\nVERSION="1.10.0"\n' > "$SCRIPT_PATH"
    : > "$LOGIN_HOOK_PATH"; : > "$PAM_SSHD_FILE"; : > "$UPDATE_LOCK_FILE"
    ensure_pam_login_line
    for unit_name in vps-monitor-{collect,report,weekly,monthly,auto-update,command}.{service,timer}; do
        : > "${SYSTEMD_DIR}/${unit_name}"
    done
    : > "${SYSTEMD_DIR}/vps-monitor-boot.service"
    for timer_name in vps-monitor-{collect,report,weekly,monthly,auto-update,command}.timer; do
        : > "${SYSTEMD_DIR}/timers.target.wants/${timer_name}"
    done

    if ! (uninstall_app) > "${UNINSTALL_ROOT}/uninstall-output.log" 2>&1; then
        cat "${UNINSTALL_ROOT}/uninstall-output.log" >&2
        printf 'FAIL: uninstall command failed\n' >&2
        exit 1
    fi
    for removed_path in "$BIN_PATH" "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR"; do
        [[ ! -e "$removed_path" && ! -L "$removed_path" ]] \
            || { printf 'FAIL: uninstall left %s\n' "$removed_path" >&2; exit 1; }
    done
    [[ ! -e "$UPDATE_LOCK_FILE" ]] || { printf 'FAIL: uninstall left update lock\n' >&2; exit 1; }
    if grep -Fqx "$PAM_MARKER" "$PAM_SSHD_FILE" || grep -Fqx "$(pam_login_line)" "$PAM_SSHD_FILE"; then
        printf 'FAIL: uninstall left PAM configuration\n' >&2
        exit 1
    fi
)

(
    DATA_DIR="${TEST_DIR}/silent-collector"
    STATE_FILE="${DATA_DIR}/state.tsv"
    SAMPLES_FILE="${DATA_DIR}/samples.tsv"
    mkdir -p "$DATA_DIR"
    INTERFACE=eth0
    read_counters() {
        CURRENT_BOOT=01234567-89ab-cdef-0123-456789abcdef
        if [[ -f "$STATE_FILE" ]]; then
            CURRENT_TS=1060; CURRENT_RX=7000; CURRENT_TX=4000
            CURRENT_CPU_BUSY=50; CURRENT_CPU_TOTAL=200
        else
            CURRENT_TS=1000; CURRENT_RX=1000; CURRENT_TX=1000
            CURRENT_CPU_BUSY=25; CURRENT_CPU_TOTAL=100
        fi
    }
    assert_equal "" "$(collect_locked)" "baseline collector output"
    assert_equal "" "$(collect_locked)" "routine collector output"
)

printf 'All lightweight tests passed.\n'
