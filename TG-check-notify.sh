#!/usr/bin/env bash
# VPS_TELEGRAM_MONITOR_SCRIPT=1
set -Eeuo pipefail
export LC_NUMERIC=C
umask 077

VERSION="1.6.1"
APP_NAME="vps-monitor"
SERVICE_USER="vpsmonitor"
INSTALL_DIR="/usr/local/lib/${APP_NAME}"
SCRIPT_PATH="${INSTALL_DIR}/TG-check-notify.sh"
BIN_PATH="/usr/local/bin/vps-monitor"
CONFIG_DIR="/etc/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
SYSTEMD_DIR="${VPS_MONITOR_SYSTEMD_DIR:-/etc/systemd/system}"
TOKEN_FILE="${CONFIG_DIR}/token"
CHAT_ID_FILE="${CONFIG_DIR}/chat_id"
SERVER_NAME_FILE="${CONFIG_DIR}/server_name"
INTERFACE_FILE="${CONFIG_DIR}/interface"
STATE_FILE="${DATA_DIR}/state.tsv"
SAMPLES_FILE="${DATA_DIR}/samples.tsv"
LOCK_FILE="${DATA_DIR}/monitor.lock"
UPDATE_LOCK_FILE="/run/lock/vps-monitor-update.lock"
LOGIN_HOOK_PATH="${INSTALL_DIR}/login-alert-hook"
PAM_SSHD_FILE="${VPS_MONITOR_PAM_SSHD_FILE:-/etc/pam.d/sshd}"
SSHD_BIN="${VPS_MONITOR_SSHD_BIN:-/usr/sbin/sshd}"
PAM_MARKER="# vps-monitor SSH login alert"
GITHUB_REPOSITORY="wolfgang008/vps-monitor"
GITHUB_BRANCH="main"
GITHUB_ARCHIVE_URL="https://codeload.github.com/${GITHUB_REPOSITORY}/tar.gz/refs/heads/${GITHUB_BRANCH}"
GITHUB_ARCHIVE_ROOT="${APP_NAME}-${GITHUB_BRANCH}"
TELEGRAM_ROOT="https://api.telegram.org"
WINDOW_SECONDS=7200
MIN_COVERAGE_SECONDS=6480
MAX_SAMPLE_SECONDS=900
SAMPLE_RETENTION_SECONDS=21600

TOKEN=""
CHAT_ID=""
SERVER_NAME=""
INTERFACE=""
LAST_TS=0
LAST_BOOT=""
LAST_INTERFACE=""
LAST_RX=0
LAST_TX=0
LAST_CPU_BUSY=0
LAST_CPU_TOTAL=0
STATE_MONTH=""
MONTH_RX=0
MONTH_TX=0
MONTH_CPU_BUSY=0
MONTH_CPU_TOTAL=0
MONTH_SECONDS=0
LAST_REPORT=0
WORK_DIR=""
UPDATE_TIMERS_STOPPED=0
PROPORTIONAL_RESULT=0

if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'; C_BLUE=$'\033[36m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fatal() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_telegram_uid() { [[ "${1:-}" =~ ^[1-9][0-9]{0,19}$ ]]; }

cleanup_work_dir() {
    if (( UPDATE_TIMERS_STOPPED == 1 )) && (( EUID == 0 )) && command -v systemctl >/dev/null; then
        systemctl enable --now vps-monitor-{collect,report,monthly}.timer >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

load_config() {
    [[ -r "$TOKEN_FILE" && -r "$CHAT_ID_FILE" && -r "$SERVER_NAME_FILE" && -r "$INTERFACE_FILE" ]] \
        || fatal "配置不完整，请重新运行一行安装命令。"
    TOKEN="$(<"$TOKEN_FILE")"
    CHAT_ID="$(<"$CHAT_ID_FILE")"
    SERVER_NAME="$(<"$SERVER_NAME_FILE")"
    INTERFACE="$(<"$INTERFACE_FILE")"
    [[ "$TOKEN" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] || fatal "Bot Token 配置格式无效。"
    is_telegram_uid "$CHAT_ID" || fatal "Telegram UID 配置格式无效。"
    [[ "$INTERFACE" =~ ^[A-Za-z0-9_.:@-]{1,64}$ ]] || fatal "网卡配置格式无效。"
    [[ -n "$SERVER_NAME" && ${#SERVER_NAME} -le 80 && "$SERVER_NAME" != *$'\n'* ]] \
        || fatal "服务器名称配置无效。"
}

reset_state_defaults() {
    LAST_TS=0; LAST_BOOT=""; LAST_INTERFACE=""; LAST_RX=0; LAST_TX=0
    LAST_CPU_BUSY=0; LAST_CPU_TOTAL=0; STATE_MONTH=""
    MONTH_RX=0; MONTH_TX=0; MONTH_CPU_BUSY=0; MONTH_CPU_TOTAL=0
    MONTH_SECONDS=0; LAST_REPORT=0
}

load_state() {
    reset_state_defaults
    [[ -r "$STATE_FILE" ]] || return 0
    local key value
    while IFS=$'\t' read -r key value || [[ -n "${key:-}" ]]; do
        case "$key" in
            last_ts) is_uint "$value" && LAST_TS="$value" ;;
            last_boot) [[ "$value" =~ ^[A-Fa-f0-9-]{16,64}$ ]] && LAST_BOOT="$value" ;;
            last_interface) [[ "$value" =~ ^[A-Za-z0-9_.:@-]{1,64}$ ]] && LAST_INTERFACE="$value" ;;
            last_rx) is_uint "$value" && LAST_RX="$value" ;;
            last_tx) is_uint "$value" && LAST_TX="$value" ;;
            last_cpu_busy) is_uint "$value" && LAST_CPU_BUSY="$value" ;;
            last_cpu_total) is_uint "$value" && LAST_CPU_TOTAL="$value" ;;
            month) [[ "$value" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] && STATE_MONTH="$value" ;;
            month_rx) is_uint "$value" && MONTH_RX="$value" ;;
            month_tx) is_uint "$value" && MONTH_TX="$value" ;;
            month_cpu_busy) is_uint "$value" && MONTH_CPU_BUSY="$value" ;;
            month_cpu_total) is_uint "$value" && MONTH_CPU_TOTAL="$value" ;;
            month_seconds) is_uint "$value" && MONTH_SECONDS="$value" ;;
            last_report) is_uint "$value" && LAST_REPORT="$value" ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    local temporary
    temporary="$(mktemp "${DATA_DIR}/state.XXXXXXXX")"
    printf '%s\t%s\n' \
        last_ts "$LAST_TS" \
        last_boot "$LAST_BOOT" \
        last_interface "$LAST_INTERFACE" \
        last_rx "$LAST_RX" \
        last_tx "$LAST_TX" \
        last_cpu_busy "$LAST_CPU_BUSY" \
        last_cpu_total "$LAST_CPU_TOTAL" \
        month "$STATE_MONTH" \
        month_rx "$MONTH_RX" \
        month_tx "$MONTH_TX" \
        month_cpu_busy "$MONTH_CPU_BUSY" \
        month_cpu_total "$MONTH_CPU_TOTAL" \
        month_seconds "$MONTH_SECONDS" \
        last_report "$LAST_REPORT" > "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$STATE_FILE"
}

monitored_interface_is_readable() {
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    [[ -r "$rx_path" && -r "$tx_path" ]]
}

read_counters() {
    local cpu_label user nice system idle iowait irq softirq steal _
    local rx_path="/sys/class/net/${INTERFACE}/statistics/rx_bytes"
    local tx_path="/sys/class/net/${INTERFACE}/statistics/tx_bytes"
    monitored_interface_is_readable || fatal "无法读取网卡 ${INTERFACE}，请重新安装以自动识别网卡。"
    CURRENT_RX="$(<"$rx_path")"
    CURRENT_TX="$(<"$tx_path")"
    read -r cpu_label user nice system idle iowait irq softirq steal _ < /proc/stat
    [[ "$cpu_label" == "cpu" ]] || fatal "无法读取 /proc/stat。"
    CURRENT_CPU_BUSY=$((user + nice + system + irq + softirq + steal))
    CURRENT_CPU_TOTAL=$((CURRENT_CPU_BUSY + idle + iowait))
    CURRENT_BOOT="$(< /proc/sys/kernel/random/boot_id)"
    CURRENT_TS="$(date +%s)"
    if ! is_uint "$CURRENT_RX" || ! is_uint "$CURRENT_TX"; then
        fatal "网卡计数器格式异常。"
    fi
}

archive_current_month() {
    [[ "$STATE_MONTH" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 0
    local archive="${DATA_DIR}/month-${STATE_MONTH}.tsv"
    local temporary
    temporary="$(mktemp "${DATA_DIR}/month.XXXXXXXX")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$MONTH_RX" "$MONTH_TX" "$MONTH_CPU_BUSY" "$MONTH_CPU_TOTAL" "$MONTH_SECONDS" > "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$archive"
}

roll_month_without_delta() {
    local current_month="$1"
    if [[ -n "$STATE_MONTH" && "$STATE_MONTH" != "$current_month" ]]; then
        archive_current_month
        STATE_MONTH="$current_month"
        MONTH_RX=0; MONTH_TX=0; MONTH_CPU_BUSY=0; MONTH_CPU_TOTAL=0; MONTH_SECONDS=0
    elif [[ -z "$STATE_MONTH" ]]; then
        STATE_MONTH="$current_month"
    fi
}

proportional_floor() {
    local value="$1" numerator="$2" denominator="$3"
    local quotient=$((value / denominator)) remainder=$((value % denominator))
    # Dividing before multiplying keeps realistic long-gap counter values
    # within Bash's signed 64-bit arithmetic range.
    PROPORTIONAL_RESULT=$((quotient * numerator + remainder * numerator / denominator))
}

add_month_delta() {
    local current_month="$1" elapsed="$2" rx_delta="$3" tx_delta="$4" busy_delta="$5" total_delta="$6"
    if [[ -z "$STATE_MONTH" || "$STATE_MONTH" == "$current_month" ]]; then
        STATE_MONTH="$current_month"
        MONTH_RX=$((MONTH_RX + rx_delta)); MONTH_TX=$((MONTH_TX + tx_delta))
        MONTH_CPU_BUSY=$((MONTH_CPU_BUSY + busy_delta)); MONTH_CPU_TOTAL=$((MONTH_CPU_TOTAL + total_delta))
        MONTH_SECONDS=$((MONTH_SECONDS + elapsed))
        return
    fi

    local cursor="$LAST_TS" segment_month segment_year segment_number next_year next_number next_month
    local boundary segment_end segment_seconds cumulative_seconds
    local cumulative_rx cumulative_tx cumulative_busy cumulative_total
    local allocated_rx=0 allocated_tx=0 allocated_busy=0 allocated_total=0
    local segment_rx segment_tx segment_busy segment_total
    while (( cursor < CURRENT_TS )); do
        segment_month="$(date -d "@${cursor}" +%Y-%m)" || fatal "无法计算跨月统计月份。"
        segment_year="${segment_month%-*}"; segment_number="${segment_month#*-}"
        next_year="$segment_year"; next_number=$((10#$segment_number + 1))
        if (( next_number == 13 )); then
            next_year=$((10#$segment_year + 1)); next_number=1
        fi
        printf -v next_month '%04d-%02d' "$next_year" "$next_number"
        boundary="$(date -d "${next_month}-01 00:00:00" +%s)" \
            || fatal "无法计算跨月统计边界。"
        if ! is_uint "$boundary" || (( boundary <= cursor )); then
            fatal "跨月统计边界异常。"
        fi
        segment_end="$boundary"
        (( segment_end > CURRENT_TS )) && segment_end="$CURRENT_TS"
        segment_seconds=$((segment_end - cursor))
        cumulative_seconds=$((segment_end - LAST_TS))

        proportional_floor "$rx_delta" "$cumulative_seconds" "$elapsed"; cumulative_rx="$PROPORTIONAL_RESULT"
        proportional_floor "$tx_delta" "$cumulative_seconds" "$elapsed"; cumulative_tx="$PROPORTIONAL_RESULT"
        proportional_floor "$busy_delta" "$cumulative_seconds" "$elapsed"; cumulative_busy="$PROPORTIONAL_RESULT"
        proportional_floor "$total_delta" "$cumulative_seconds" "$elapsed"; cumulative_total="$PROPORTIONAL_RESULT"
        segment_rx=$((cumulative_rx - allocated_rx)); segment_tx=$((cumulative_tx - allocated_tx))
        segment_busy=$((cumulative_busy - allocated_busy)); segment_total=$((cumulative_total - allocated_total))

        if [[ -n "$STATE_MONTH" && "$STATE_MONTH" != "$segment_month" ]]; then
            archive_current_month
            MONTH_RX=0; MONTH_TX=0; MONTH_CPU_BUSY=0; MONTH_CPU_TOTAL=0; MONTH_SECONDS=0
        fi
        STATE_MONTH="$segment_month"
        MONTH_RX=$((MONTH_RX + segment_rx)); MONTH_TX=$((MONTH_TX + segment_tx))
        MONTH_CPU_BUSY=$((MONTH_CPU_BUSY + segment_busy)); MONTH_CPU_TOTAL=$((MONTH_CPU_TOTAL + segment_total))
        MONTH_SECONDS=$((MONTH_SECONDS + segment_seconds))

        allocated_rx="$cumulative_rx"; allocated_tx="$cumulative_tx"
        allocated_busy="$cumulative_busy"; allocated_total="$cumulative_total"
        cursor="$segment_end"
    done
}

prune_samples() {
    [[ -f "$SAMPLES_FILE" ]] || return 0
    local cutoff temporary
    cutoff=$((CURRENT_TS - SAMPLE_RETENTION_SECONDS))
    temporary="$(mktemp "${DATA_DIR}/samples.XXXXXXXX")"
    awk -F '\t' -v cutoff="$cutoff" '$2 + 0 >= cutoff' "$SAMPLES_FILE" > "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$SAMPLES_FILE"
}

collect_locked() {
    load_state
    read_counters
    local current_month elapsed rx_delta tx_delta busy_delta total_delta
    current_month="$(date -d "@${CURRENT_TS}" +%Y-%m)"

    if (( LAST_TS == 0 )) || [[ "$LAST_BOOT" != "$CURRENT_BOOT" || "$LAST_INTERFACE" != "$INTERFACE" ]]; then
        roll_month_without_delta "$current_month"
        LAST_TS="$CURRENT_TS"; LAST_BOOT="$CURRENT_BOOT"; LAST_INTERFACE="$INTERFACE"
        LAST_RX="$CURRENT_RX"; LAST_TX="$CURRENT_TX"
        LAST_CPU_BUSY="$CURRENT_CPU_BUSY"; LAST_CPU_TOTAL="$CURRENT_CPU_TOTAL"
        save_state
        return
    fi

    elapsed=$((CURRENT_TS - LAST_TS))
    rx_delta=$((CURRENT_RX - LAST_RX)); tx_delta=$((CURRENT_TX - LAST_TX))
    busy_delta=$((CURRENT_CPU_BUSY - LAST_CPU_BUSY)); total_delta=$((CURRENT_CPU_TOTAL - LAST_CPU_TOTAL))
    if (( elapsed <= 0 || rx_delta < 0 || tx_delta < 0 || busy_delta < 0 || total_delta <= 0 || busy_delta > total_delta )); then
        roll_month_without_delta "$current_month"
        LAST_TS="$CURRENT_TS"; LAST_BOOT="$CURRENT_BOOT"; LAST_INTERFACE="$INTERFACE"
        LAST_RX="$CURRENT_RX"; LAST_TX="$CURRENT_TX"
        LAST_CPU_BUSY="$CURRENT_CPU_BUSY"; LAST_CPU_TOTAL="$CURRENT_CPU_TOTAL"
        save_state
        warn "检测到系统计数器重置，已自动建立新的安全基线。" >&2
        return
    fi

    local sample_start="$LAST_TS" should_sample=0
    add_month_delta "$current_month" "$elapsed" "$rx_delta" "$tx_delta" "$busy_delta" "$total_delta"
    (( elapsed <= MAX_SAMPLE_SECONDS )) && should_sample=1
    LAST_TS="$CURRENT_TS"; LAST_BOOT="$CURRENT_BOOT"; LAST_INTERFACE="$INTERFACE"
    LAST_RX="$CURRENT_RX"; LAST_TX="$CURRENT_TX"
    LAST_CPU_BUSY="$CURRENT_CPU_BUSY"; LAST_CPU_TOTAL="$CURRENT_CPU_TOTAL"
    # Save the accounting baseline before appending the rolling sample. If the
    # process is interrupted between the two writes, one short sample may be
    # absent, but the next run can never count the same traffic twice.
    save_state
    if (( should_sample == 1 )); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$sample_start" "$CURRENT_TS" "$rx_delta" "$tx_delta" "$busy_delta" "$total_delta" >> "$SAMPLES_FILE"
    fi
    prune_samples
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -w 30 9; then
        warn "另一个监控任务仍在运行，本次操作已安全跳过。"
        exit 0
    fi
}

calculate_window() {
    local now="$1"
    local start=$((now - WINDOW_SECONDS))
    [[ -r "$SAMPLES_FILE" ]] || { printf '0 0 0 0 0\n'; return; }
    awk -F '\t' -v start="$start" -v finish="$now" '
        {
            sample_start=$1+0; sample_end=$2+0; duration=sample_end-sample_start
            overlap_start=(sample_start>start ? sample_start : start)
            overlap_end=(sample_end<finish ? sample_end : finish)
            overlap=overlap_end-overlap_start
            if (duration>0 && overlap>0) {
                fraction=overlap/duration
                rx+=($3+0)*fraction; tx+=($4+0)*fraction
                busy+=($5+0)*fraction; total+=($6+0)*fraction; coverage+=overlap
            }
        }
        END { printf "%.6f %.6f %.6f %.6f %.6f\n", rx, tx, busy, total, coverage }
    ' "$SAMPLES_FILE"
}

format_two_hour_message() {
    local rx="$1" tx="$2" busy="$3" total="$4" month_total="$5"
    awk -v name="$SERVER_NAME" -v rx="$rx" -v tx="$tx" -v busy="$busy" -v total="$total" -v month_total="$month_total" '
        BEGIN {
            cpu=(total>0 ? busy*100/total : 0)
            printf "%s\n进站速度: %.2f MB/s\n出站速度: %.2f MB/s\n总流量: %.2f TB\nCPU利用率: %.0f%%", \
                name, rx/7200/1000000, tx/7200/1000000, month_total/1000000000000, cpu
        }
    '
}

format_month_message() {
    local month="$1" rx="$2" tx="$3" busy="$4" total="$5"
    awk -v name="$SERVER_NAME" -v month="$month" -v rx="$rx" -v tx="$tx" -v busy="$busy" -v total="$total" '
        BEGIN {
            split(month, part, "-"); cpu=(total>0 ? busy*100/total : 0)
            printf "%s %d年%d月流量报告\n进站流量: %.2f TB\n出站流量: %.2f TB\n总流量: %.2f TB\n平均CPU利用率: %.0f%%", \
                name, part[1], part[2], rx/1000000000000, tx/1000000000000, (rx+tx)/1000000000000, cpu
        }
    '
}

format_login_message() {
    local login_user="$1" login_ip="$2" login_epoch="$3" login_time
    login_time="$(date -d "@${login_epoch}" '+%F %T %Z')"
    printf '⚠️ VPS 登录提醒\n服务器: %s\n登录用户: %s\n来源IP: %s\n登录时间: %s' \
        "$SERVER_NAME" "$login_user" "$login_ip" "$login_time"
}

send_message() {
    local message="$1" request_dir curl_config message_file response_file attempt wait_seconds result=1
    request_dir="$(mktemp -d "${DATA_DIR}/telegram.XXXXXXXX")"
    chmod 0700 "$request_dir"
    curl_config="${request_dir}/request.conf"; message_file="${request_dir}/message.txt"; response_file="${request_dir}/response.json"
    printf '%s' "$message" > "$message_file"
    printf '%s\n' \
        "url = \"${TELEGRAM_ROOT}/bot${TOKEN}/sendMessage\"" \
        'request = "POST"' \
        'connect-timeout = 10' \
        'max-time = 30' \
        'silent' \
        'show-error' \
        "output = \"${response_file}\"" \
        "data-urlencode = \"chat_id=${CHAT_ID}\"" \
        "data-urlencode = \"text@${message_file}\"" \
        'data = "disable_web_page_preview=true"' \
        'data = "protect_content=true"' > "$curl_config"
    chmod 0600 "$curl_config" "$message_file"

    for attempt in 1 2 3 4; do
        : > "$response_file"
        if curl --config "$curl_config" && grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response_file"; then
            result=0
            break
        fi
        wait_seconds="$(sed -nE 's/.*"retry_after"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$response_file" | head -n 1)"
        is_uint "$wait_seconds" || wait_seconds=$((attempt * 2))
        (( wait_seconds > 30 )) && wait_seconds=30
        (( attempt < 4 )) && sleep "$wait_seconds"
    done
    rm -rf -- "$request_dir"
    (( result == 0 )) || fatal "Telegram 消息发送失败；Token、UID 和消息内容均未写入日志。"
}

run_collect() {
    load_config; acquire_lock
    collect_locked
}

run_report() {
    load_config; acquire_lock
    collect_locked >/dev/null
    load_state
    local now rx tx busy total coverage message
    now="$(date +%s)"
    if (( LAST_REPORT > 0 && now - LAST_REPORT < 6480 )); then
        printf 'report: duplicate-skipped\n'
        return
    fi
    read -r rx tx busy total coverage <<< "$(calculate_window "$now")"
    if ! awk -v value="$coverage" -v minimum="$MIN_COVERAGE_SECONDS" 'BEGIN { exit !(value >= minimum) }'; then
        printf 'report: insufficient-data\n'
        return
    fi
    message="$(format_two_hour_message "$rx" "$tx" "$busy" "$total" "$((MONTH_RX + MONTH_TX))")"
    send_message "$message"
    LAST_REPORT="$now"; save_state
    printf 'report: sent\n'
}

oldest_unsent_month() {
    local current_month candidate month month_key current_key
    local oldest="" oldest_key=0
    current_month="$(date +%Y-%m)"; current_key="${current_month//-/}"
    for candidate in "$DATA_DIR"/month-????-??.tsv; do
        [[ -f "$candidate" ]] || continue
        month="${candidate##*/month-}"; month="${month%.tsv}"
        [[ "$month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || continue
        month_key="${month//-/}"
        (( month_key < current_key )) || continue
        [[ ! -e "${DATA_DIR}/sent-${month}" ]] || continue
        if [[ -z "$oldest" ]] || (( month_key < oldest_key )); then
            oldest="$month"; oldest_key="$month_key"
        fi
    done
    [[ -n "$oldest" ]] || return 1
    printf '%s' "$oldest"
}

run_monthly() {
    load_config; acquire_lock
    collect_locked >/dev/null
    local report_month archive marker rx tx busy total seconds message
    if ! report_month="$(oldest_unsent_month)"; then
        printf 'monthly: nothing-pending\n'
        return
    fi
    archive="${DATA_DIR}/month-${report_month}.tsv"; marker="${DATA_DIR}/sent-${report_month}"
    read -r rx tx busy total seconds < "$archive"
    if ! is_uint "$rx" || ! is_uint "$tx" || ! is_uint "$busy" || ! is_uint "$total" || ! is_uint "$seconds"; then
        fatal "月度统计文件格式异常。"
    fi
    message="$(format_month_message "$report_month" "$rx" "$tx" "$busy" "$total")"
    send_message "$message"
    : > "$marker"; chmod 0600 "$marker"
    printf 'monthly: sent\n'
}

run_test_message() {
    load_config
    send_message "${SERVER_NAME}"$'\n监控测试成功。'
    printf 'test: sent\n'
}

run_login_alert() {
    load_config
    local login_user="${VPS_LOGIN_USER:-}" login_ip="${VPS_LOGIN_IP:-}" login_epoch message
    [[ "$login_user" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || return 0
    [[ "$login_ip" =~ ^[A-Fa-f0-9:.]{3,64}$ ]] || return 0
    [[ "$login_ip" == *.* || "$login_ip" == *:* ]] || return 0
    login_epoch="$(date +%s)"
    message="$(format_login_message "$login_user" "$login_ip" "$login_epoch")"
    send_message "$message"
    printf 'login-alert: sent\n'
}

run_status() {
    require_root
    load_config; load_state
    local last_sample="暂无" last_report="暂无" sample_count=0 state_size=0 now
    local login_alert="异常" timers="正常" timer service service_result
    now="$(date +%s)"
    (( LAST_TS > 0 )) && last_sample="$(date -d "@${LAST_TS}" '+%F %T %Z')"
    (( LAST_REPORT > 0 )) && last_report="$(date -d "@${LAST_REPORT}" '+%F %T %Z')"
    [[ -r "$SAMPLES_FILE" ]] && sample_count="$(wc -l < "$SAMPLES_FILE")"
    [[ -r "$STATE_FILE" ]] && state_size="$(wc -c < "$STATE_FILE")"
    for timer in vps-monitor-{collect,report,monthly}.timer; do
        if ! systemctl is-enabled --quiet "$timer" || ! systemctl is-active --quiet "$timer"; then
            timers="异常"
        fi
    done
    for service in vps-monitor-{collect,report,monthly}.service; do
        if systemctl is-failed --quiet "$service"; then
            timers="异常"
        fi
        service_result="$(systemctl show --property=Result --value "$service" 2>/dev/null || printf 'unknown')"
        [[ -z "$service_result" || "$service_result" == success ]] || timers="异常"
    done
    if (( LAST_TS == 0 || LAST_TS > now + 300 || now - LAST_TS > MAX_SAMPLE_SECONDS )); then
        timers="异常"
    fi
    monitored_interface_is_readable || timers="异常"
    if [[ -x "$LOGIN_HOOK_PATH" && -r "$PAM_SSHD_FILE" ]] \
        && grep -Fqx "$(pam_login_line)" "$PAM_SSHD_FILE" && sshd_pam_is_enabled; then
        login_alert="正常"
    fi
    printf '程序版本: %s\n服务器名称: %s\n监控网卡: %s\n定时任务: %s\n登录提醒: %s\n最近采样: %s\n最近汇报: %s\n短期样本: %s 条\n状态文件: %s 字节\n' \
        "$VERSION" "$SERVER_NAME" "$INTERFACE" "$timers" "$login_alert" "$last_sample" "$last_report" "$sample_count" "$state_size"
}

setup_api_call() {
    local token="$1" method="$2" response="$3"; shift 3
    local config="${WORK_DIR}/setup-api.conf" item
    printf '%s\n' \
        "url = \"${TELEGRAM_ROOT}/bot${token}/${method}\"" \
        'request = "POST"' 'connect-timeout = 10' 'max-time = 20' 'silent' 'show-error' \
        "output = \"${response}\"" > "$config"
    for item in "$@"; do
        printf 'data-urlencode = "%s"\n' "$item" >> "$config"
    done
    chmod 0600 "$config"
    : > "$response"
    curl --config "$config" >/dev/null 2>&1 \
        && grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$response"
}

telegram_updates_cursor() {
    python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        updates = json.load(handle).get("result", [])
    cursor = max((int(item.get("update_id", -1)) + 1 for item in updates), default=0)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
print(cursor)
PY
}

telegram_start_match() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        updates = json.load(handle).get("result", [])
    with open(sys.argv[2], encoding="utf-8") as handle:
        nonce = handle.read().strip()
    cursor = int(sys.argv[3])
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

uid = ""
expected = f"/start {nonce}"
for update in updates:
    try:
        cursor = max(cursor, int(update.get("update_id", -1)) + 1)
    except (ValueError, TypeError):
        continue
    message = update.get("message") or {}
    sender = message.get("from") or {}
    chat = message.get("chat") or {}
    sender_id = sender.get("id")
    chat_id = chat.get("id")
    if (message.get("text") == expected and chat.get("type") == "private"
            and sender.get("is_bot") is not True and isinstance(sender_id, int)
            and sender_id > 0 and sender_id == chat_id):
        uid = str(sender_id)
print(f"{cursor}\t{uid}")
PY
}

resolve_telegram_uid() {
    local token="$1" response="${WORK_DIR}/telegram-response.json" nonce_file="${WORK_DIR}/bind-nonce"
    local bot_username webhook nonce start_time cursor parsed uid=""
    info "正在安全验证 Bot Token……" > /dev/tty
    setup_api_call "$token" getMe "$response" || fatal "Token 无效，或 VPS 无法访问 Telegram API。"
    bot_username="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["result"]["username"])' "$response" 2>/dev/null || true)"
    [[ "$bot_username" =~ ^[A-Za-z0-9_]{5,32}$ ]] || fatal "无法读取机器人用户名。"
    success "Token 有效，机器人为 @${bot_username}" > /dev/tty

    setup_api_call "$token" getWebhookInfo "$response" || fatal "无法检查机器人状态。"
    webhook="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["result"].get("url", ""))' "$response" 2>/dev/null || true)"
    [[ -z "$webhook" ]] || fatal "该机器人已配置 Webhook，无法使用安全启动链接。请创建一个专用机器人。"

    setup_api_call "$token" getUpdates "$response" "timeout=0" "limit=1" "offset=-1" \
        || fatal "无法初始化机器人消息，请确认该机器人没有被其他程序同时使用。"
    cursor="$(telegram_updates_cursor "$response")" || fatal "无法解析 Telegram 返回的数据。"
    is_uint "$cursor" || fatal "Telegram 更新游标格式异常。"

    nonce="vps_$(tr -d '-' < /proc/sys/kernel/random/uuid)"
    [[ "$nonce" =~ ^vps_[A-Fa-f0-9]{32}$ ]] || fatal "无法生成安全的一次性验证码。"
    printf '%s' "$nonce" > "$nonce_file"; chmod 0600 "$nonce_file"
    printf '\n请打开下面的一次性安全链接，并点击“开始/START”：\n\n  https://t.me/%s?start=%s\n\n' \
        "$bot_username" "$nonce" > /dev/tty
    printf '正在等待 Telegram 确认（最长 3 分钟）' > /dev/tty

    start_time=$SECONDS
    while (( SECONDS - start_time < 180 )); do
        if setup_api_call "$token" getUpdates "$response" "timeout=10" "limit=100" "offset=${cursor}"; then
            parsed="$(telegram_start_match "$response" "$nonce_file" "$cursor")" || parsed=""
            IFS=$'\t' read -r cursor uid <<< "$parsed"
            is_uint "$cursor" || fatal "Telegram 更新游标格式异常。"
            if is_telegram_uid "$uid"; then
                printf ' 已确认！\n' > /dev/tty
                setup_api_call "$token" sendMessage "$response" \
                    "chat_id=${uid}" "text=VPS Monitor：安全启动链接验证成功。" \
                    || fatal "已识别 UID，但测试消息发送失败，请重新运行安装命令。"
                printf '%s' "$uid"
                return
            fi
        elif grep -Eq '"error_code"[[:space:]]*:[[:space:]]*409' "$response"; then
            fatal "该机器人正被其他程序读取消息，请使用一个专用机器人。"
        fi
        printf '.' > /dev/tty
    done
    printf '\n' > /dev/tty
    fatal "等待超时。请重新运行安装命令，并在 3 分钟内点击安全启动链接。"
}

pam_login_line() {
    printf 'session optional pam_exec.so quiet type=open_session %s' "$LOGIN_HOOK_PATH"
}

sshd_pam_is_enabled() {
    [[ -x "$SSHD_BIN" ]] || return 1
    "$SSHD_BIN" -T 2>/dev/null | awk '$1 == "usepam" && value == "" { value=$2 } END { print value }' | grep -Fqx yes
}

render_login_hook() {
    cat <<'EOF'
#!/bin/sh
set -u

[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
[ "${PAM_SERVICE:-}" = "sshd" ] || exit 0
case "${PAM_USER:-}" in
    ''|*[!A-Za-z0-9_.-]*) exit 0 ;;
esac
case "${PAM_RHOST:-}" in
    ''|*[!A-Fa-f0-9:.]*) exit 0 ;;
esac
[ "${#PAM_USER}" -le 64 ] || exit 0
[ "${#PAM_RHOST}" -le 64 ] || exit 0
case "$PAM_RHOST" in
    *.*|*:*) ;;
    *) exit 0 ;;
esac

/usr/bin/systemd-run --quiet --no-block --collect \
    --unit="vps-monitor-login-alert-$(/usr/bin/date +%s%N)-$$" \
    --description="VPS SSH login alert" \
    --property=User=vpsmonitor \
    --property=Group=vpsmonitor \
    --property=Nice=10 \
    --property=UMask=0077 \
    --property=NoNewPrivileges=yes \
    --property=PrivateTmp=yes \
    --property=PrivateDevices=yes \
    --property=ProtectSystem=strict \
    --property=ProtectHome=yes \
    --property=ProtectKernelTunables=yes \
    --property=ProtectKernelModules=yes \
    --property=ProtectKernelLogs=yes \
    --property=ProtectControlGroups=yes \
    --property=RestrictSUIDSGID=yes \
    --property=LockPersonality=yes \
    --property=RestrictNamespaces=yes \
    --property="RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" \
    --property=ReadWritePaths=/var/lib/vps-monitor \
    --property=TimeoutStartSec=3min \
    --setenv="VPS_LOGIN_USER=$PAM_USER" \
    --setenv="VPS_LOGIN_IP=$PAM_RHOST" \
    /usr/local/bin/vps-monitor login-alert >/dev/null 2>&1 || true

exit 0
EOF
}

ensure_pam_login_line() {
    local line
    line="$(pam_login_line)"
    grep -Fqx "$line" "$PAM_SSHD_FILE" && return 0
    printf '\n%s\n%s\n' "$PAM_MARKER" "$line" >> "$PAM_SSHD_FILE"
}

remove_pam_login_line() {
    [[ -f "$PAM_SSHD_FILE" ]] || return 0
    local line temporary
    line="$(pam_login_line)"; temporary="$(mktemp -t vps-monitor-pam.XXXXXXXX)"
    if ! awk -v marker="$PAM_MARKER" -v line="$line" '$0 != marker && $0 != line' \
        "$PAM_SSHD_FILE" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    cat -- "$temporary" > "$PAM_SSHD_FILE"
    rm -f -- "$temporary"
}

install_login_alert_hook() {
    sshd_pam_is_enabled \
        || fatal "SSH 未启用 PAM 会话处理（UsePAM yes），无法保证登录提醒生效，安装已停止。"
    [[ -f "$PAM_SSHD_FILE" && -w "$PAM_SSHD_FILE" ]] || fatal "找不到可写的 SSH PAM 配置，无法启用登录提醒。"
    render_login_hook > "${WORK_DIR}/login-alert-hook"
    sh -n "${WORK_DIR}/login-alert-hook" || fatal "登录提醒钩子语法校验失败。"
    install -o root -g root -m 0755 "${WORK_DIR}/login-alert-hook" "$LOGIN_HOOK_PATH"
    ensure_pam_login_line
}

detect_interface() {
    local interface
    interface="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$interface" ]]; then
        interface="$(ip -o -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
    [[ "$interface" =~ ^[A-Za-z0-9_.:@-]{1,64}$ && -r "/sys/class/net/${interface}/statistics/rx_bytes" ]] \
        || fatal "无法自动识别默认公网网卡。"
    printf '%s' "$interface"
}

detect_server_name() {
    local response="${WORK_DIR}/ipwho.json" name
    if curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 5 --max-time 8 \
        'https://ipwho.is/' -o "$response"; then
        name="$(python3 - "$response" <<'PY'
import json, re, socket, sys
countries = {"AU":"澳大利亚","CA":"加拿大","DE":"德国","FI":"芬兰","FR":"法国","GB":"英国","HK":"香港","IN":"印度","JP":"日本","KR":"韩国","NL":"荷兰","SG":"新加坡","TW":"台湾","US":"美国"}
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    country = countries.get(str(data.get("country_code", "")).upper(), str(data.get("country", "")).strip())
    connection = data.get("connection") or {}
    provider = str(connection.get("isp") or connection.get("org") or "VPS")
    provider = re.sub(r"\b(LLC|LTD|LIMITED|INC|CORP|CORPORATION|CO\.?|GMBH)\b", "", provider, flags=re.I)
    provider = "".join(re.findall(r"[A-Za-z0-9\u4e00-\u9fff._-]+", provider)[:2])[:24] or "VPS"
    value = (country + provider)[:80]
except Exception:
    value = socket.gethostname()[:80] or "VPS"
print(value.replace("\n", ""))
PY
)"
    else
        name="$(hostname | tr -cd 'A-Za-z0-9._-')"
    fi
    [[ -n "$name" ]] || name="VPS"
    printf '%s' "$name"
}

require_root() {
    (( EUID == 0 )) || fatal "请复制 README 中带 sudo 的一行命令运行。"
}

run_as_service_user_if_needed() {
    local command_name="$1"
    (( EUID == 0 )) || {
        [[ "$(id -un)" == "$SERVICE_USER" ]] \
            || fatal "运行任务只能由专用账户执行；请使用 sudo vps-monitor ${command_name}。"
        return
    }
    is_managed_service_account || fatal "专用系统账户状态异常，无法安全运行监控任务。"
    exec runuser -u "$SERVICE_USER" -- "$SCRIPT_PATH" "$@"
}

is_managed_service_account() {
    local passwd_entry group_entry account_name account_uid account_gid account_home account_shell
    local group_name group_gid
    passwd_entry="$(getent passwd "$SERVICE_USER")" || return 1
    group_entry="$(getent group "$SERVICE_USER")" || return 1
    IFS=: read -r account_name _ account_uid account_gid _ account_home account_shell <<< "$passwd_entry"
    IFS=: read -r group_name _ group_gid _ <<< "$group_entry"
    is_uint "$account_uid" && is_uint "$account_gid" && is_uint "$group_gid" \
        && (( account_uid > 0 && account_uid < 1000 )) \
        && [[ "$account_name" == "$SERVICE_USER" && "$group_name" == "$SERVICE_USER" ]] \
        && [[ "$account_gid" == "$group_gid" && "$account_home" == "$DATA_DIR" ]] \
        && [[ "$account_shell" == /usr/sbin/nologin || "$account_shell" == /bin/false ]]
}

verify_supported_os() {
    local os_release_file="${VPS_MONITOR_OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "$os_release_file" ]] || fatal "无法识别操作系统。"
    # shellcheck disable=SC1090 # The path is fixed in production and overridden only by tests.
    source "$os_release_file"
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04|ubuntu:24.04) ;;
        ubuntu:*) fatal "仅支持 Ubuntu 22.04/24.04，当前为 ${PRETTY_NAME:-未知系统}。" ;;
        debian:12|debian:12.*) ;;
        debian:*) fatal "仅支持 Debian 12，当前为 ${PRETTY_NAME:-未知系统}。" ;;
        *) fatal "仅支持 Ubuntu 和 Debian 12，当前为 ${PRETTY_NAME:-未知系统}。" ;;
    esac
    command -v systemctl >/dev/null || fatal "系统未使用 systemd。"
    if ! command -v apt-get >/dev/null || ! command -v dpkg-query >/dev/null; then
        fatal "系统缺少 apt/dpkg 包管理工具。"
    fi
    success "系统检查通过：${PRETTY_NAME:-Linux}"
}

ensure_dependencies() {
    local missing=0 command_name
    for command_name in curl ip flock python3 awk getent groupadd useradd runuser systemd-run sha256sum tar; do
        command -v "$command_name" >/dev/null || missing=1
    done
    if ! dpkg-query -W -f='${Status}' libpam-modules 2>/dev/null | grep -Fq 'install ok installed'; then
        missing=1
    fi
    if (( missing == 1 )); then
        info "正在安装系统基础组件……"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq bash curl ca-certificates iproute2 util-linux python3 gawk passwd libpam-modules tar
    fi
    success "基础组件已就绪（运行时无第三方库）"
}

script_version() {
    local file="$1" version
    version="$(sed -nE 's/^VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' "$file" | head -n 1)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s' "$version"
}

version_is_newer() {
    local candidate="$1" installed="$2"
    local candidate_major candidate_minor candidate_patch installed_major installed_minor installed_patch
    IFS=. read -r candidate_major candidate_minor candidate_patch <<< "$candidate"
    IFS=. read -r installed_major installed_minor installed_patch <<< "$installed"
    is_uint "$candidate_major" && is_uint "$candidate_minor" && is_uint "$candidate_patch" \
        && is_uint "$installed_major" && is_uint "$installed_minor" && is_uint "$installed_patch" \
        || return 1
    (( 10#$candidate_major > 10#$installed_major \
        || (10#$candidate_major == 10#$installed_major && 10#$candidate_minor > 10#$installed_minor) \
        || (10#$candidate_major == 10#$installed_major && 10#$candidate_minor == 10#$installed_minor \
            && 10#$candidate_patch > 10#$installed_patch) ))
}

verify_downloaded_script() {
    local script_file="$1" checksum_file="$2" expected listed extra actual
    local -a checksum_lines=()
    mapfile -t checksum_lines < "$checksum_file" || return 1
    (( ${#checksum_lines[@]} == 1 )) || return 1
    read -r expected listed extra <<< "${checksum_lines[0]}"
    listed="${listed#\*}"
    [[ -z "${extra:-}" && "$expected" =~ ^[A-Fa-f0-9]{64}$ && "$listed" == "TG-check-notify.sh" ]] \
        || return 1
    actual="$(sha256sum "$script_file" | awk '{print $1}')" || return 1
    [[ "${expected,,}" == "${actual,,}" ]] || return 1
    grep -q '^# VPS_TELEGRAM_MONITOR_SCRIPT=1$' "$script_file" || return 1
    script_version "$script_file" >/dev/null || return 1
    bash -n "$script_file"
}

extract_verified_main_archive() {
    local archive_file="$1" output_file="$2" checksum_file="$3"
    tar -xOzf "$archive_file" "${GITHUB_ARCHIVE_ROOT}/TG-check-notify.sh" > "$output_file" \
        && tar -xOzf "$archive_file" "${GITHUB_ARCHIVE_ROOT}/TG-check-notify.sh.sha256" > "$checksum_file" \
        && verify_downloaded_script "$output_file" "$checksum_file"
}

download_verified_main() {
    local output_file="$1" checksum_file="${WORK_DIR}/TG-check-notify.sh.sha256"
    local archive_file="${WORK_DIR}/vps-monitor-main.tar.gz" attempt
    for attempt in 1 2 3; do
        rm -f -- "$output_file" "$checksum_file" "$archive_file"
        if curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
                --connect-timeout 10 --max-time 60 "$GITHUB_ARCHIVE_URL" -o "$archive_file" \
            && extract_verified_main_archive "$archive_file" "$output_file" "$checksum_file"; then
            chmod 0700 "$output_file"
            return 0
        fi
        (( attempt < 3 )) && sleep "$attempt"
    done
    return 1
}

install_systemd_units() {
    install -d -m 0755 "$SYSTEMD_DIR"
    cat > "${SYSTEMD_DIR}/vps-monitor-collect.service" <<EOF
[Unit]
Description=Lightweight VPS monitor collector
[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_PATH} collect
Nice=10
IOSchedulingClass=idle
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX
ReadWritePaths=${DATA_DIR}
TimeoutStartSec=60
StandardOutput=null
StandardError=journal
EOF
    cat > "${SYSTEMD_DIR}/vps-monitor-collect.timer" <<EOF
[Unit]
Description=Collect VPS counters every five minutes
[Timer]
OnBootSec=10s
OnUnitActiveSec=5min
AccuracySec=10s
Unit=vps-monitor-collect.service
[Install]
WantedBy=timers.target
EOF
    cat > "${SYSTEMD_DIR}/vps-monitor-report.service" <<EOF
[Unit]
Description=Send two-hour VPS Telegram report
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_PATH} report
Nice=10
IOSchedulingClass=idle
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${DATA_DIR}
TimeoutStartSec=4min
Restart=on-failure
RestartSec=10min
EOF
    cat > "${SYSTEMD_DIR}/vps-monitor-report.timer" <<EOF
[Unit]
Description=Send VPS report every two hours
[Timer]
OnCalendar=*-*-* 0/2:00:00
Persistent=true
AccuracySec=30s
Unit=vps-monitor-report.service
[Install]
WantedBy=timers.target
EOF
    cat > "${SYSTEMD_DIR}/vps-monitor-monthly.service" <<EOF
[Unit]
Description=Send previous calendar month VPS report
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_PATH} monthly
Nice=10
IOSchedulingClass=idle
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${DATA_DIR}
TimeoutStartSec=4min
Restart=on-failure
RestartSec=30min
EOF
    cat > "${SYSTEMD_DIR}/vps-monitor-monthly.timer" <<EOF
[Unit]
Description=Send VPS monthly report
[Timer]
OnCalendar=*-*-* 00:05:00
Persistent=true
AccuracySec=1min
Unit=vps-monitor-monthly.service
[Install]
WantedBy=timers.target
EOF
    chmod 0644 "${SYSTEMD_DIR}"/vps-monitor-{collect,report,monthly}.{service,timer}
}

install_script_source() {
    local source_file="${BASH_SOURCE[0]:-}" temporary="${WORK_DIR}/TG-check-notify.sh"
    if [[ -n "$source_file" && -f "$source_file" && "$source_file" != /dev/fd/* \
        && "$source_file" != /dev/stdin && "$source_file" != /proc/self/fd/* ]]; then
        cp -- "$source_file" "$temporary"
    else
        info "正在下载并校验 GitHub 主版本……"
        download_verified_main "$temporary" || fatal "主版本下载或 SHA-256 校验失败，安装已安全停止。"
    fi
    grep -q '^# VPS_TELEGRAM_MONITOR_SCRIPT=1$' "$temporary" || fatal "下载文件校验失败。"
    bash -n "$temporary" || fatal "脚本语法校验失败。"
    install -d -o root -g root -m 0755 "$INSTALL_DIR"
    install -o root -g root -m 0755 "$temporary" "$SCRIPT_PATH"
    ln -sfn "$SCRIPT_PATH" "$BIN_PATH"
}

install_app() {
    require_root
    if [[ -f "$SCRIPT_PATH" && -x "$SCRIPT_PATH" && -e "$BIN_PATH" \
        && -r "$TOKEN_FILE" && -r "$CHAT_ID_FILE" && -r "$SERVER_NAME_FILE" && -r "$INTERFACE_FILE" ]]; then
        info "检测到现有安装，将保留 TG 配置和统计数据并执行安全更新。"
        run_update
        return
    fi
    verify_supported_os; ensure_dependencies
    [[ -r /dev/tty && -w /dev/tty ]] || fatal "需要交互式 SSH 终端，当前环境无法安全读取 Token。"
    WORK_DIR="$(mktemp -d -t vps-monitor-install.XXXXXXXX)"; chmod 0700 "$WORK_DIR"; trap cleanup_work_dir EXIT
    local setup_token setup_chat_id setup_interface setup_server_name create_service_account=0
    printf '\n╭────────────────────────────────────╮\n│  VPS Telegram Monitor 一键安装    │\n╰────────────────────────────────────╯\n\n' > /dev/tty
    read -r -s -p '请输入 Bot Token（输入不会显示）：' setup_token < /dev/tty
    printf '\n' > /dev/tty
    [[ "$setup_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] || fatal "Token 格式不正确。"
    setup_chat_id="$(resolve_telegram_uid "$setup_token")"
    info "正在自动识别公网网卡、国家和服务商……"
    setup_interface="$(detect_interface)"; setup_server_name="$(detect_server_name)"
    success "识别结果：${setup_server_name}（${setup_interface}）"

    if getent passwd "$SERVICE_USER" >/dev/null; then
        is_managed_service_account \
            || fatal "系统中已存在同名账户，但属性不属于本程序。为避免影响原有服务，安装已停止。"
    else
        ! getent group "$SERVICE_USER" >/dev/null \
            || fatal "系统中已存在同名用户组。为避免影响原有服务，安装已停止。"
        create_service_account=1
    fi
    install_script_source
    if (( create_service_account == 1 )); then
        if ! groupadd --system "$SERVICE_USER"; then
            rm -f -- "$BIN_PATH"; rm -rf -- "$INSTALL_DIR"
            fatal "无法创建专用系统用户组，安装已安全停止。"
        fi
        if ! useradd --system --gid "$SERVICE_USER" --home-dir "$DATA_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
            groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
            rm -f -- "$BIN_PATH"; rm -rf -- "$INSTALL_DIR"
            fatal "无法创建专用系统账户，安装已安全停止。"
        fi
    fi
    systemctl stop vps-monitor-{collect,report,monthly}.{timer,service} >/dev/null 2>&1 || true
    install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
    printf '%s' "$setup_token" > "${WORK_DIR}/token"
    printf '%s' "$setup_chat_id" > "${WORK_DIR}/chat_id"
    printf '%s' "$setup_server_name" > "${WORK_DIR}/server_name"
    printf '%s' "$setup_interface" > "${WORK_DIR}/interface"
    install -o root -g "$SERVICE_USER" -m 0640 "${WORK_DIR}/token" "$TOKEN_FILE"
    install -o root -g "$SERVICE_USER" -m 0640 "${WORK_DIR}/chat_id" "$CHAT_ID_FILE"
    install -o root -g "$SERVICE_USER" -m 0640 "${WORK_DIR}/server_name" "$SERVER_NAME_FILE"
    install -o root -g "$SERVICE_USER" -m 0640 "${WORK_DIR}/interface" "$INTERFACE_FILE"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"; chmod 0750 "$DATA_DIR"

    install_systemd_units
    install_login_alert_hook
    systemctl daemon-reload
    runuser -u "$SERVICE_USER" -- "$BIN_PATH" collect >/dev/null
    systemctl enable --now vps-monitor-{collect,report,monthly}.timer >/dev/null
    success "安装完成，Telegram 安全启动链接与 SSH 登录提醒已验证"
    printf '\n以后无需操作：每 5 分钟轻量采集，每 2 小时汇报，每月 1 日发送月报；SSH 登录成功时立即提醒。\n'
    printf '查看状态：sudo vps-monitor status\n查看日志：sudo journalctl -u "vps-monitor-*" --since today\n\n'
    warn "Token 与 UID 仅保存在受限配置文件中，日志不会输出这些信息。"
}

apply_installed_update() {
    require_root
    is_managed_service_account || fatal "专用系统账户状态异常，已拒绝更新。"
    load_config
    WORK_DIR="$(mktemp -d -t vps-monitor-update-apply.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    trap cleanup_work_dir EXIT
    install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$DATA_DIR"
    chown root:"$SERVICE_USER" "$TOKEN_FILE" "$CHAT_ID_FILE" "$SERVER_NAME_FILE" "$INTERFACE_FILE"
    chmod 0640 "$TOKEN_FILE" "$CHAT_ID_FILE" "$SERVER_NAME_FILE" "$INTERFACE_FILE"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"; chmod 0750 "$DATA_DIR"
    install_systemd_units
    install_login_alert_hook
    systemctl daemon-reload
    systemctl enable --now vps-monitor-{collect,report,monthly}.timer >/dev/null
}

restore_update_backup() {
    local backup_dir="$1" pam_line_was_present="$2" unit units_complete=1
    install -o root -g root -m 0755 "${backup_dir}/TG-check-notify.sh" "$SCRIPT_PATH" || return 1
    if [[ -f "${backup_dir}/login-alert-hook" ]]; then
        install -o root -g root -m 0755 "${backup_dir}/login-alert-hook" "$LOGIN_HOOK_PATH" || return 1
    else
        rm -f -- "$LOGIN_HOOK_PATH" || return 1
    fi
    for unit in vps-monitor-{collect,report,monthly}.{service,timer}; do
        if [[ -f "${backup_dir}/units/${unit}" ]]; then
            install -o root -g root -m 0644 "${backup_dir}/units/${unit}" "${SYSTEMD_DIR}/${unit}" || return 1
        else
            rm -f -- "${SYSTEMD_DIR}/${unit}" || return 1
            units_complete=0
        fi
    done
    (( pam_line_was_present == 1 )) || remove_pam_login_line || return 1
    ln -sfn "$SCRIPT_PATH" "$BIN_PATH" || return 1
    systemctl daemon-reload || return 1
    if (( units_complete == 1 )); then
        systemctl enable --now vps-monitor-{collect,report,monthly}.timer >/dev/null || return 1
    fi
}

run_update() {
    require_root; verify_supported_os; ensure_dependencies
    exec 8>"$UPDATE_LOCK_FILE"
    flock -n 8 || fatal "另一个更新任务正在运行，请稍后再试。"
    [[ -f "$SCRIPT_PATH" && -x "$SCRIPT_PATH" && -e "$BIN_PATH" ]] \
        || fatal "未检测到完整安装，请先运行 README 中的一键安装命令。"
    is_managed_service_account || fatal "专用系统账户状态异常，为避免影响其他程序，更新已停止。"
    load_config

    WORK_DIR="$(mktemp -d -t vps-monitor-update.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    trap cleanup_work_dir EXIT
    local downloaded="${WORK_DIR}/TG-check-notify.sh" backup_dir="${WORK_DIR}/backup"
    local installed_version remote_version unit same_version=0 pam_line_was_present=0

    info "正在检查 GitHub 主版本并验证 SHA-256……"
    download_verified_main "$downloaded" || fatal "主版本下载或 SHA-256 校验失败，现有程序未被修改。"
    installed_version="$(script_version "$SCRIPT_PATH")" || fatal "无法识别当前安装版本，现有程序未被修改。"
    remote_version="$(script_version "$downloaded")" || fatal "无法识别主版本，现有程序未被修改。"
    if [[ "$remote_version" == "$installed_version" ]]; then
        same_version=1
    else
        version_is_newer "$remote_version" "$installed_version" \
            || fatal "主版本 v${remote_version} 低于当前版本 v${installed_version}，已拒绝自动降级。"
    fi

    mkdir -p "${backup_dir}/units"
    cp -p -- "$SCRIPT_PATH" "${backup_dir}/TG-check-notify.sh"
    if [[ -f "$LOGIN_HOOK_PATH" ]]; then
        cp -p -- "$LOGIN_HOOK_PATH" "${backup_dir}/login-alert-hook"
    fi
    for unit in vps-monitor-{collect,report,monthly}.{service,timer}; do
        if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then
            cp -p -- "${SYSTEMD_DIR}/${unit}" "${backup_dir}/units/${unit}"
        fi
    done
    if [[ -f "$PAM_SSHD_FILE" ]] && grep -Fqx "$(pam_login_line)" "$PAM_SSHD_FILE"; then
        pam_line_was_present=1
    fi

    systemctl stop vps-monitor-{collect,report,monthly}.timer >/dev/null 2>&1 || true
    UPDATE_TIMERS_STOPPED=1
    local wait_deadline=$((SECONDS + 240)) active_service
    while :; do
        active_service=0
        for unit in vps-monitor-{collect,report,monthly}.service; do
            systemctl is-active --quiet "$unit" && active_service=1
        done
        (( active_service == 0 )) && break
        if (( SECONDS >= wait_deadline )); then
            systemctl enable --now vps-monitor-{collect,report,monthly}.timer >/dev/null 2>&1 || true
            fatal "监控任务长时间未结束，更新已取消，现有程序未被修改。"
        fi
        sleep 1
    done

    if (( same_version == 1 )); then
        info "正在校验并修复 v${installed_version} 的完整安装……"
    else
        info "正在从 v${installed_version} 安全更新到 v${remote_version}……"
    fi
    if install -o root -g root -m 0755 "$downloaded" "$SCRIPT_PATH" \
        && ln -sfn "$SCRIPT_PATH" "$BIN_PATH" \
        && "$SCRIPT_PATH" __apply-update; then
        UPDATE_TIMERS_STOPPED=0
        if (( same_version == 1 )); then
            success "当前已是最新版 v${installed_version}，完整性检查和自动修复完成。"
        else
            success "更新完成：v${installed_version} → v${remote_version}。"
        fi
        printf 'TG Token、UID、历史流量和 SSH 登录提醒均已保留。\n'
        return
    fi

    warn "新版本应用失败，正在恢复更新前的完整文件……"
    if restore_update_backup "$backup_dir" "$pam_line_was_present"; then
        UPDATE_TIMERS_STOPPED=0
        fatal "更新或修复失败，已自动恢复 v${installed_version}，配置和统计数据未丢失。"
    fi
    UPDATE_TIMERS_STOPPED=0
    fatal "更新和自动恢复均未完整完成，定时任务已保持停止；请保留此输出并检查 systemd 状态，配置与统计目录未被删除。"
}

uninstall_app() {
    require_root
    local managed_account=0 unit path pam_line
    local -a leftovers=()
    is_managed_service_account && managed_account=1
    pam_line="$(pam_login_line)"

    remove_pam_login_line || fatal "无法安全移除 SSH PAM 登录提醒，卸载已停止。"
    systemctl disable --now vps-monitor-{collect,report,monthly}.timer >/dev/null 2>&1 || true
    systemctl stop vps-monitor-{collect,report,monthly}.service >/dev/null 2>&1 || true
    systemctl stop 'vps-monitor-login-alert-*.service' >/dev/null 2>&1 || true
    rm -f -- "${SYSTEMD_DIR}"/vps-monitor-{collect,report,monthly}.{service,timer} "$BIN_PATH" || true
    rm -rf -- "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" || true

    if (( managed_account == 1 )); then
        if getent passwd "$SERVICE_USER" >/dev/null; then
            userdel "$SERVICE_USER" >/dev/null 2>&1 || true
        fi
        if getent group "$SERVICE_USER" >/dev/null; then
            groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
        fi
    elif getent passwd "$SERVICE_USER" >/dev/null || getent group "$SERVICE_USER" >/dev/null; then
        warn "检测到同名系统账户，但属性与本程序专用账户不完全匹配，已保留以免影响原有服务。"
    fi

    if ! systemctl daemon-reload; then
        leftovers+=("systemd 配置重新加载失败")
    fi
    systemctl reset-failed vps-monitor-{collect,report,monthly}.{service,timer} >/dev/null 2>&1 || true
    systemctl reset-failed 'vps-monitor-login-alert-*.service' >/dev/null 2>&1 || true

    for path in "$BIN_PATH" "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" \
        "${SYSTEMD_DIR}"/vps-monitor-{collect,report,monthly}.{service,timer} \
        "${SYSTEMD_DIR}"/timers.target.wants/vps-monitor-{collect,report,monthly}.timer; do
        [[ ! -e "$path" && ! -L "$path" ]] || leftovers+=("$path")
    done
    for unit in vps-monitor-{collect,report,monthly}.{service,timer}; do
        systemctl is-active --quiet "$unit" && leftovers+=("仍在运行的 systemd 单元 ${unit}")
        systemctl is-enabled --quiet "$unit" && leftovers+=("仍然启用的 systemd 单元 ${unit}")
    done
    if systemctl list-units --state=active --type=service --plain --no-legend \
        'vps-monitor-login-alert-*.service' 2>/dev/null | grep -q .; then
        leftovers+=("仍在运行的 SSH 登录提醒任务")
    fi
    if [[ -f "$PAM_SSHD_FILE" ]] \
        && { grep -Fqx "$pam_line" "$PAM_SSHD_FILE" || grep -Fqx "$PAM_MARKER" "$PAM_SSHD_FILE"; }; then
        leftovers+=("SSH PAM 登录提醒配置")
    fi
    if (( managed_account == 1 )); then
        getent passwd "$SERVICE_USER" >/dev/null && leftovers+=("专用用户 ${SERVICE_USER}")
        getent group "$SERVICE_USER" >/dev/null && leftovers+=("专用用户组 ${SERVICE_USER}")
    fi

    if (( ${#leftovers[@]} > 0 )); then
        warn "卸载未完全完成，以下项目仍然存在："
        printf '  - %s\n' "${leftovers[@]}"
        fatal "请保留此输出并检查系统状态；脚本没有修改任何无关资源。"
    fi
    success "程序、定时任务、登录提醒、Token、统计数据和专用账户均已删除。"
    warn "为避免影响系统，公共组件、systemd 历史日志和 Telegram 聊天消息不会被删除。"
}

usage() {
    printf '用法：vps-monitor {collect|report|monthly|test|status|update|uninstall}\n'
}

main() {
    case "${1:-install}" in
        collect|report|monthly|test|login-alert) run_as_service_user_if_needed "$@" ;;
    esac
    case "${1:-install}" in
        install) install_app ;;
        collect) run_collect ;;
        report) run_report ;;
        monthly) run_monthly ;;
        test) run_test_message ;;
        login-alert) run_login_alert ;;
        status) run_status ;;
        update) run_update ;;
        __apply-update) apply_installed_update ;;
        uninstall|--uninstall) uninstall_app ;;
        --version) printf 'vps-monitor %s\n' "$VERSION" ;;
        *) usage; exit 2 ;;
    esac
}

if [[ "${VPS_MONITOR_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
