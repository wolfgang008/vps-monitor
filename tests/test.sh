#!/usr/bin/env bash
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

is_telegram_uid "123456789" || { printf 'FAIL: valid Telegram UID rejected\n' >&2; exit 1; }
if is_telegram_uid "@example" || is_telegram_uid "012345" || is_telegram_uid "-100123"; then
    printf 'FAIL: invalid Telegram UID accepted\n' >&2
    exit 1
fi

expected_two_hour=$'测试服务器\n进站速度: 10.15 MB/s\n出站速度: 10.07 MB/s\n总流量: 2.51 TB\nCPU利用率: 29%'
actual_two_hour="$(format_two_hour_message 76629934080 76025954304 29 100 2759774185718)"
assert_equal "$expected_two_hour" "$actual_two_hour" "two-hour message format"

expected_month=$'测试服务器 2026年8月流量报告\n进站流量: 1.42 TB\n出站流量: 1.09 TB\n总流量: 2.51 TB\n平均CPU利用率: 29%'
actual_month="$(format_month_message 2026-08 1561306511442 1198467674276 29 100)"
assert_equal "$expected_month" "$actual_month" "monthly message format"

login_epoch="$(date -d '2026-08-05 12:34:56 UTC' +%s)"
login_time="$(date -d "@${login_epoch}" '+%F %T %Z')"
expected_login="$(printf '⚠️ VPS 登录提醒\n服务器: 测试服务器\n登录用户: root\n来源IP: 203.0.113.8\n登录时间: %s' "$login_time")"
actual_login="$(format_login_message root 203.0.113.8 "$login_epoch")"
assert_equal "$expected_login" "$actual_login" "SSH login alert format"

(
    load_config() { :; }
    acquire_lock() { :; }
    send_message() { printf '%s' "$1" > "${TEST_DIR}/captured-login-alert"; }
    VPS_LOGIN_USER=root VPS_LOGIN_IP=203.0.113.8 run_login_alert >/dev/null
)
login_prefix=$'⚠️ VPS 登录提醒\n服务器: 测试服务器\n登录用户: root\n来源IP: 203.0.113.8\n登录时间: '
[[ "$(<"${TEST_DIR}/captured-login-alert")" == "${login_prefix}"* ]] \
    || { printf 'FAIL: SSH login alert delivery\n' >&2; exit 1; }

render_login_hook > "${TEST_DIR}/login-alert-hook"
sh -n "${TEST_DIR}/login-alert-hook"
grep -Fq -- '--no-block' "${TEST_DIR}/login-alert-hook"
grep -Fq -- "VPS_LOGIN_IP=\$PAM_RHOST" "${TEST_DIR}/login-alert-hook"

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

printf '1000\t1060\t6000\t3000\t25\t100\n' > "$SAMPLES_FILE"
read -r rx tx busy total coverage <<< "$(calculate_window 1060)"
assert_equal "6000.000000" "$rx" "window rx"
assert_equal "3000.000000" "$tx" "window tx"
assert_equal "25.000000" "$busy" "window busy"
assert_equal "100.000000" "$total" "window total"
assert_equal "60.000000" "$coverage" "window coverage"

pwned="${TEST_DIR}/pwned"
# shellcheck disable=SC2016 # Literal payload verifies that state is never executed.
printf 'month_rx\t$(touch %s)\nmonth_tx\t42\n' "$pwned" > "$STATE_FILE"
load_state
assert_equal "0" "$MONTH_RX" "invalid state rejected"
assert_equal "42" "$MONTH_TX" "valid state accepted"
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

SYSTEMD_DIR="${TEST_DIR}/systemd"
BIN_PATH="/bin/true"
install_systemd_units
grep -Fxq 'OnCalendar=*-*-* 0/2:00:00' "${SYSTEMD_DIR}/vps-monitor-report.timer"
grep -Fxq 'Persistent=true' "${SYSTEMD_DIR}/vps-monitor-report.timer"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/*.timer
fi

printf 'All lightweight tests passed.\n'
