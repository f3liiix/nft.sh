#!/usr/bin/env bash
#
# nftables 端口转发管理工具 v1.1
# 交互式管理 DNAT 端口转发规则
#

# ============== 常量定义 ==============
CONF_DIR="${NFT_FORWARD_CONF_DIR:-/etc/nftables.d}"
CONF_FILE="${NFT_FORWARD_CONF_FILE:-${CONF_DIR}/port-forward.conf}"
RULES_FILE="${NFT_FORWARD_RULES_FILE:-${CONF_DIR}/port-forward.rules}"
BACKUP_DIR="${NFT_FORWARD_BACKUP_DIR:-${CONF_DIR}/backups}"
MAIN_CONF="${NFT_FORWARD_MAIN_CONF:-/etc/nftables.conf}"
SYSCTL_CONF="${NFT_FORWARD_SYSCTL_CONF:-/etc/sysctl.d/99-nft-forward.conf}"
LOG_FILE="${NFT_FORWARD_LOG_FILE:-/var/log/nft-forward.log}"
LOGROTATE_CONF="${NFT_FORWARD_LOGROTATE_CONF:-/etc/logrotate.d/nft-forward}"
STATE_DIR="${NFT_FORWARD_STATE_DIR:-/var/lib/nft-forward}"
STATE_FILE="${NFT_FORWARD_STATE_FILE:-${STATE_DIR}/traffic-state}"
SYSTEMD_DIR="${NFT_FORWARD_SYSTEMD_DIR:-/etc/systemd/system}"
TRAFFIC_SERVICE_FILE="${NFT_FORWARD_TRAFFIC_SERVICE_FILE:-${SYSTEMD_DIR}/nft-forward-traffic-check.service}"
TRAFFIC_TIMER_FILE="${NFT_FORWARD_TRAFFIC_TIMER_FILE:-${SYSTEMD_DIR}/nft-forward-traffic-check.timer}"
SCRIPT_PATH="${NFT_FORWARD_SCRIPT_PATH:-/usr/local/sbin/nft.sh}"
SCRIPT_URL="${NFT_FORWARD_SCRIPT_URL:-https://nft.hide.ss/nft.sh}"
TABLE_NAME="${NFT_FORWARD_TABLE_NAME:-port_forward}"
QUOTA_PERIOD_SECONDS="${NFT_FORWARD_QUOTA_PERIOD_SECONDS:-2592000}"
GB_BYTES="${NFT_FORWARD_GB_BYTES:-1000000000}"
QUOTA_RESET_DISPLAY_TZ="${NFT_FORWARD_QUOTA_RESET_TZ:-Asia/Shanghai}"
CONF_INCLUDE_LINE="include \"${CONF_DIR}/*.conf\""
APP_TITLE="${NFT_FORWARD_APP_TITLE:-nftables 端口转发管理工具}"
APP_VERSION="${NFT_FORWARD_APP_VERSION:-v1.1}"
GUM_BIN="${NFT_FORWARD_GUM_BIN:-gum}"
GUM_ENABLED=0
GUM_CONNECT_TIMEOUT="${NFT_FORWARD_GUM_CONNECT_TIMEOUT:-5}"
GUM_MAX_TIME="${NFT_FORWARD_GUM_MAX_TIME:-20}"
GUM_APT_TIMEOUT="${NFT_FORWARD_GUM_APT_TIMEOUT:-20}"
DEFAULT_GUM_DEB_AMD64_URL="${NFT_FORWARD_DEFAULT_GUM_DEB_AMD64_URL:-https://mirror-1322011140.cos.ap-shanghai.myqcloud.com/gum/gum_0.17.0_amd64.deb}"
DEFAULT_GUM_DEB_ARM64_URL="${NFT_FORWARD_DEFAULT_GUM_DEB_ARM64_URL:-https://mirror-1322011140.cos.ap-shanghai.myqcloud.com/gum/gum_0.17.0_arm64.deb}"
GUM_ENABLE_CHARM_REPO_FALLBACK="${NFT_FORWARD_GUM_ENABLE_CHARM_REPO_FALLBACK:-0}"
GUM_INSTALL_FAILED=0
# 规则列表/gum table 表头同色：Lip Gloss 256 色号（与其它 gum 蓝紫标题接近）；也可用 NFT_FORWARD_TABLE_HEADER_FG（如 `39`、`62`、`#569CD6`）覆盖 gum 一侧
TABLE_HEADER_FG="${NFT_FORWARD_TABLE_HEADER_FG:-62}"
MENU_NOTICE=""

# ============== 日志函数 ==============
log_action() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ============== gum / UI 适配层 ==============
gum_enabled() {
    [[ "${GUM_ENABLED:-0}" == "1" ]] && command -v "$GUM_BIN" >/dev/null 2>&1
}

gum_available() {
    command -v "$GUM_BIN" >/dev/null 2>&1
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

ui_log() {
    local level="$1" msg="$2"
    if gum_enabled; then
        "$GUM_BIN" log --level "$level" "$msg" 2>/dev/null && return 0
    fi
    return 1
}

# ============== 输出辅助（用 printf 避免 echo -e 转义副作用） ==============
info() {
    ui_log info "$1" || printf '\033[32m[信息]\033[0m %s\n' "$1"
}

warn() {
    ui_log warn "$1" || printf '\033[33m[警告]\033[0m %s\n' "$1"
}

err() {
    ui_log error "$1" || printf '\033[31m[错误]\033[0m %s\n' "$1"
}

ui_section() {
    local title="$1"
    if gum_enabled; then
        "$GUM_BIN" style --bold "$title" || printf '\n%s\n' "$title"
    else
        printf '\n\033[1m%s\033[0m\n' "$title"
    fi
}

# 顶部品牌横幅（吊牌简化：gum 圆角框 + 文本；fallback 单行框）
ui_app_banner_fallback() {
    local line="$1"
    printf '\n\033[1m  ╭─ %s ─╯\033[0m\n' "$line"
}

ui_app_banner() {
    local line="${1:-}"
    if [[ -z "$line" ]]; then
        line="${APP_TITLE}"
        [[ -n "${APP_VERSION:-}" ]] && line="${APP_TITLE} ${APP_VERSION}"
    fi
    if gum_enabled; then
        "$GUM_BIN" style --border rounded --padding "0 2" --bold "$line" 2>/dev/null || ui_app_banner_fallback "$line"
    else
        ui_app_banner_fallback "$line"
    fi
}

# 进入子功能界面：清屏后输出工具品牌（非 TTY 时仅跳过清屏，仍输出横幅）
ui_begin_feature_screen() {
    clear_interactive_screen
    ui_app_banner
}

ui_subsection() {
    local title="$1"
    if gum_enabled; then
        "$GUM_BIN" style --bold "$title" || printf '\n--- %s ---\n' "$title"
    else
        printf '\n--- %s ---\n' "$title"
    fi
}

# 诊断页：列表式圆点；通过为「• 项名 + 绿色 ✓」，告警为「• 项名 + 黄色 ⚠」后接缩进「  • 说明」
ui_diag_item_ok() {
    local title="$1"
    local bullet=$'• '
    if gum_enabled; then
        printf '%s%s ' "$bullet" "$title"
        "$GUM_BIN" style --foreground 82 "✓"
        # gum style 已带换行，勿再 echo，否则每项之间多一空行
        return 0
    fi
    printf '%s%s \033[32m✓\033[0m\n' "$bullet" "$title"
}

ui_diag_item_warn() {
    local title="$1"
    local bullet=$'• '
    if gum_enabled; then
        printf '%s%s ' "$bullet" "$title"
        "$GUM_BIN" style --foreground 214 "⚠"
        return 0
    fi
    printf '%s%s \033[33m⚠\033[0m\n' "$bullet" "$title"
}

ui_diag_issue() {
    local msg="$1"
    local sub=$'  • '
    if gum_enabled; then
        "$GUM_BIN" style --foreground 246 "${sub}${msg}"
        return 0
    fi
    printf '%s%s\n' "$sub" "$msg"
}

ui_choose() {
    local prompt="$1" item value label selected choice
    shift

    if gum_enabled; then
        local labels=()
        for item in "$@"; do
            labels+=("${item#*|}")
        done

        selected="$("$GUM_BIN" choose --header "$prompt" "${labels[@]}")" || return 1
        [[ -n "$selected" ]] || return 1

        for item in "$@"; do
            value="${item%%|*}"
            label="${item#*|}"
            if [[ "$label" == "$selected" ]]; then
                printf '%s\n' "$value"
                return 0
            fi
        done
        return 1
    fi

    for item in "$@"; do
        value="${item%%|*}"
        label="${item#*|}"
        printf '  %s) %s\n' "$value" "$label"
    done

    while true; do
        printf '%s: ' "$prompt"
        IFS= read -r choice || return 1
        for item in "$@"; do
            value="${item%%|*}"
            if [[ "$choice" == "$value" ]]; then
                printf '%s\n' "$value"
                return 0
            fi
        done
        err "无效选择。"
    done
}

ui_input() {
    local prompt="$1" default_value="${2:-}" placeholder="${3:-请输入}"
    local -a gum_args=(input --prompt "${prompt} " --placeholder "$placeholder")
    if gum_enabled; then
        [[ -n "$default_value" ]] && gum_args+=(--value "$default_value")
        "${GUM_BIN}" "${gum_args[@]}"
        return
    fi

    local value=""
    IFS= read -r -p "${prompt} " value || return 1
    if [[ -z "$value" && -n "$default_value" ]]; then
        value="$default_value"
    fi
    printf '%s\n' "$value"
}

ui_confirm_yes_default() {
    local prompt="$1" confirm
    if gum_enabled; then
        "$GUM_BIN" confirm --default=true --affirmative "确认" --negative "取消" "$prompt"
        return
    fi

    IFS= read -r -p "$prompt [Y/n]: " confirm || return 1
    [[ ! "$confirm" =~ ^[Nn]$ ]]
}

ui_confirm_no_default() {
    local prompt="$1" confirm
    if gum_enabled; then
        "$GUM_BIN" confirm --default=false --affirmative "确认" --negative "取消" "$prompt"
        return
    fi

    IFS= read -r -p "$prompt [y/N]: " confirm || return 1
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# 终端对齐列表表头：与 TABLE_HEADER_FG（256 色数字）同色加粗；非数字则仅加粗 fallback
ansi_table_header_prefix() {
    if [[ "${TABLE_HEADER_FG}" =~ ^[0-9]+$ ]]; then
        printf '\033[1m\033[38;5;%sm' "${TABLE_HEADER_FG}"
    else
        printf '\033[1m'
    fi
}

ui_table() {
    if gum_enabled; then
        local input line_count height
        input="$(cat)"
        line_count="$(printf '%s\n' "$input" | wc -l | tr -d '[:space:]')"
        height=$((line_count + 2))
        if (( height > 12 )); then
            height=12
        fi
        printf '%s\n' "$input" | \
            GUM_TABLE_BORDER_FOREGROUND=240 \
            GUM_TABLE_HEADER_FOREGROUND="${TABLE_HEADER_FG}" \
            GUM_TABLE_HEADER_BOLD=true \
            "$GUM_BIN" table --separator $'\t' --height "$height" --border rounded || return 1
    else
        cat
    fi
}

ui_rule_choice() {
    local prompt="$1" item idx=1 rule lport target_host resolved_ip dport choice
    if gum_enabled; then
        local options=()
        options+=("0|取消")
        for rule in "${RULES[@]}"; do
            IFS='|' read -r _ lport target_host resolved_ip dport _ _ <<< "$rule"
            options+=("${idx}|${idx}. ${lport} (tcp+udp) -> $(format_rule_target "$target_host" "$resolved_ip" "$dport")")
            ((idx++))
        done
        ui_choose "$prompt" "${options[@]}"
        return
    fi

    IFS= read -r -p "${prompt} (0 取消): " choice || return 1
    printf '%s\n' "$choice"
}

ui_spin_shell() {
    local title="$1" command_text="$2"
    if gum_enabled; then
        "$GUM_BIN" spin --title "$title" --show-output -- bash -c "$command_text"
    else
        eval "$command_text"
    fi
}

clear_interactive_screen() {
    is_interactive_terminal || return 0
    if command -v clear >/dev/null 2>&1; then
        clear
    fi
}

# 交互式会话结束并即将 exit 调用：清屏，去掉横幅 / gum 残留的终端画面
interactive_terminal_exit_prepare() {
    is_interactive_terminal || return 0
    clear_interactive_screen
}

ui_before_menu() {
    clear_interactive_screen
}

ui_wait_return() {
    is_interactive_terminal || return 0
    local _
    printf '\n按回车返回主菜单...'
    IFS= read -r _ || true
}

ui_print_menu_notice() {
    [[ -n "${MENU_NOTICE:-}" ]] || return 0
    warn "$MENU_NOTICE"
    MENU_NOTICE=""
}

curl_with_timeout() {
    curl --connect-timeout "$GUM_CONNECT_TIMEOUT" --max-time "$GUM_MAX_TIME" "$@"
}

apt_get_with_timeout() {
    apt-get \
        -o "Acquire::http::Timeout=${GUM_APT_TIMEOUT}" \
        -o "Acquire::https::Timeout=${GUM_APT_TIMEOUT}" \
        "$@"
}

machine_arch() {
    uname -m
}

default_gum_deb_url() {
    case "$(machine_arch)" in
        x86_64|amd64)
            printf '%s\n' "$DEFAULT_GUM_DEB_AMD64_URL"
            ;;
        aarch64|arm64)
            printf '%s\n' "$DEFAULT_GUM_DEB_ARM64_URL"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_gum_deb_sha256() {
    local deb_file="$1" expected="${NFT_FORWARD_GUM_SHA256:-}"
    [[ -n "$expected" ]] || return 0

    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$deb_file" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$deb_file" | awk '{print $1}')"
    else
        warn "未检测到 sha256sum/shasum，无法校验 gum 安装包。"
        return 1
    fi

    [[ "$actual" == "$expected" ]]
}

install_gum_from_deb_url() {
    local deb_url="${NFT_FORWARD_GUM_DEB_URL:-}" deb_file
    if [[ -z "$deb_url" ]]; then
        deb_url="$(default_gum_deb_url)" || return 1
    fi

    deb_file="$(mktemp /tmp/nft-forward-gum.XXXXXX.deb)"
    if ! curl_with_timeout -fsSL -o "$deb_file" "$deb_url"; then
        rm -f "$deb_file" 2>/dev/null || true
        return 1
    fi
    if ! chmod 0644 "$deb_file"; then
        rm -f "$deb_file" 2>/dev/null || true
        return 1
    fi
    if ! verify_gum_deb_sha256 "$deb_file"; then
        rm -f "$deb_file" 2>/dev/null || true
        return 1
    fi
    if ! apt_get_with_timeout install -y "$deb_file"; then
        rm -f "$deb_file" 2>/dev/null || true
        return 1
    fi

    rm -f "$deb_file" 2>/dev/null || true
}

install_gum() {
    local pm
    pm="$(detect_pkg_manager)"

    case "$pm" in
        apt)
            install_gum_from_deb_url && return 0
            [[ "$GUM_ENABLE_CHARM_REPO_FALLBACK" == "1" ]] || return 1
            apt_get_with_timeout update -y &&
            apt_get_with_timeout install -y curl gpg ca-certificates &&
            mkdir -p /etc/apt/keyrings &&
            mkdir -p /etc/apt/sources.list.d &&
            curl_with_timeout -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg &&
            printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *' > /etc/apt/sources.list.d/charm.list &&
            apt_get_with_timeout update -y &&
            apt_get_with_timeout install -y gum
            ;;
        dnf|yum)
            [[ "$GUM_ENABLE_CHARM_REPO_FALLBACK" == "1" ]] || return 1
            mkdir -p /etc/yum.repos.d &&
            cat > /etc/yum.repos.d/charm.repo <<'EOF'
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key
EOF
            curl_with_timeout -fsSL https://repo.charm.sh/yum/gpg.key | rpm --import - &&
            "$pm" install -y gum
            ;;
        pacman)
            pacman -Sy --noconfirm gum
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_gum_available() {
    GUM_ENABLED=0
    GUM_INSTALL_FAILED=0

    if [[ "${NFT_FORWARD_DISABLE_GUM:-0}" == "1" ]]; then
        return 0
    fi
    if ! is_interactive_terminal; then
        return 0
    fi
    if gum_available; then
        GUM_ENABLED=1
        return 0
    fi

    if install_gum >/dev/null 2>&1 && gum_available; then
        GUM_ENABLED=1
        return 0
    fi

    GUM_ENABLED=0
    GUM_INSTALL_FAILED=1
    return 0
}

# ============== root 权限检查 ==============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要 root 权限运行，请使用 sudo 或 root 用户执行。"
        exit 1
    fi
}

# ============== 输入验证 ==============
validate_port() {
    local port="$1"
    # 拒绝非纯数字、前导零（避免 bash 八进制歧义）、空串
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" =~ ^0[0-9] ]]; then
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    # 拒绝前导零（避免 bash 八进制解析歧义，如 010 != 10）
    if [[ "$ip" =~ (^|\.)0[0-9] ]]; then
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            return 1
        fi
    done
    return 0
}

quota_gb_for_choice() {
    case "$1" in
        1) echo "0" ;;
        2) echo "50" ;;
        3) echo "100" ;;
        4) echo "200" ;;
        5) echo "300" ;;
        6) echo "400" ;;
        7) echo "500" ;;
        8) echo "800" ;;
        *) return 1 ;;
    esac
}

format_quota() {
    local quota_gb="$1"
    if [[ "$quota_gb" == "0" ]]; then
        echo "不限制"
    else
        echo "${quota_gb}G"
    fi
}

validate_remark() {
    local remark="${1:-}"
    [[ "$remark" != *"|"* ]] || return 1
    # 备注若含 TAB/换行会破坏 gum table 的 TSV 列与「已用流量」等对不齐
    [[ "$remark" != *$'\t'* ]] || return 1
    [[ "$remark" != *$'\n'* ]] || return 1
    [[ "$remark" != *$'\r'* ]] || return 1
    (( ${#remark} <= 40 )) || return 1
    return 0
}

validate_stored_remark() {
    local remark="${1:-}"
    [[ "$remark" != *"|"* ]] || return 1
    [[ "$remark" != *$'\t'* ]] || return 1
    [[ "$remark" != *$'\n'* ]] || return 1
    [[ "$remark" != *$'\r'* ]] || return 1
    return 0
}

format_remark() {
    local remark="${1:-}"
    if [[ -z "$remark" ]]; then
        printf '%s\n' "-"
    else
        printf '%s\n' "$remark"
    fi
}

validate_domain_name() {
    local domain="${1:-}" label
    [[ -n "$domain" ]] || return 1
    [[ "$domain" != *"|"* ]] || return 1
    [[ "$domain" != *$'\t'* ]] || return 1
    [[ "$domain" != *$'\n'* ]] || return 1
    [[ "$domain" != *$'\r'* ]] || return 1
    (( ${#domain} <= 253 )) || return 1
    [[ "$domain" == *"." ]] && domain="${domain%.}"
    [[ -n "$domain" ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" =~ ^[0-9.]+$ ]] && return 1

    local IFS='.'
    read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" ]] || return 1
        (( ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

validate_target_host() {
    local target="${1:-}"
    validate_ip "$target" || validate_domain_name "$target"
}

rule_target_is_domain() {
    local target="${1:-}"
    validate_ip "$target" && return 1
    validate_domain_name "$target"
}

format_table_target() {
    local ip="$1" port="$2"
    printf '%s:%s\n' "$ip" "$port"
}

format_rule_target() {
    local target_host="$1" resolved_ip="$2" port="$3"
    if [[ "$target_host" == "$resolved_ip" ]]; then
        format_table_target "$resolved_ip" "$port"
    else
        printf '%s(%s):%s\n' "$target_host" "$resolved_ip" "$port"
    fi
}

format_bytes() {
    local bytes="${1:-0}"
    if (( bytes <= 0 )); then
        echo "0B"
    elif (( bytes >= GB_BYTES )); then
        awk -v bytes="$bytes" -v gb="$GB_BYTES" 'BEGIN { printf "%.2fG\n", bytes / gb }'
    elif (( bytes >= 1000000 )); then
        awk -v bytes="$bytes" 'BEGIN { printf "%.2fM\n", bytes / 1000000 }'
    elif (( bytes >= 1000 )); then
        awk -v bytes="$bytes" 'BEGIN { printf "%.2fK\n", bytes / 1000 }'
    else
        printf '%sB\n' "$bytes"
    fi
}

remaining_days() {
    local period_start="${1:-0}" now="${2:-0}"
    local period_days=$((QUOTA_PERIOD_SECONDS / 86400))
    if (( period_start <= 0 )); then
        echo "$period_days"
        return 0
    fi

    local remaining_seconds=$((period_start + QUOTA_PERIOD_SECONDS - now))
    if (( remaining_seconds <= 0 )); then
        echo "0"
        return 0
    fi

    echo $(((remaining_seconds + 86400 - 1) / 86400))
}

# 配额计费周期结束日（YYYY-MM-DD），按 QUOTA_RESET_DISPLAY_TZ（默认北京时间）换算；period_start≤0 时按当前 epoch 起算周期末估算。
format_quota_period_reset_day() {
    local period_start="${1:-0}" now="${2:-0}"
    local reset_epoch tz formatted
    tz="${QUOTA_RESET_DISPLAY_TZ:-Asia/Shanghai}"
    reset_epoch=$((period_start + QUOTA_PERIOD_SECONDS))
    if (( period_start <= 0 )); then
        reset_epoch=$((now + QUOTA_PERIOD_SECONDS))
    fi

    # 优先 GNU/BSD date，对 TZ、闰秒等与系统一致；bash %T 在各版本上对 TZ 行为不一，作末路回填
    formatted="$(TZ="${tz}" LC_ALL=C date -d "@${reset_epoch}" '+%Y-%m-%d' 2>/dev/null)" || formatted=""
    [[ -n "$formatted" ]] && {
        printf '%s\n' "$formatted"
        return 0
    }

    formatted="$(TZ="${tz}" date -r "${reset_epoch}" '+%Y-%m-%d' 2>/dev/null)" || formatted=""
    [[ -n "$formatted" ]] && {
        printf '%s\n' "$formatted"
        return 0
    }

    if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        TZ="${tz}" LC_ALL=C printf '%(%Y-%m-%d)T\n' "${reset_epoch}"
        return 0
    fi

    printf '%s\n' "?"
}

rule_status_label() {
    local quota_gb="${1:-0}" blocked="${2:-0}"
    # 状态列仅有「耗尽」（限额用尽并已阻断转发）或「正常」（其余情况含「流量限制」为不限制）
    if [[ "$blocked" == "1" ]] && [[ "$quota_gb" != "0" ]]; then
        echo "耗尽"
    else
        echo "正常"
    fi
}

print_rules_table_tsv() {
    local idx=1 now
    local rule rule_id lport target_host resolved_ip dport quota_gb remark used_bytes blocked quota_label used_label days_label status_label remark_label
    now="$(now_epoch)"

    printf '序号\t协议\t本机端口\t目标地址\t流量限制\t已用流量\t下次重置\t状态\t备注\n'
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb remark <<< "$rule"
        used_bytes="$(state_get STATE_USED_BYTES "$rule_id" 0)"
        blocked="$(state_get STATE_BLOCKED "$rule_id" 0)"
        quota_label="$(format_quota "$quota_gb")"
        used_label="$(format_bytes "$used_bytes")"
        if [[ "$quota_gb" == "0" ]]; then
            days_label="-"
        else
            days_label="$(format_quota_period_reset_day "$(state_get STATE_PERIOD_START "$rule_id" 0)" "$now")"
        fi
        status_label="$(rule_status_label "$quota_gb" "$blocked")"
        remark_label="$(format_remark "$remark")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$idx" "tcp+udp" "$lport" "$(format_rule_target "$target_host" "$resolved_ip" "$dport")" "$quota_label" "$used_label" "$days_label" "$status_label" "$remark_label"
        ((idx++))
    done
}

select_quota_gb() {
    local choice quota_gb
    if gum_enabled; then
        "$GUM_BIN" style "说明：额度按单向回程流量统计，即目标服务器返回给客户端的流量；不是带宽速率限制。" >&2 || true
        choice="$(ui_choose "请选择月流量上限" \
            "1|不限制" \
            "2|50G" \
            "3|100G" \
            "4|200G" \
            "5|300G" \
            "6|400G" \
            "7|500G" \
            "8|800G")" || return 1
        quota_gb="$(quota_gb_for_choice "$choice")" || return 1
        printf '%s\n' "$quota_gb"
        return 0
    fi

    printf '\n请选择月流量上限：\n' >&2
    printf '说明：额度按单向回程流量统计，即目标服务器返回给客户端的流量；不是带宽速率限制。\n' >&2
    printf '  1) 不限制\n' >&2
    printf '  2) 50G\n' >&2
    printf '  3) 100G\n' >&2
    printf '  4) 200G\n' >&2
    printf '  5) 300G\n' >&2
    printf '  6) 400G\n' >&2
    printf '  7) 500G\n' >&2
    printf '  8) 800G\n' >&2
    while true; do
        printf '请选择月流量上限 [1-8]: ' >&2
        IFS= read -r choice || return 1
        quota_gb="$(quota_gb_for_choice "$choice")" || {
            printf '\033[31m[错误]\033[0m 请选择 1-8 之间的选项。\n' >&2
            continue
        }
        printf '%s\n' "$quota_gb"
        return 0
    done
}

make_rule_id() {
    local lport="$1" _target_host="$2" dport="$3"
    local stamp
    stamp="$(date +%s%N 2>/dev/null || date +%s)"
    stamp="${stamp//[^0-9]/}"
    if [[ -z "$stamp" ]]; then
        stamp="$(date +%s)"
    fi
    printf 'pf_%s_%s_%s\n' "$lport" "$dport" "$stamp"
}

make_legacy_rule_id() {
    local lport="$1" dip="$2" dport="$3"
    local safe_ip="${dip//./_}"
    echo "pf_${lport}_${safe_ip}_${dport}"
}

validate_quota_gb() {
    case "$1" in
        0|50|100|200|300|400|500|800) return 0 ;;
        *) return 1 ;;
    esac
}

# ============== 自动获取本机 IP ==============
get_local_ip() {
    local ip
    # 优先取默认路由出口的 IP（最准确：这就是发包时实际使用的源 IP）
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    # 回退：取第一个非 lo 接口的 IP
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    # 最终回退
    hostname -I 2>/dev/null | awk '{print $1}' || true
}

# 按目标地址选择 SNAT 源地址，适配非默认路由、内网、隧道等目标路径
get_snat_ip_for_dest() {
    local dest_ip="$1" route_src
    route_src="$(ip route get "$dest_ip" 2>/dev/null | awk '{
        for (i = 1; i < NF; i++) {
            if ($i == "src") {
                print $(i + 1)
                exit
            }
        }
    }')" || true
    if [[ -n "$route_src" ]]; then
        printf '%s\n' "$route_src"
        return 0
    fi
    get_local_ip
}

resolve_target_ipv4() {
    local target_host="$1" candidate line

    if validate_ip "$target_host"; then
        printf '%s\n' "$target_host"
        return 0
    fi

    validate_domain_name "$target_host" || return 1

    if command -v getent >/dev/null 2>&1; then
        while IFS= read -r line; do
            candidate="${line%%[[:space:]]*}"
            if validate_ip "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(getent ahostsv4 "$target_host" 2>/dev/null || true)
    fi

    if command -v dig >/dev/null 2>&1; then
        while IFS= read -r candidate; do
            if validate_ip "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(dig +short A "$target_host" 2>/dev/null || true)
    fi

    if command -v host >/dev/null 2>&1; then
        while IFS= read -r line; do
            candidate="${line##* has address }"
            if [[ "$candidate" != "$line" ]] && validate_ip "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(host "$target_host" 2>/dev/null || true)
    fi

    return 1
}

# ============== 发行版检测 ==============
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# ============== iptables 可用性检测 ==============
# 不依赖 systemd 服务，而是检测命令是否存在且能读取规则
has_iptables() {
    command -v iptables &>/dev/null && iptables -S &>/dev/null
}

has_systemctl() {
    command -v systemctl &>/dev/null
}

# ============== iptables 规则持久化尝试 ==============
try_persist_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && return 0
    fi
    if command -v iptables-save &>/dev/null; then
        if [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
        elif [[ -d /etc/sysconfig ]]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null && return 0
        fi
    fi
    if command -v service &>/dev/null; then
        service iptables save >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ============== 检查目标是否仍被其他规则使用 ==============
# 参数: $1=目标IP  $2=目标端口  $3=要排除的本机端口(即正在删除的那条)
dest_still_used() {
    local check_ip="$1" check_dport="$2" exclude_lport="$3"
    local rule lport resolved_ip dport
    for rule in "${RULES[@]}"; do
        IFS='|' read -r _ lport _ resolved_ip dport _ _ <<< "$rule"
        # 跳过正在删除的那条
        [[ "$lport" == "$exclude_lport" ]] && continue
        # 如果其他规则也指向同一 dest_ip:dport，返回 true
        if [[ "$resolved_ip" == "$check_ip" && "$dport" == "$check_dport" ]]; then
            return 0
        fi
    done
    return 1
}

# ============== firewalld / iptables 端口放行 ==============
# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口
firewalld_forward_rule_add() {
    local dest_ip="$1" dport="$2"
    firewall-cmd --direct --permanent --add-rule ipv4 filter FORWARD 0 -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --add-rule ipv4 filter FORWARD 0 -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --add-rule ipv4 filter FORWARD 0 -s "${dest_ip}" -p tcp --sport "${dport}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --add-rule ipv4 filter FORWARD 0 -s "${dest_ip}" -p udp --sport "${dport}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewalld_forward_rule_remove() {
    local dest_ip="$1" dport="$2"
    firewall-cmd --direct --permanent --remove-rule ipv4 filter FORWARD 0 -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --remove-rule ipv4 filter FORWARD 0 -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --remove-rule ipv4 filter FORWARD 0 -s "${dest_ip}" -p tcp --sport "${dport}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --direct --permanent --remove-rule ipv4 filter FORWARD 0 -s "${dest_ip}" -p udp --sport "${dport}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
}

firewall_open_port() {
    local lport="$1" dest_ip="$2" dport="$3"

    # firewalld 优先：如果 firewalld 在运行，只用 firewall-cmd，不碰 iptables
    # （firewalld 可能以 iptables 为后端，手动插 iptables 规则会被 reload 冲掉）
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --add-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
        firewalld_forward_rule_add "$dest_ip" "$dport"
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "已在 firewalld 中放行端口 ${lport} 及转发到 ${dest_ip}:${dport} (tcp+udp)。"
        log_action "firewalld 放行端口 ${lport} 转发到 ${dest_ip}:${dport}"
        return
    fi

    # UFW: Ubuntu 小白最常见的防火墙
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        # INPUT: 放行进入本机的流量
        ufw allow "${lport}/tcp" >/dev/null 2>&1 || true
        ufw allow "${lport}/udp" >/dev/null 2>&1 || true
        # FORWARD: ufw allow 只管 INPUT，转发流量需要 route allow
        ufw route allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        ufw route allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        info "已在 UFW 中放行端口 ${lport} 及转发到 ${dest_ip}:${dport} (tcp+udp)。"
        log_action "UFW 放行端口 ${lport} 转发到 ${dest_ip}:${dport}"
        return
    fi

    # 无 firewalld / UFW，检测 iptables
    if has_iptables; then
        # INPUT 链: 放行进入本机的流量（匹配 DNAT 前的本机端口）
        iptables -C INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        # FORWARD 链: DNAT 后包的目的地已改写为 dest_ip:dport，需按此匹配
        iptables -C FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        # FORWARD 链: 放行回程已建立连接的包（DNAT 转发场景标配）
        iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        info "已在 iptables 中放行: INPUT ${lport}, FORWARD → ${dest_ip}:${dport} (tcp+udp)。"
        log_action "iptables 放行 INPUT:${lport} FORWARD:${dest_ip}:${dport}"
        if ! try_persist_iptables; then
            warn "iptables 规则已生效但未能自动持久化，重启后可能丢失。"
            warn "如需持久化请安装 iptables-persistent / netfilter-persistent。"
        fi
    fi
}

# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口  $4=是否跳过共享检查("force" 表示强制删除)
firewall_close_port() {
    local lport="$1" dest_ip="$2" dport="$3" force="${4:-}"

    # firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --remove-port="${lport}/tcp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --remove-port="${lport}/udp" --permanent >/dev/null 2>&1 || true
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            firewalld_forward_rule_remove "$dest_ip" "$dport"
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "已从 firewalld 中移除端口 ${lport} 及转发到 ${dest_ip}:${dport} 的放行规则。"
        log_action "firewalld 移除端口 ${lport} 转发到 ${dest_ip}:${dport}"
        return
    fi

    # UFW（用 yes 管道防止 ufw delete 交互询问卡住脚本）
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        yes | ufw delete allow "${lport}/tcp" >/dev/null 2>&1 || true
        yes | ufw delete allow "${lport}/udp" >/dev/null 2>&1 || true
        # route 规则按目标匹配，只有在没有其他规则共享同一目标时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            yes | ufw route delete allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
            yes | ufw route delete allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        fi
        info "已从 UFW 中移除端口 ${lport} 的放行规则。"
        log_action "UFW 移除端口 ${lport}"
        return
    fi

    # iptables
    if has_iptables; then
        # INPUT 链: 总是删除（lport 是唯一的）
        iptables -D INPUT -p tcp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "${lport}" -j ACCEPT 2>/dev/null || true
        # FORWARD 链: 只有在没有其他规则共享同一 dest_ip:dport 时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            iptables -D FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        fi
        # 注意: 不删除 ESTABLISHED,RELATED 规则，它是通用规则，其他转发可能还需要
        info "已从 iptables 中移除: INPUT ${lport}, FORWARD → ${dest_ip}:${dport}。"
        log_action "iptables 移除 INPUT:${lport} FORWARD:${dest_ip}:${dport}"
        try_persist_iptables || true
    fi
}

# 只移除目标侧 FORWARD/route 放行，保留本机监听端口放行。
firewall_close_forward_target() {
    local lport="$1" dest_ip="$2" dport="$3"

    if [[ ! "$lport" =~ ^[0-9]+$ ]] || ! validate_ip "$dest_ip" || ! validate_port "$dport"; then
        return 0
    fi

    if dest_still_used "$dest_ip" "$dport" "$lport"; then
        return 0
    fi

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewalld_forward_rule_remove "$dest_ip" "$dport"
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_action "firewalld 移除旧转发目标 ${dest_ip}:${dport}"
        return
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        yes | ufw route delete allow proto tcp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        yes | ufw route delete allow proto udp to "${dest_ip}" port "${dport}" >/dev/null 2>&1 || true
        log_action "UFW 移除旧转发目标 ${dest_ip}:${dport}"
        return
    fi

    if has_iptables; then
        iptables -D FORWARD -d "${dest_ip}" -p tcp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -d "${dest_ip}" -p udp --dport "${dport}" -j ACCEPT 2>/dev/null || true
        try_persist_iptables || true
        log_action "iptables 移除旧转发目标 ${dest_ip}:${dport}"
    fi
}

# ============== 端口占用检测（TCP + UDP） ==============
check_port_conflict() {
    local port="$1"
    local conflict=""
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        conflict="TCP"
    fi
    if ss -ulnp 2>/dev/null | grep -qE ":${port}\b"; then
        if [[ -n "$conflict" ]]; then
            conflict="TCP+UDP"
        else
            conflict="UDP"
        fi
    fi
    if [[ -n "$conflict" ]]; then
        warn "本机端口 ${port} 已被其他服务占用（${conflict}）。"
        warn "添加转发后，该端口的外部流量将被转发，本地服务可能无法从外部访问。"
        if ! ui_confirm_no_default "是否仍要继续添加转发规则？"; then
            return 1
        fi
    fi
    return 0
}

# ============== 初始化配置文件结构 ==============
init_conf() {
    mkdir -p "${CONF_DIR}" "${BACKUP_DIR}" "$(dirname "${LOG_FILE}")" "$(dirname "${LOGROTATE_CONF}")" 2>/dev/null || {
        err "无法创建配置目录 ${CONF_DIR}，请检查权限。"
        return 1
    }

    # 确保日志文件存在
    touch "${LOG_FILE}" 2>/dev/null || true

    # 创建 logrotate 配置
    if [[ ! -f "${LOGROTATE_CONF}" ]]; then
        cat > "${LOGROTATE_CONF}" <<LOGROTATE
${LOG_FILE} {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LOGROTATE
    fi

    # 确保主配置存在且包含 include
    if [[ ! -f "${MAIN_CONF}" ]]; then
        # 极简系统可能没有 nftables.conf，创建最小文件确保重启后规则自动加载
        cat > "${MAIN_CONF}" <<NFTCONF
#!/usr/sbin/nft -f
flush ruleset
${CONF_INCLUDE_LINE}
NFTCONF
        info "已创建 ${MAIN_CONF}（系统中不存在该文件）。"
        log_action "创建 ${MAIN_CONF}"
    elif ! grep -qF "${CONF_INCLUDE_LINE}" "${MAIN_CONF}" 2>/dev/null; then
        echo "${CONF_INCLUDE_LINE}" >> "${MAIN_CONF}"
        info "已在 ${MAIN_CONF} 中添加 include 指令。"
        log_action "在 ${MAIN_CONF} 中添加 include 指令"
    fi

    # 如果转发配置文件不存在，创建初始结构
    if [[ ! -f "${CONF_FILE}" ]]; then
        write_conf_file || return 1
    fi
}

# ============== 安装流量检查 systemd timer ==============
install_traffic_timer() {
    local tmp_service tmp_timer service_unit
    mkdir -p "${SYSTEMD_DIR}" 2>/dev/null || {
        warn "无法创建 systemd 目录 ${SYSTEMD_DIR}，流量限制不会自动执行。"
        return 1
    }
    if [[ -d "${TRAFFIC_SERVICE_FILE}" ]]; then
        warn "无法写入 systemd service ${TRAFFIC_SERVICE_FILE}，流量限制不会自动执行。"
        return 1
    fi
    if [[ -d "${TRAFFIC_TIMER_FILE}" ]]; then
        warn "无法写入 systemd timer ${TRAFFIC_TIMER_FILE}，流量限制不会自动执行。"
        return 1
    fi

    tmp_service="${TRAFFIC_SERVICE_FILE}.tmp.$$"
    tmp_timer="${TRAFFIC_TIMER_FILE}.tmp.$$"
    service_unit="$(basename "${TRAFFIC_SERVICE_FILE}")"

    if ! cat > "${tmp_service}" <<EOF
[Unit]
Description=nft-forward traffic quota check

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} --traffic-check
EOF
    then
        rm -f "${tmp_service}" "${tmp_timer}" 2>/dev/null || true
        warn "无法写入 systemd service ${TRAFFIC_SERVICE_FILE}，流量限制不会自动执行。"
        return 1
    fi
    if ! mv -f "${tmp_service}" "${TRAFFIC_SERVICE_FILE}" 2>/dev/null; then
        rm -f "${tmp_service}" "${tmp_timer}" 2>/dev/null || true
        warn "无法写入 systemd service ${TRAFFIC_SERVICE_FILE}，流量限制不会自动执行。"
        return 1
    fi

    if ! cat > "${tmp_timer}" <<EOF
[Unit]
Description=Run nft-forward traffic and domain refresh check every 2 minutes

[Timer]
Unit=${service_unit}
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    then
        rm -f "${tmp_service}" "${tmp_timer}" 2>/dev/null || true
        warn "无法写入 systemd timer ${TRAFFIC_TIMER_FILE}，流量限制不会自动执行。"
        return 1
    fi
    if ! mv -f "${tmp_timer}" "${TRAFFIC_TIMER_FILE}" 2>/dev/null; then
        rm -f "${tmp_service}" "${tmp_timer}" 2>/dev/null || true
        warn "无法写入 systemd timer ${TRAFFIC_TIMER_FILE}，流量限制不会自动执行。"
        return 1
    fi

    if [[ -n "${NFT_FORWARD_TEST_MODE:-}" ]]; then
        return 0
    fi

    if has_systemctl; then
        ui_spin_shell "重载 systemd" "systemctl daemon-reload >/dev/null 2>&1" || true
        if ui_spin_shell "启用流量检查 timer" "systemctl enable --now \"$(basename "${TRAFFIC_TIMER_FILE}")\" >/dev/null 2>&1"; then
            info "已启用流量限制定时检查。"
            log_action "启用流量限制定时检查"
        else
            warn "流量限制定时检查启用失败，请手动执行: systemctl enable --now $(basename "${TRAFFIC_TIMER_FILE}")"
            return 1
        fi
    else
        warn "未检测到 systemctl，流量限制不会自动执行。"
        return 1
    fi
}

timer_unit_needs_install() {
    local expected_execstart

    if [[ ! -f "${TRAFFIC_SERVICE_FILE}" || ! -f "${TRAFFIC_TIMER_FILE}" ]]; then
        return 0
    fi

    expected_execstart="ExecStart=${SCRIPT_PATH} --traffic-check"
    if ! grep -qF "${expected_execstart}" "${TRAFFIC_SERVICE_FILE}" 2>/dev/null; then
        return 0
    fi
    if ! grep -qF "OnUnitActiveSec=2min" "${TRAFFIC_TIMER_FILE}" 2>/dev/null; then
        return 0
    fi
    if ! grep -qF "traffic and domain refresh check every 2 minutes" "${TRAFFIC_TIMER_FILE}" 2>/dev/null; then
        return 0
    fi
    if ! has_systemctl; then
        return 0
    fi

    local timer_name timer_enabled timer_active
    timer_name="$(basename "${TRAFFIC_TIMER_FILE}")"
    timer_enabled=$(systemctl is-enabled "$timer_name" 2>/dev/null) || timer_enabled="unknown"
    timer_active=$(systemctl is-active "$timer_name" 2>/dev/null) || timer_active="unknown"

    [[ "$timer_enabled" == "enabled" && "$timer_active" == "active" ]] && return 1
    return 0
}

source_script_path() {
    printf '%s\n' "${BASH_SOURCE[0]}"
}

is_regular_readable_script_source() {
    local source_path="$1"
    [[ -n "$source_path" && -f "$source_path" && -r "$source_path" ]]
}

download_current_script_to_temp() {
    local tmp_script
    tmp_script="$(mktemp /tmp/nft-forward-script.XXXXXX)" || return 1
    if ! curl_with_timeout -fsSL -o "$tmp_script" "$SCRIPT_URL"; then
        rm -f "$tmp_script" 2>/dev/null || true
        return 1
    fi
    if ! bash -n "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "$tmp_script"
}

install_script_source_to_script_path() {
    local source_path="$1"
    if install -m 0755 "$source_path" "${SCRIPT_PATH}" 2>/dev/null; then
        info "已安装脚本到 ${SCRIPT_PATH}，用于流量限制定时检查。"
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        log_action "安装脚本到 ${SCRIPT_PATH}"
        return 0
    fi

    return 1
}

install_current_script_to_script_path() {
    local source_path tmp_source=""
    source_path="$(source_script_path)"
    if is_regular_readable_script_source "$source_path" && [[ -x "${SCRIPT_PATH}" ]] && cmp -s "$source_path" "${SCRIPT_PATH}" 2>/dev/null; then
        return 0
    fi

    mkdir -p "$(dirname "${SCRIPT_PATH}")" 2>/dev/null || {
        warn "无法创建脚本安装目录 $(dirname "${SCRIPT_PATH}")，流量限制不会自动执行。"
        return 1
    }

    if is_regular_readable_script_source "$source_path"; then
        if install_script_source_to_script_path "$source_path"; then
            return 0
        fi
    else
        tmp_source="$(download_current_script_to_temp)" || {
            warn "无法从 ${SCRIPT_URL} 下载脚本，流量限制不会自动执行。"
            return 1
        }
        if install_script_source_to_script_path "$tmp_source"; then
            rm -f "$tmp_source" 2>/dev/null || true
            return 0
        fi
        rm -f "$tmp_source" 2>/dev/null || true
    fi

    warn "无法安装脚本到 ${SCRIPT_PATH}，流量限制不会自动执行。"
    return 1
}

ensure_traffic_timer_installed() {
    if ! install_current_script_to_script_path; then
        return 1
    fi

    timer_unit_needs_install || return 0
    install_traffic_timer
}

# ============== 写出配置文件（基于当前 RULES 数组） ==============
# RULES 数组格式: "rule_id|本机端口|target_host|resolved_ip|目标端口|quota_gb|备注"
declare -a RULES=()
declare -a STATE_PERIOD_START=()
declare -a STATE_USED_BYTES=()
declare -a STATE_LAST_COUNTER=()
declare -a STATE_BLOCKED=()
declare -a STATE_TRACKED_RULE_IDS=()
STATE_ASSOC_SUPPORTED=0

if declare -A __state_assoc_probe 2>/dev/null; then
    unset __state_assoc_probe
    unset STATE_PERIOD_START STATE_USED_BYTES STATE_LAST_COUNTER STATE_BLOCKED
    declare -A STATE_PERIOD_START=()
    declare -A STATE_USED_BYTES=()
    declare -A STATE_LAST_COUNTER=()
    declare -A STATE_BLOCKED=()
    STATE_ASSOC_SUPPORTED=1
fi

is_nonnegative_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_rule_id() {
    local rule_id="${1:-}"
    [[ "$rule_id" =~ ^pf_[0-9]+_([0-9]{1,3}_){3}[0-9]{1,3}_[0-9]+$ ]] && return 0
    [[ "$rule_id" =~ ^pf_[0-9]+_[0-9]+_[0-9]{10,}$ ]] && return 0
    return 1
}

parse_rule_metadata_line() {
    local line="$1"
    local -a fields
    local rule_id lport target_host resolved_ip dport quota_gb remark

    IFS='|' read -r -a fields <<< "$line"

    case "${#fields[@]}" in
        5)
            rule_id="${fields[0]}"
            lport="${fields[1]}"
            target_host="${fields[2]}"
            resolved_ip="${fields[2]}"
            dport="${fields[3]}"
            quota_gb="${fields[4]}"
            remark=""
            ;;
        6)
            rule_id="${fields[0]}"
            lport="${fields[1]}"
            if validate_target_host "${fields[2]}" && \
               validate_ip "${fields[3]}" && \
               validate_port "${fields[4]}" && \
               validate_quota_gb "${fields[5]}"; then
                target_host="${fields[2]}"
                resolved_ip="${fields[3]}"
                dport="${fields[4]}"
                quota_gb="${fields[5]}"
                remark=""
            else
                target_host="${fields[2]}"
                resolved_ip="${fields[2]}"
                dport="${fields[3]}"
                quota_gb="${fields[4]}"
                remark="${fields[5]}"
            fi
            ;;
        7)
            rule_id="${fields[0]}"
            lport="${fields[1]}"
            target_host="${fields[2]}"
            resolved_ip="${fields[3]}"
            dport="${fields[4]}"
            quota_gb="${fields[5]}"
            remark="${fields[6]}"
            ;;
        *)
            return 1
            ;;
    esac

    validate_rule_id "$rule_id" || return 1
    validate_port "$lport" || return 1
    validate_target_host "$target_host" || return 1
    validate_ip "$resolved_ip" || return 1
    validate_port "$dport" || return 1
    validate_quota_gb "${quota_gb:-}" || return 1
    validate_stored_remark "${remark:-}" || return 1

    printf '%s|%s|%s|%s|%s|%s|%s\n' "$rule_id" "$lport" "$target_host" "$resolved_ip" "$dport" "$quota_gb" "${remark:-}"
}

track_state_rule_id() {
    local rule_id="$1"
    local existing
    for existing in "${STATE_TRACKED_RULE_IDS[@]-}"; do
        [[ "$existing" == "$rule_id" ]] && return 0
    done
    STATE_TRACKED_RULE_IDS+=("$rule_id")
}

reset_state_maps() {
    local rule_id
    if [[ "$STATE_ASSOC_SUPPORTED" == "1" ]]; then
        STATE_PERIOD_START=()
        STATE_USED_BYTES=()
        STATE_LAST_COUNTER=()
        STATE_BLOCKED=()
    else
        for rule_id in "${STATE_TRACKED_RULE_IDS[@]-}"; do
            unset "STATE_PERIOD_START__${rule_id}" \
                  "STATE_USED_BYTES__${rule_id}" \
                  "STATE_LAST_COUNTER__${rule_id}" \
                  "STATE_BLOCKED__${rule_id}"
        done
    fi
    STATE_TRACKED_RULE_IDS=()
}

state_exists() {
    local map_name="$1" rule_id="$2"
    validate_rule_id "$rule_id" || return 1
    if [[ "$STATE_ASSOC_SUPPORTED" == "1" ]]; then
        eval '[[ -n "${'"$map_name"'["$rule_id"]+x}" ]]'
    else
        eval '[[ -n "${'"${map_name}__${rule_id}"'+x}" ]]'
    fi
}

state_get() {
    local map_name="$1" rule_id="$2" default_value="${3:-0}"
    local value=""
    validate_rule_id "$rule_id" || {
        printf '%s' "$default_value"
        return 0
    }
    if [[ "$STATE_ASSOC_SUPPORTED" == "1" ]]; then
        eval 'value="${'"$map_name"'["$rule_id"]-}"'
    else
        eval 'value="${'"${map_name}__${rule_id}"'-}"'
    fi
    if [[ -n "$value" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default_value"
    fi
}

state_set() {
    local map_name="$1" rule_id="$2" value="$3"
    validate_rule_id "$rule_id" || return 1
    track_state_rule_id "$rule_id"
    if [[ "$STATE_ASSOC_SUPPORTED" == "1" ]]; then
        eval "$map_name[\"\$rule_id\"]=\"\$value\""
    else
        printf -v "${map_name}__${rule_id}" '%s' "$value"
    fi
}

now_epoch() {
    date +%s
}

read_counter_bytes() {
    local counter_name="$1"
    local output
    output="$(nft list counter ip "$TABLE_NAME" "$counter_name" 2>/dev/null)" || return 1
    if [[ "$output" =~ bytes[[:space:]]+([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

counter_delta() {
    local current="${1:-0}" last="${2:-0}"
    if (( current >= last )); then
        echo $((current - last))
    else
        # 计数回落通常表示 nft counter 被重建；当前值是重建后已经发生的新回程流量
        echo "$current"
    fi
}

# nft 整表重载后 egress 计数器重新从 0 计起，写入当前读数以对齐 LAST（不修改已用量/周期）
sync_egress_counter_baselines_after_nft_reload() {
    command -v nft >/dev/null 2>&1 || return 0
    load_rules >/dev/null 2>&1 || return 0
    [[ ${#RULES[@]} -gt 0 ]] || return 0
    load_traffic_state || return 0
    local rule rule_id cur last_v changed=0
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id _ _ _ _ _ _ <<< "$rule"
        validate_rule_id "$rule_id" || continue
        cur="$(read_counter_bytes "${rule_id}_egress")" || continue
        last_v="$(state_get STATE_LAST_COUNTER "$rule_id" 0)"
        if [[ "${last_v}" != "${cur}" ]]; then
            state_set STATE_LAST_COUNTER "$rule_id" "$cur"
            changed=1
        fi
    done
    if (( changed == 1 )); then
        save_traffic_state 2>/dev/null || true
    fi
    return 0
}

ensure_state_for_rules() {
    local rule rule_id
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id _ _ _ _ _ _ <<< "$rule"
        validate_rule_id "$rule_id" || continue
        # period_start=0 表示尚未开始真实采样；Task 7 接入 counter 后会在首次采样时写入。
        state_exists STATE_PERIOD_START "$rule_id" || state_set STATE_PERIOD_START "$rule_id" 0
        state_exists STATE_USED_BYTES "$rule_id" || state_set STATE_USED_BYTES "$rule_id" 0
        state_exists STATE_LAST_COUNTER "$rule_id" || state_set STATE_LAST_COUNTER "$rule_id" 0
        state_exists STATE_BLOCKED "$rule_id" || state_set STATE_BLOCKED "$rule_id" 0
    done
}

load_traffic_state() {
    reset_state_maps

    if [[ ! -f "${STATE_FILE}" ]]; then
        ensure_state_for_rules
        return 0
    fi

    local line rule_id period_start used_bytes last_counter blocked
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        IFS='|' read -r rule_id period_start used_bytes last_counter blocked <<< "$line"
        if validate_rule_id "$rule_id" && \
           is_nonnegative_integer "$period_start" && \
           is_nonnegative_integer "$used_bytes" && \
           is_nonnegative_integer "$last_counter" && \
           [[ "${blocked:-}" =~ ^[01]$ ]]; then
            state_set STATE_PERIOD_START "$rule_id" "$period_start"
            state_set STATE_USED_BYTES "$rule_id" "$used_bytes"
            state_set STATE_LAST_COUNTER "$rule_id" "$last_counter"
            state_set STATE_BLOCKED "$rule_id" "$blocked"
        else
            warn "跳过无效流量状态: ${line}"
        fi
    done < "${STATE_FILE}"

    ensure_state_for_rules
}

save_traffic_state() {
    mkdir -p "${STATE_DIR}" 2>/dev/null || {
        err "无法创建状态目录 ${STATE_DIR}"
        return 1
    }

    ensure_state_for_rules

    local tmp_file="${STATE_FILE}.tmp.$$"
    {
        echo "# nft-forward traffic state"
        echo "# format: rule_id|period_start|used_bytes|last_counter|blocked"
        local rule rule_id
        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id _ _ _ _ _ _ <<< "$rule"
            validate_rule_id "$rule_id" || continue
            printf '%s|%s|%s|%s|%s\n' \
                "$rule_id" \
                "$(state_get STATE_PERIOD_START "$rule_id" 0)" \
                "$(state_get STATE_USED_BYTES "$rule_id" 0)" \
                "$(state_get STATE_LAST_COUNTER "$rule_id" 0)" \
                "$(state_get STATE_BLOCKED "$rule_id" 0)"
        done
    } > "${tmp_file}" || {
        err "无法写入临时状态文件 ${tmp_file}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }

    mv -f "${tmp_file}" "${STATE_FILE}" 2>/dev/null || {
        err "无法写入状态文件 ${STATE_FILE}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }
}

reset_rule_state() {
    local rule_id="$1" now="$2" last_counter="$3"
    state_set STATE_PERIOD_START "$rule_id" "$now" || return 1
    state_set STATE_USED_BYTES "$rule_id" 0 || return 1
    state_set STATE_LAST_COUNTER "$rule_id" "$last_counter" || return 1
    state_set STATE_BLOCKED "$rule_id" 0 || return 1
}

rollover_expired_periods() {
    local now="${1:-0}"
    ensure_state_for_rules

    local rule rule_id period_start
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id _ _ _ _ _ _ <<< "$rule"
        validate_rule_id "$rule_id" || continue
        period_start="$(state_get STATE_PERIOD_START "$rule_id" 0)"
        if (( period_start > 0 )) && (( now - period_start >= QUOTA_PERIOD_SECONDS )); then
            state_set STATE_PERIOD_START "$rule_id" "$now"
            state_set STATE_USED_BYTES "$rule_id" 0
            state_set STATE_BLOCKED "$rule_id" 0
        fi
    done
}

quota_bytes() {
    local quota_gb="${1:-0}"
    echo $((quota_gb * GB_BYTES))
}

is_rule_blocked() {
    local rule_id="$1"
    [[ "$(state_get STATE_BLOCKED "$rule_id" 0)" == "1" ]]
}

rule_fields_from_id() {
    local rule_id="$1"
    validate_rule_id "$rule_id" || return 1
    local rest lport dport safe_ip dip
    rest="${rule_id#pf_}"
    lport="${rest%%_*}"
    rest="${rest#${lport}_}"
    dport="${rest##*_}"
    safe_ip="${rest%_${dport}}"
    dip="${safe_ip//_/.}"
    validate_port "$lport" && validate_ip "$dip" && validate_port "$dport" || return 1
    printf '%s|%s|%s\n' "$lport" "$dip" "$dport"
}

rule_ports_from_timestamp_id() {
    local rule_id="$1"
    local lport dport
    [[ "$rule_id" =~ ^pf_([0-9]+)_([0-9]+)_[0-9]{10,}$ ]] || return 1
    lport="${BASH_REMATCH[1]}"
    dport="${BASH_REMATCH[2]}"
    validate_port "$lport" && validate_port "$dport" || return 1
    printf '%s|%s\n' "$lport" "$dport"
}

rule_fields_from_generated_conf() {
    local rule_id="$1"
    local parsed lport dport line conf_lport dip conf_dport

    if parsed="$(rule_fields_from_id "$rule_id")"; then
        printf '%s\n' "$parsed"
        return 0
    fi

    parsed="$(rule_ports_from_timestamp_id "$rule_id")" || return 1
    IFS='|' read -r lport dport <<< "$parsed"

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        parsed="$(parse_dnat_rule_line "$line")" || continue
        IFS='|' read -r conf_lport dip conf_dport <<< "$parsed"
        if [[ "$conf_lport" == "$lport" && "$conf_dport" == "$dport" ]]; then
            printf '%s|%s|%s\n' "$lport" "$dip" "$dport"
            return 0
        fi
    done < "${CONF_FILE}"

    return 1
}

migrate_legacy_rules_if_needed() {
    if [[ -f "${RULES_FILE}" ]] || [[ ! -f "${CONF_FILE}" ]]; then
        return 0
    fi

    local migrated=()
    local line parsed lport dip dport rule_id
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if parsed="$(parse_generated_counter_rule_line "$line")"; then
            rule_id="$parsed"
            parsed="$(rule_fields_from_generated_conf "$rule_id")" || continue
            IFS='|' read -r lport dip dport <<< "$parsed"
            migrated+=("${rule_id}|${lport}|${dip}|${dip}|${dport}|0|")
        fi
    done < "${CONF_FILE}"

    if [[ ${#migrated[@]} -eq 0 ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            parsed="$(parse_dnat_rule_line "$line")" || continue
            IFS='|' read -r lport dip dport <<< "$parsed"
            rule_id="$(make_legacy_rule_id "$lport" "$dip" "$dport")"
            migrated+=("${rule_id}|${lport}|${dip}|${dip}|${dport}|0|")
        done < "${CONF_FILE}"
    fi

    if [[ ${#migrated[@]} -eq 0 ]]; then
        return 0
    fi

    RULES=("${migrated[@]}")
    write_rules_file || return 1
    load_traffic_state
    save_traffic_state || return 1
    log_action "迁移旧转发配置到 ${RULES_FILE}"
}

legacy_conf_has_rules() {
    [[ -f "${CONF_FILE}" ]] || return 1
    local line
    while IFS= read -r line; do
        parse_generated_counter_rule_line "$line" >/dev/null && return 0
        parse_dnat_rule_line "$line" >/dev/null && return 0
    done < "${CONF_FILE}"
    return 1
}

metadata_rule_id_matches_fields() {
    local rule_id="$1" lport="$2" resolved_ip="$3" dport="$4"
    local parsed id_lport id_ip id_dport

    if parsed="$(rule_fields_from_id "$rule_id")"; then
        IFS='|' read -r id_lport id_ip id_dport <<< "$parsed"
        [[ "$lport" == "$id_lport" && "$resolved_ip" == "$id_ip" && "$dport" == "$id_dport" ]]
        return
    fi

    if parsed="$(rule_ports_from_timestamp_id "$rule_id")"; then
        IFS='|' read -r id_lport id_dport <<< "$parsed"
        [[ "$lport" == "$id_lport" && "$dport" == "$id_dport" ]]
        return
    fi

    return 1
}

metadata_matches_legacy_conf_rules() {
    [[ -f "${RULES_FILE}" ]] || return 1
    [[ -f "${CONF_FILE}" ]] || return 0

    local -a legacy_rules=()
    local -a generated_rule_ids=()
    local -a metadata_rules=()
    local line parsed lport target_host resolved_ip dport rule_id quota_gb remark dip

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        rule_id="$(parse_generated_counter_rule_line "$line")" || continue
        generated_rule_ids+=("$rule_id")
    done < "${CONF_FILE}"

    if [[ ${#generated_rule_ids[@]} -eq 0 ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            parsed="$(parse_dnat_rule_line "$line")" || continue
            IFS='|' read -r lport dip dport <<< "$parsed"
            legacy_rules+=("$(make_legacy_rule_id "$lport" "$dip" "$dport")|${lport}|${dip}|${dport}")
        done < "${CONF_FILE}"
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        parsed="$(parse_rule_metadata_line "$line")" || return 1
        IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb remark <<< "$parsed"
        metadata_rule_id_matches_fields "$rule_id" "$lport" "$resolved_ip" "$dport" || return 1
        if [[ ${#generated_rule_ids[@]} -gt 0 ]]; then
            metadata_rules+=("${rule_id}")
        else
            metadata_rules+=("$(make_legacy_rule_id "$lport" "$resolved_ip" "$dport")|${lport}|${resolved_ip}|${dport}")
        fi
    done < "${RULES_FILE}"

    local legacy_sorted metadata_sorted
    if [[ ${#generated_rule_ids[@]} -gt 0 ]]; then
        legacy_sorted="$(printf '%s\n' "${generated_rule_ids[@]}" | LC_ALL=C sort)"
    else
        legacy_sorted="$(printf '%s\n' "${legacy_rules[@]}" | LC_ALL=C sort)"
    fi
    metadata_sorted="$(printf '%s\n' "${metadata_rules[@]}" | LC_ALL=C sort)"
    [[ "$legacy_sorted" == "$metadata_sorted" ]]
}

parse_dnat_rule_line() {
    local line="$1"
    if [[ "$line" =~ ^[[:space:]]*fib[[:space:]]+daddr[[:space:]]+type[[:space:]]+local[[:space:]]+(tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+(ct[[:space:]]+mark[[:space:]]+set[[:space:]]+[0-9]+[[:space:]]+)?dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+)[[:space:]]*$ ]]; then
        printf '%s|%s|%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
        return 0
    fi
    if [[ "$line" =~ ^[[:space:]]*tcp[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+(ct[[:space:]]+mark[[:space:]]+set[[:space:]]+[0-9]+[[:space:]]+)?dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+)[[:space:]]*$ ]]; then
        printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
        return 0
    fi
    return 1
}

parse_generated_counter_rule_line() {
    local line="$1" rule_id
    if [[ "$line" =~ ^[[:space:]]*counter[[:space:]]+([A-Za-z0-9_]+)_egress([[:space:]]*\{)?[[:space:]]*$ ]]; then
        rule_id="${BASH_REMATCH[1]}"
        validate_rule_id "$rule_id" || return 1
        printf '%s\n' "$rule_id"
        return 0
    fi
    return 1
}

restore_rules_state() {
    local restore_reload="$1"
    shift
    local -a old_rules_snapshot=("$@")

    RULES=("${old_rules_snapshot[@]}")
    write_rules_file >/dev/null 2>&1 || true
    if [[ "$restore_reload" == "1" ]]; then
        write_conf_file >/dev/null 2>&1 || true
        reload_rules >/dev/null 2>&1 || true
    fi
}

ensure_metadata_ready_for_mutation() {
    migrate_legacy_rules_if_needed || return 1
    if [[ ! -f "${RULES_FILE}" ]] && legacy_conf_has_rules; then
        err "检测到旧版转发配置但规则元数据文件缺失。内部安全保护已阻止本次修改，以免覆盖旧规则；请等待迁移功能完成后再继续操作。"
        return 1
    fi
    if legacy_conf_has_rules && ! metadata_matches_legacy_conf_rules; then
        err "检测到旧版转发配置与规则元数据不一致。内部安全保护已阻止本次修改，以免覆盖旧规则；请先修复或重建元数据文件后再继续操作。"
        return 1
    fi
    return 0
}

# 这里会在读取 metadata 前尝试执行一次旧配置迁移，保持 Task 3 的向后兼容行为。
load_rules() {
    RULES=()
    migrate_legacy_rules_if_needed
    if [[ ! -f "${RULES_FILE}" ]]; then
        return
    fi
    RULES=()
    local line parsed
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if parsed="$(parse_rule_metadata_line "$line")"; then
            RULES+=("$parsed")
        else
            warn "跳过无效规则元数据: ${line}"
        fi
    done < "${RULES_FILE}"
}

write_rules_file() {
    mkdir -p "${CONF_DIR}" 2>/dev/null || {
        err "无法创建配置目录 ${CONF_DIR}"
        return 1
    }
    local tmp_file="${RULES_FILE}.tmp.$$"
    {
        echo "# nft-forward rules metadata"
        echo "# format: rule_id|local_port|target_host|resolved_ip|dest_port|quota_gb|remark"
        local rule parsed
        for rule in "${RULES[@]}"; do
            parsed="$(parse_rule_metadata_line "$rule")" || continue
            echo "$parsed"
        done
    } > "${tmp_file}" || {
        err "无法写入临时规则文件 ${tmp_file}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }
    mv -f "${tmp_file}" "${RULES_FILE}" 2>/dev/null || {
        err "无法写入规则文件 ${RULES_FILE}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }
}

write_conf_file() {
    load_traffic_state || return 1

    # 先写入临时文件，成功后原子替换，避免写到一半断电导致配置损坏
    local tmp_file="${CONF_FILE}.tmp.$$"
    local rule rule_id lport target_host resolved_ip dport quota_gb snat_ip target_label

    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$rule"
        validate_rule_id "$rule_id" || continue
        is_rule_blocked "$rule_id" && continue
        snat_ip="$(get_snat_ip_for_dest "$resolved_ip")"
        if [[ -z "$snat_ip" ]]; then
            err "无法获取到 ${resolved_ip} 的 SNAT 源地址，请检查路由配置。"
            return 1
        fi
    done

    {
        cat <<EOF
#!/usr/sbin/nft -f

table ip ${TABLE_NAME} {
EOF

        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$rule"
            validate_rule_id "$rule_id" || continue
            cat <<EOF
    counter ${rule_id}_egress {
    }
EOF
        done

        cat <<EOF

    # --- PREROUTING (DNAT/BLOCK) ---
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$rule"
            validate_rule_id "$rule_id" || continue
            target_label="$(format_rule_target "$target_host" "$resolved_ip" "$dport")"
            if is_rule_blocked "$rule_id"; then
                cat <<EOF

        # 阻断: 本机:${lport} -> ${target_label}
        fib daddr type local tcp dport ${lport} drop
        fib daddr type local udp dport ${lport} drop
EOF
            else
                cat <<EOF

        # 转发: 本机:${lport} -> ${target_label}
        fib daddr type local tcp dport ${lport} ct mark set ${lport} dnat to ${resolved_ip}:${dport}
        fib daddr type local udp dport ${lport} ct mark set ${lport} dnat to ${resolved_ip}:${dport}
EOF
            fi
        done

        cat <<EOF
    }

    # --- FORWARD (EGRESS COUNTER/BLOCK) ---
    chain forward {
        type filter hook forward priority -10; policy accept;
EOF

        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$rule"
            validate_rule_id "$rule_id" || continue
            target_label="$(format_rule_target "$target_host" "$resolved_ip" "$dport")"
            if is_rule_blocked "$rule_id"; then
                cat <<EOF

        # 阻断请求: 客户端 -> ${target_label}
        ct mark ${lport} ip daddr ${resolved_ip} tcp dport ${dport} drop
        ct mark ${lport} ip daddr ${resolved_ip} udp dport ${dport} drop

        # 阻断回程: ${target_label} -> 客户端
        ct mark ${lport} ip saddr ${resolved_ip} tcp sport ${dport} drop
        ct mark ${lport} ip saddr ${resolved_ip} udp sport ${dport} drop
EOF
            else
                cat <<EOF

        # 放行请求: 客户端 -> ${target_label}
        ct mark ${lport} ip daddr ${resolved_ip} tcp dport ${dport} accept
        ct mark ${lport} ip daddr ${resolved_ip} udp dport ${dport} accept

        # 统计回程: ${target_label} -> 客户端
        ct mark ${lport} ip saddr ${resolved_ip} tcp sport ${dport} counter name ${rule_id}_egress accept
        ct mark ${lport} ip saddr ${resolved_ip} udp sport ${dport} counter name ${rule_id}_egress accept
EOF
            fi
        done

        cat <<EOF
    }

    # --- POSTROUTING (SNAT) ---
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$rule"
            validate_rule_id "$rule_id" || continue
            if is_rule_blocked "$rule_id"; then
                continue
            fi
            target_label="$(format_rule_target "$target_host" "$resolved_ip" "$dport")"
            snat_ip="$(get_snat_ip_for_dest "$resolved_ip")"
            cat <<EOF

        # 回源: 发往 ${target_label} 的已 DNAT 流量, SNAT 为到目标路由的源地址
        ip daddr ${resolved_ip} tcp dport ${dport} ct status dnat snat to ${snat_ip}
        ip daddr ${resolved_ip} udp dport ${dport} ct status dnat snat to ${snat_ip}
EOF
        done

        cat <<EOF
    }
}
EOF
    } > "${tmp_file}" || {
        err "无法写入临时配置文件 ${tmp_file}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }

    # 原子替换
    mv -f "${tmp_file}" "${CONF_FILE}" 2>/dev/null || {
        err "无法写入配置文件 ${CONF_FILE}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }
}

# ============== 重新加载规则 ==============
build_nft_reload_batch() {
    local batch_file escaped_conf
    batch_file="$(mktemp "${CONF_FILE}.reload.XXXXXX")" || return 1
    escaped_conf="${CONF_FILE//\"/\\\"}"
    {
        printf 'delete table ip %s\n' "$TABLE_NAME"
        printf 'include "%s"\n' "$escaped_conf"
    } > "$batch_file" || {
        rm -f "$batch_file" 2>/dev/null || true
        return 1
    }
    printf '%s\n' "$batch_file"
}

reload_rules() {
    local load_file="$CONF_FILE" batch_file=""

    if nft list table ip "${TABLE_NAME}" >/dev/null 2>&1; then
        batch_file="$(build_nft_reload_batch)" || {
            err "无法创建 nftables 重载批处理文件。"
            return 1
        }
        load_file="$batch_file"
    fi

    if ! nft -c -f "${load_file}"; then
        rm -f "$batch_file" 2>/dev/null || true
        err "配置校验失败，未修改当前运行中的 nftables 规则。请检查 ${CONF_FILE}"
        return 1
    fi

    if ! ui_spin_shell "重载 nftables 转发规则" "nft -f \"${load_file}\""; then
        rm -f "$batch_file" 2>/dev/null || true
        err "加载配置文件失败，请检查 ${CONF_FILE}"
        return 1
    fi
    rm -f "$batch_file" 2>/dev/null || true
    sync_egress_counter_baselines_after_nft_reload || true
    return 0
}

# ============== 备份配置 ==============
backup_conf() {
    if [[ -f "${CONF_FILE}" ]]; then
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        cp "${CONF_FILE}" "${BACKUP_DIR}/port-forward.conf.${ts}" 2>/dev/null || true
    fi
}

# ============== 开启内核参数：IP 转发 + BBR/fq ==============
enable_ip_forward() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current="0"
    if [[ "$current" != "1" ]]; then
        if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            info "已开启 IPv4 转发。"
        else
            warn "无法开启 IPv4 转发，请手动执行: sysctl -w net.ipv4.ip_forward=1"
        fi
    fi

    # 持久化：统一替换所有匹配行为 =1，没有则追加（避免重复项导致后值覆盖前值的误判）
    mkdir -p "$(dirname "${SYSCTL_CONF}")" 2>/dev/null || true
    touch "${SYSCTL_CONF}" 2>/dev/null || true

    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "${SYSCTL_CONF}" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward=1|' "${SYSCTL_CONF}" 2>/dev/null || true
    else
        echo "net.ipv4.ip_forward=1" >> "${SYSCTL_CONF}" 2>/dev/null || true
    fi

    sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
}

enable_bbr_fq() {
    # 1) 内核是否支持 bbr
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "内核不支持 BBR（tcp_available_congestion_control 中未找到 bbr），已跳过。"
        return 0
    fi

    # 2) 读取当前配置
    local cur_cc cur_qd
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cur_cc=""
    cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || cur_qd=""

    # 3) 判断是否已经开启
    if [[ "$cur_cc" == "bbr" && "$cur_qd" == "fq" ]]; then
        info "BBR + fq 已启用（无需修改）。"
        return 0
    fi

    # 4) 没开则开启（立即生效）
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    # 再读一次确认
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cur_cc=""
    cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null) || cur_qd=""

    if [[ "$cur_cc" == "bbr" && "$cur_qd" == "fq" ]]; then
        info "已开启 BBR + fq。"
        log_action "开启 BBR+fq"
    else
        warn "尝试开启 BBR+fq 后未确认生效（当前: cc=${cur_cc:-?}, qdisc=${cur_qd:-?}），可能被系统配置覆盖。"
    fi

    # 5) 持久化：写入 SYSCTL_CONF（用“替换/追加”避免覆盖别的项）
    mkdir -p "$(dirname "${SYSCTL_CONF}")" 2>/dev/null || true
    touch "${SYSCTL_CONF}" 2>/dev/null || true

    if grep -qE '^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=' "${SYSCTL_CONF}"; then
        sed -i -E 's|^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=.*|net.core.default_qdisc=fq|' "${SYSCTL_CONF}" 2>/dev/null || true
    else
        echo "net.core.default_qdisc=fq" >> "${SYSCTL_CONF}" 2>/dev/null || true
    fi

    if grep -qE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=' "${SYSCTL_CONF}"; then
        sed -i -E 's/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=.*/net.ipv4.tcp_congestion_control=bbr/' "${SYSCTL_CONF}" 2>/dev/null || true
    else
        echo "net.ipv4.tcp_congestion_control=bbr" >> "${SYSCTL_CONF}" 2>/dev/null || true
    fi

    sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
    info "已持久化 BBR + fq 到 ${SYSCTL_CONF}。"
    log_action "持久化 BBR+fq 到 ${SYSCTL_CONF}"
}

# ============== 检测防火墙状态（仅提示） ==============
check_firewall_status() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "检测到 firewalld 正在运行，添加转发规则时将自动放行对应端口。"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        info "检测到 UFW 正在运行，添加转发规则时将自动放行对应端口。"
    elif has_iptables; then
        info "检测到 iptables 规则集存在，添加转发规则时将自动放行对应端口。"
    fi
}

# ============== 诊断/自检 ==============
do_diagnose() {
    ui_begin_feature_screen
    printf '\n'

    ui_section "诊断 / 自检"
    echo ""

    # 1. IP 转发
    local ip_fwd
    ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || ip_fwd="未知"
    if [[ "$ip_fwd" == "1" ]]; then
        info "IPv4 转发: 已开启"
    else
        err  "IPv4 转发: 未开启 (当前值: ${ip_fwd})"
        echo "  → 修复: 选择菜单【安装 nftables】会自动开启"
    fi

    # 2. nftables 状态
    if command -v nft &>/dev/null; then
        info "nftables: 已安装 ($(nft --version 2>/dev/null || echo '未知版本'))"
    else
        err  "nftables: 未安装"
        echo "  → 修复: 选择菜单【安装 nftables】"
    fi

    local svc_enabled svc_active
    if has_systemctl; then
        svc_enabled=$(systemctl is-enabled nftables 2>/dev/null) || svc_enabled="unknown"
        svc_active=$(systemctl is-active nftables 2>/dev/null) || svc_active="unknown"
    else
        svc_enabled="no-systemctl"
        svc_active="no-systemctl"
    fi

    if [[ "$svc_enabled" == "no-systemctl" ]]; then
        warn "nftables 开机启动: 无法检测（systemctl 不可用）"
    elif [[ "$svc_enabled" == "enabled" ]]; then
        info "nftables 开机启动: 是"
    else
        warn "nftables 开机启动: 否（重启后规则可能丢失）"
        echo "  → 修复: systemctl enable nftables"
    fi

    if [[ "$svc_active" == "no-systemctl" ]]; then
        warn "nftables 服务状态: 无法检测（systemctl 不可用）"
    elif [[ "$svc_active" == "active" ]]; then
        info "nftables 服务状态: 运行中"
    else
        warn "nftables 服务状态: 未运行"
        echo "  → 修复: systemctl start nftables"
    fi

    # 3. 转发规则是否加载
    if nft list table ip "${TABLE_NAME}" &>/dev/null; then
        load_rules
        info "转发规则表: 已加载（${#RULES[@]} 条转发规则）"
    else
        warn "转发规则表: 未加载（可能无规则或服务未启动）"
    fi

    # 4. 防火墙检测
    local fw_found=false diag_fw=ok fw_issues=()

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        fw_found=true
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        fw_found=true
        diag_fw=warn
        fw_issues+=("UFW 活跃（默认可能阻止入站，影响转发）")
    fi

    if ! $fw_found && has_iptables; then
        fw_found=true
        local fwd_policy
        fwd_policy=$(iptables -S FORWARD 2>/dev/null | grep -- '^-P FORWARD' | awk '{print $3}') || fwd_policy=""
        if [[ "$fwd_policy" == "DROP" || "$fwd_policy" == "REJECT" ]]; then
            diag_fw=warn
            fw_issues+=("iptables FORWARD 默认策略为 ${fwd_policy}（可能阻止转发流量）")
        fi
    fi

    if [[ "$diag_fw" == ok ]]; then
        ui_diag_item_ok "防火墙状态"
    else
        ui_diag_item_warn "防火墙状态"
        local fw_m
        for fw_m in "${fw_issues[@]}"; do ui_diag_issue "$fw_m"; done
    fi

    # 5. nftables forward 链检测
    local diag_nft=ok nft_issues=()
    local fwd_chains
    fwd_chains=$(nft list chains 2>/dev/null | grep -B1 "hook forward" || true)
    if [[ -n "$fwd_chains" ]]; then
        if echo "$fwd_chains" | grep -qi "drop"; then
            local ruleset
            ruleset=$(nft list ruleset 2>/dev/null) || ruleset=""
            if ! echo "$ruleset" | grep -Eq 'ct[[:space:]]+status[[:space:]]+dnat[[:space:]]+accept'; then
                diag_nft=warn
                nft_issues+=("forward 钩子上存在默认 drop，且未发现 ct status dnat accept 等放行规则")
                nft_issues+=("可能阻止转发，请在链内添加等效放行或核对规则集")
                nft_issues+=("查看: nft list ruleset | grep -A5 'hook forward'")
            fi
        fi
    fi

    if [[ "$diag_nft" == ok ]]; then
        ui_diag_item_ok "nftables 转发链"
    else
        ui_diag_item_warn "nftables 转发链"
        local nft_m
        for nft_m in "${nft_issues[@]}"; do ui_diag_issue "$nft_m"; done
    fi

    # 6. 配置持久化
    local diag_persist=ok persist_issues=()
    if [[ -f "${MAIN_CONF}" ]]; then
        if ! grep -qF "${CONF_INCLUDE_LINE}" "${MAIN_CONF}" 2>/dev/null; then
            diag_persist=warn
            persist_issues+=("主配置 ${MAIN_CONF} 缺少 include 指令（重启后规则可能丢失）")
            persist_issues+=("修复: 选择菜单【安装 nftables】会自动添加")
        fi
    else
        diag_persist=warn
        persist_issues+=("主配置 ${MAIN_CONF} 不存在（重启后规则可能丢失）")
        persist_issues+=("修复: 选择菜单【安装 nftables】会自动创建")
    fi

    if [[ "$diag_persist" == ok ]]; then
        ui_diag_item_ok "配置持久化"
    else
        ui_diag_item_warn "配置持久化"
        local pe
        for pe in "${persist_issues[@]}"; do ui_diag_issue "$pe"; done
    fi

    # 7. 流量限制（月流量相关）
    local diag_quota=ok quota_issues=()
    if [[ ! -f "${RULES_FILE}" ]]; then
        diag_quota=warn
        quota_issues+=("规则元数据文件 ${RULES_FILE} 不存在（旧规则会在下次加载时迁移）")
    fi

    if [[ ! -d "${STATE_DIR}" || ! -w "${STATE_DIR}" ]]; then
        diag_quota=warn
        quota_issues+=("流量状态目录 ${STATE_DIR} 不存在或不可写")
    fi

    if [[ -f "${TRAFFIC_SERVICE_FILE}" && -f "${TRAFFIC_TIMER_FILE}" ]]; then
        :
    elif [[ -f "${TRAFFIC_TIMER_FILE}" ]]; then
        diag_quota=warn
        quota_issues+=("流量检查 systemd 单元: service 缺失，流量限制不会自动执行")
    elif [[ -f "${TRAFFIC_SERVICE_FILE}" ]]; then
        diag_quota=warn
        quota_issues+=("流量检查 systemd 单元: timer 缺失，流量限制不会自动执行")
    else
        diag_quota=warn
        quota_issues+=("流量检查 systemd 单元未安装，流量限制不会自动执行")
    fi

    if has_systemctl; then
        local timer_enabled timer_active
        timer_enabled=$(systemctl is-enabled "$(basename "${TRAFFIC_TIMER_FILE}")" 2>/dev/null) || timer_enabled="unknown"
        timer_active=$(systemctl is-active "$(basename "${TRAFFIC_TIMER_FILE}")" 2>/dev/null) || timer_active="unknown"
        if [[ -f "${TRAFFIC_SERVICE_FILE}" && -f "${TRAFFIC_TIMER_FILE}" ]] && {
            [[ "$timer_enabled" != "enabled" ]] || [[ "$timer_active" != "active" ]]
        }; then
            diag_quota=warn
            quota_issues+=("流量检查 timer 当前 enabled=${timer_enabled}, active=${timer_active}，限额检查可能不会按时运行")
        fi
    else
        diag_quota=warn
        quota_issues+=("systemctl 不可用，流量限制不会自动执行")
    fi

    if [[ "$diag_quota" == ok ]]; then
        ui_diag_item_ok "流量限制"
    else
        ui_diag_item_warn "流量限制"
        local qe
        for qe in "${quota_issues[@]}"; do ui_diag_issue "$qe"; done
    fi

    # 8. 目标连通性测试（可选）
    echo ""
    load_rules
    local connectivity_prompted=false connectivity_cancelled=false
    if [[ ${#RULES[@]} -gt 0 ]]; then
        connectivity_prompted=true
        if ui_confirm_no_default "是否测试目标连通性？"; then
            local rule lport target_host resolved_ip dport
            for rule in "${RULES[@]}"; do
                IFS='|' read -r _ lport target_host resolved_ip dport _ _ <<< "$rule"
                printf "  测试 %s (TCP) ... " "$(format_rule_target "$target_host" "$resolved_ip" "$dport")"
                if timeout 3 bash -c ">/dev/tcp/${resolved_ip}/${dport}" 2>/dev/null; then
                    printf "\033[32m通\033[0m\n"
                else
                    printf "\033[31m不通或超时\033[0m\n"
                fi
            done
        else
            connectivity_cancelled=true
        fi
    fi
    if [[ "$connectivity_prompted" != true || "$connectivity_cancelled" != true ]]; then
        ui_wait_return
    fi
}

# ====================================================
# 功能 1：安装 nftables
# ====================================================
do_install() {
    ui_begin_feature_screen

    if command -v nft &>/dev/null; then
        info "nftables 已安装。"
        nft --version 2>/dev/null || true
        echo ""
        warn "安装将清空所有已有 nftables 配置，由本脚本统一接管。"
        warn "已有的配置文件将被备份（重命名为 .bak）。"
        if ! ui_confirm_no_default "是否继续？"; then
            interactive_terminal_exit_prepare
            info "已取消，退出脚本。"
            exit 0
        fi

        # 备份已有配置文件（重命名，不删除）
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        if [[ -f "${MAIN_CONF}" ]]; then
            mv "${MAIN_CONF}" "${MAIN_CONF}.bak.${ts}" 2>/dev/null || true
            info "已备份 ${MAIN_CONF} → ${MAIN_CONF}.bak.${ts}"
        fi
        if [[ -d "${CONF_DIR}" ]]; then
            local f
            for f in "${CONF_DIR}"/*.conf; do
                [[ -f "$f" ]] || continue
                mv "$f" "${f}.bak.${ts}" 2>/dev/null || true
                info "已备份 ${f} → ${f}.bak.${ts}"
            done
        fi

        # 清空当前运行中的规则
        ui_spin_shell "清空 nftables 规则集" "nft flush ruleset 2>/dev/null || true"
        info "已清空当前 nftables 规则集。"
        log_action "清空已有配置并由脚本接管 (备份时间戳: ${ts})"

        enable_ip_forward
        enable_bbr_fq
        check_firewall_status
        init_conf

        # 加载主配置（flush + include），验证整条配置链路
        if ! ui_spin_shell "加载 nftables 主配置" "nft -f \"${MAIN_CONF}\""; then
            err "加载 ${MAIN_CONF} 失败，请检查配置。"
            return
        fi

        # 确保服务开机启动且当前正在运行
        if ui_spin_shell "启用 nftables 服务" "systemctl enable --now nftables 2>/dev/null"; then
            info "已启用 nftables 服务。"
        else
            warn "nftables 服务启用失败，重启后规则可能丢失。"
            warn "请手动执行: systemctl enable --now nftables"
        fi

        install_traffic_timer || true

        info "初始化完成，所有配置已由本脚本接管。"
        return
    fi

    info "未检测到 nftables，准备安装..."
    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)

    case "$pkg_mgr" in
        apt)
            ui_spin_shell "安装 nftables" "apt-get update -y && apt-get install -y nftables"
            ;;
        dnf)
            ui_spin_shell "安装 nftables" "dnf install -y nftables"
            ;;
        yum)
            ui_spin_shell "安装 nftables" "yum install -y nftables"
            ;;
        pacman)
            ui_spin_shell "安装 nftables" "pacman -Sy --noconfirm nftables"
            ;;
        *)
            err "无法识别包管理器，请手动安装 nftables。"
            return
            ;;
    esac

    if ! command -v nft &>/dev/null; then
        err "安装失败，请手动安装 nftables。"
        return
    fi

    info "nftables 安装成功。"
    nft --version 2>/dev/null || true
    log_action "安装 nftables"

    enable_ip_forward
    enable_bbr_fq
    check_firewall_status
    init_conf
    # 先写好配置，再启用服务，确保服务启动时直接加载我们的配置
    if ui_spin_shell "启用 nftables 服务" "systemctl enable --now nftables 2>/dev/null"; then
        info "已启用 nftables 服务。"
    else
        warn "nftables 服务启用失败，重启后规则可能丢失。"
        warn "请手动执行: systemctl enable --now nftables"
    fi

    install_traffic_timer || true

    info "安装与初始化完成。"
}

# ====================================================
# 就地编辑规则的月流量上限与备注（不修改转发三元组）
# ====================================================
edit_rule_quota_and_remark_at() {
    local row_idx="$1"
    local target rule_id lport target_host resolved_ip dport old_q old_rm new_q new_rm
    local -a OLD_SNAPSHOT

    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，无法保存修改。"
        return 1
    fi

    ensure_metadata_ready_for_mutation || return 1

    if [[ ! "$row_idx" =~ ^[1-9][0-9]*$ ]] || (( row_idx < 1 || row_idx > ${#RULES[@]} )); then
        err "无效的序号。"
        return 1
    fi

    target="${RULES[$((row_idx - 1))]}"
    IFS='|' read -r rule_id lport target_host resolved_ip dport old_q old_rm <<< "$target"

    printf '当前所选规则：本机 %s (tcp+udp) → %s\n' "$lport" "$(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    printf '%s\n' '仅月流量上限与备注可修改（如需修改目标地址，请先删除再新增）。'
    printf '月流量上限: %s\n' "$(format_quota "$old_q")"
    printf '备注: %s\n' "$(format_remark "$old_rm")"

    new_q="$old_q"
    new_rm="$old_rm"

    printf '\n'
    if ui_confirm_yes_default "是否修改月流量上限？（当前 $(format_quota "$old_q")）"; then
        new_q="$(select_quota_gb)" || {
            info "已取消。"
            return 1
        }
        if gum_enabled && is_interactive_terminal; then
            clear_interactive_screen
            ui_app_banner
            printf '\n'
        fi
    fi

    if ui_confirm_yes_default "是否修改备注？（当前 $(format_remark "$old_rm")）"; then
        if ! new_rm="$(ui_input "请输入备注（可留空）:" "${old_rm}" "可不填")"; then
            info "已取消。"
            return 1
        fi
        while ! validate_remark "$new_rm"; do
            err "备注不能包含 |，且长度不能超过 40 个字符。"
            if ! new_rm="$(ui_input "请输入备注（可留空）:" "${old_rm}" "可不填")"; then
                info "已取消。"
                return 1
            fi
        done
    fi

    if [[ "$new_q" == "$old_q" && "$new_rm" == "$old_rm" ]]; then
        info "未做任何修改。"
        return 0
    fi

    # 确认（gum 下不设顶空行：与「即将添加转发规则」页一致）
    if ! gum_enabled; then
        echo ""
    fi
    echo "即将保存修改为:"
    echo " - 本机端口 ${lport} (tcp+udp) → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    echo " - 月流量上限: $(format_quota "$old_q") → $(format_quota "$new_q")"
    echo " - 备注: $(format_remark "$old_rm") → $(format_remark "$new_rm")"
    echo ""
    if ! ui_confirm_no_default "确认保存？"; then
        info "已取消。"
        return 1
    fi

    OLD_SNAPSHOT=("${RULES[@]}")
    RULES[$((row_idx - 1))]="${rule_id}|${lport}|${target_host}|${resolved_ip}|${dport}|${new_q}|${new_rm}"

    if ! write_rules_file; then
        RULES=("${OLD_SNAPSHOT[@]}")
        return 1
    fi

    if [[ "$new_q" == "$old_q" ]]; then
        info "保存成功。"
        log_action "编辑规则备注: ${lport} -> ${resolved_ip}:${dport}"
        return 0
    fi

    backup_conf
    if ! write_conf_file; then
        restore_rules_state 0 "${OLD_SNAPSHOT[@]}"
        return 1
    fi
    if ! reload_rules; then
        restore_rules_state 1 "${OLD_SNAPSHOT[@]}"
        err "规则加载失败，请检查配置。"
        return 1
    fi

    info "保存成功。"
    log_action "编辑规则(限额/备注): ${lport} -> ${resolved_ip}:${dport}; quota_gb ${old_q} -> ${new_q}"
    return 0
}

# ====================================================
# 功能 2：查看 / 编辑现有端口转发（仅可调月流量限额与备注）
# ====================================================
do_list() {
    local wait_return="${1:-1}"
    [[ "$wait_return" == "1" ]] && {
        ui_begin_feature_screen
        printf '\n'
    }

    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则。"
        if [[ "$wait_return" == "1" ]]; then
            ui_wait_return
        fi
        return 0
    fi

    ensure_state_for_rules
    load_traffic_state

    local idx=1
    local now
    now="$(now_epoch)"
    local rule rule_id lport target_host resolved_ip dport quota_gb remark used_bytes blocked quota_label used_label days_label status_label remark_label selected_row choice

    if gum_enabled; then
        if [[ "$wait_return" != "1" ]]; then
            print_rules_table_tsv | ui_table >/dev/null 2>&1 || true
            return 0
        fi
        while true; do
            selected_row="$(print_rules_table_tsv | ui_table)" || return 0
            # gum table：Esc/q 常为退出码 0 + stdout 无选中行；Ctrl+C 等为非零。视为离开表格而非「无效选择」，避免无限重绘
            [[ -z "${selected_row//[$'\t\r\n ']/}" ]] && return 0
            choice="${selected_row%%$'\t'*}"
            [[ -z "$choice" ]] && return 0
            if [[ "$choice" == "序号" ]]; then
                err "无效的表格选择。"
                continue
            fi
            if [[ ! "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
                err "无效的序号。"
                continue
            fi
            edit_rule_quota_and_remark_at "$choice" || true
            load_rules || break
            ensure_state_for_rules
            load_traffic_state
            if gum_enabled && is_interactive_terminal; then
                clear_interactive_screen
                ui_app_banner
                printf '\n'
            fi
        done
        ui_wait_return
        return 0
    fi

    while true; do
        idx=1
        printf "%s%-6s %-10s %-10s %-22s %-10s %-10s %-11s %-10s %-20s\033[0m\n" \
            "$(ansi_table_header_prefix)" "序号" "协议" "本机端口" "目标地址" "流量限制" "已用流量" "下次重置" "状态" "备注"
        echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

        for rule in "${RULES[@]}"; do
            IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb remark <<< "$rule"
            used_bytes="$(state_get STATE_USED_BYTES "$rule_id" 0)"
            blocked="$(state_get STATE_BLOCKED "$rule_id" 0)"
            quota_label="$(format_quota "$quota_gb")"
            used_label="$(format_bytes "$used_bytes")"
            if [[ "$quota_gb" == "0" ]]; then
                days_label="-"
            else
                days_label="$(format_quota_period_reset_day "$(state_get STATE_PERIOD_START "$rule_id" 0)" "$now")"
            fi
            status_label="$(rule_status_label "$quota_gb" "$blocked")"
            remark_label="$(format_remark "$remark")"
            printf "%-6s %-10s %-10s %-22s %-10s %-10s %-11s %-10s %-20s\n" \
                "$idx" "tcp+udp" "$lport" "$(format_rule_target "$target_host" "$resolved_ip" "$dport")" "$quota_label" "$used_label" "$days_label" "$status_label" "$remark_label"
            ((idx++))
        done
        echo ""
        [[ "$wait_return" != "1" ]] && return 0
        if ! choice="$(ui_rule_choice "请输入要编辑的序号（0 退出）")"; then
            info "已取消。"
            break
        fi
        [[ "$choice" == "0" ]] && break
        if [[ ! "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
            err "无效的序号。"
            continue
        fi
        edit_rule_quota_and_remark_at "$choice" || true
        load_rules || break
        ensure_state_for_rules
        load_traffic_state
    done

    if [[ "$wait_return" == "1" ]]; then
        ui_wait_return
    fi
    return 0
}

reset_rule_traffic_interactive() {
    ui_begin_feature_screen
    printf '\n'

    ensure_metadata_ready_for_mutation || return
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则。"
        ui_wait_return
        return
    fi

    load_traffic_state

    local choice selected_row
    if gum_enabled; then
        selected_row="$(print_rules_table_tsv | ui_table)" || {
            info "已取消。"
            return
        }
        choice="${selected_row%%$'\t'*}"
        if [[ -z "$choice" ]]; then
            info "已取消。"
            return
        fi
    else
        do_list 0
        choice="$(ui_rule_choice "请输入要重置的序号")" || {
            info "已取消。"
            return
        }
    fi

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        info "已取消。"
        return
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        err "无效的序号。"
        return
    fi

    local target rule_id lport target_host resolved_ip dport quota_gb used_bytes
    target="${RULES[$((choice-1))]}"
    IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb _ <<< "$target"
    used_bytes="$(state_get STATE_USED_BYTES "$rule_id" 0)"

    echo "即将重置流量并恢复转发:"
    echo " - 本机端口 ${lport} (tcp+udp) → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    echo " - 已用流量: $(format_bytes "$used_bytes")"
    echo ""
    if ! ui_confirm_yes_default "确认重置？"; then
        info "已取消。"
        return
    fi

    local current_counter
    current_counter="$(read_counter_bytes "${rule_id}_egress")" || {
        warn "读取计数器失败，已按 0 重置规则 ${rule_id}"
        current_counter=0
    }

    local now old_state_content="" old_conf_content="" had_state=0 had_conf=0
    now="$(now_epoch)"

    if [[ -f "${STATE_FILE}" ]]; then
        old_state_content="$(cat "${STATE_FILE}")"
        had_state=1
    fi
    if [[ -f "${CONF_FILE}" ]]; then
        old_conf_content="$(cat "${CONF_FILE}")"
        had_conf=1
    fi

    reset_rule_state "$rule_id" "$now" "$current_counter" || return 1
    save_traffic_state || return 1

    if ! write_conf_file; then
        restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" || return 1
        return 1
    fi

    if ! reload_rules; then
        restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" || return 1
        reload_rules >/dev/null 2>&1 || true
        err "规则加载失败，请检查配置。"
        return 1
    fi

    info "已重置规则流量用量并恢复转发: ${lport} → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    log_action "重置流量状态并恢复转发: ${lport} -> ${resolved_ip}:${dport}"
    ui_wait_return
}

# ====================================================
# 功能 3：新增端口转发
# ====================================================
do_add() {
    ui_begin_feature_screen
    printf '\n'

    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    ensure_metadata_ready_for_mutation || return
    init_conf || return
    enable_ip_forward
    load_rules

    local local_ip
    local_ip=$(get_local_ip)
    if [[ -z "$local_ip" ]]; then
        err "无法获取本机 IP 地址，请检查网络配置。"
        return
    fi

    # 输入本机端口
    local lport
    while true; do
        if ! lport="$(ui_input "请输入本机监听端口 (1-65535):" "" "例如 8443")"; then
            info "已取消。"
            return
        fi
        if validate_port "$lport"; then
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    # 检查端口是否已有转发规则
    local rule rp
    for rule in "${RULES[@]}"; do
        IFS='|' read -r _ rp _ _ _ _ _ <<< "$rule"
        if [[ "$rp" == "$lport" ]]; then
            err "本机端口 ${lport} 已存在转发规则，请先删除后再添加。"
            return
        fi
    done

    # 检查端口占用（TCP + UDP）
    if ! check_port_conflict "$lport"; then
        info "已取消。"
        return
    fi

    # 输入目标地址并解析 IPv4
    local target_host resolved_ip
    while true; do
        if ! target_host="$(ui_input "请输入目标 IP 或域名:" "" "例如 192.168.1.100 或 example.com")"; then
            info "已取消。"
            return
        fi
        if ! validate_target_host "$target_host"; then
            err "目标地址无效，请输入合法 IPv4 或域名。"
            continue
        fi
        if resolved_ip="$(resolve_target_ipv4 "$target_host")"; then
            break
        fi
        err "无法解析 ${target_host} 的 IPv4 地址，请检查域名或 DNS。"
    done

    # 输入目标端口
    local dport
    while true; do
        if ! dport="$(ui_input "请输入目标端口 (1-65535) [默认: ${lport}]:" "$lport" "默认与本机端口相同，可改")"; then
            info "已取消。"
            return
        fi
        dport="${dport:-$lport}"
        if validate_port "$dport"; then
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    local quota_gb
    quota_gb="$(select_quota_gb)" || return
    # 去掉额度选择页留在屏幕上的 gum style 标题/说明，避免与后续备注、确认页叠在一起
    if gum_enabled && is_interactive_terminal; then
        clear_interactive_screen
        ui_app_banner
        printf '\n'
    fi

    local remark
    while true; do
        if ! remark="$(ui_input "请输入备注（可留空）:" "" "可不填")"; then
            info "已取消。"
            return
        fi
        if validate_remark "$remark"; then
            break
        fi
        err "备注不能包含 |，且长度不能超过 40 个字符。"
    done

    # 确认（gum 下不设顶空行：横幅后已有留白，备注输入结束后不再叠一行）
    if ! gum_enabled; then
        echo ""
    fi
    echo "即将添加转发规则:"
    echo " - 本机端口 ${lport} (tcp+udp) -> ${target_host}:${dport}"
    if [[ "$target_host" != "$resolved_ip" ]]; then
        echo " - 当前解析 IP: ${resolved_ip}"
    fi
    echo " - 月流量上限: $(format_quota "$quota_gb")"
    echo " - 备注: $(format_remark "$remark")"
    echo ""
    if ! ui_confirm_yes_default "确认添加？"; then
        info "已取消。"
        return
    fi

    # 备份并写入
    backup_conf
    local -a OLD_RULES_SNAPSHOT=("${RULES[@]}")
    local rule_id
    rule_id="$(make_rule_id "$lport" "$target_host" "$dport")"
    RULES+=("${rule_id}|${lport}|${target_host}|${resolved_ip}|${dport}|${quota_gb}|${remark}")
    if ! write_rules_file; then
        RULES=("${OLD_RULES_SNAPSHOT[@]}")
        return
    fi
    if ! write_conf_file; then
        restore_rules_state 0 "${OLD_RULES_SNAPSHOT[@]}"
        return
    fi

    if ! reload_rules; then
        restore_rules_state 1 "${OLD_RULES_SNAPSHOT[@]}"
        err "规则加载失败，请检查配置。"
        return
    fi

    firewall_open_port "$lport" "$resolved_ip" "$dport"
    info "转发规则添加成功: ${lport} → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    log_action "新增转发: ${lport} -> ${target_host}(${resolved_ip}):${dport}"
    info "若转发不通，请使用菜单中的【诊断/自检】排查。"
    ui_wait_return
}

# ====================================================
# 功能 4：删除端口转发
# ====================================================
do_delete() {
    ui_begin_feature_screen

    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    ensure_metadata_ready_for_mutation || return
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则，无需删除。"
        ui_wait_return
        return
    fi

    printf '\n'
    local idx=1
    local rule lport target_host resolved_ip dport remark remark_label
    local choice selected_row
    if gum_enabled; then
        load_traffic_state
        selected_row="$(print_rules_table_tsv | ui_table)" || {
            info "已取消。"
            return
        }
        choice="${selected_row%%$'\t'*}"
        if [[ -z "$choice" ]]; then
            info "已取消。"
            return
        fi
    else
        # 展示列表
        printf "%s%-6s %-10s %-10s    %-20s %-20s\033[0m\n" \
            "$(ansi_table_header_prefix)" "序号" "协议" "本机端口" "目标地址" "备注"
        echo "─────────────────────────────────────────────────────────────────────────"

        for rule in "${RULES[@]}"; do
            IFS='|' read -r _ lport target_host resolved_ip dport _ remark <<< "$rule"
            remark_label="$(format_remark "$remark")"
            printf "%-6s %-10s %-10s -> %-20s %-20s\n" \
                "$idx" "tcp+udp" "$lport" "$(format_rule_target "$target_host" "$resolved_ip" "$dport")" "$remark_label"
            ((idx++))
        done
        # 选择删除
        choice="$(ui_rule_choice "请输入要删除的序号")" || {
            info "已取消。"
            return
        }
    fi

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        info "已取消。"
        return
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        err "无效的序号。"
        return
    fi

    local target="${RULES[$((choice-1))]}"
    IFS='|' read -r _ lport target_host resolved_ip dport _ remark <<< "$target"

    echo "即将删除转发规则:"
    echo " - 本机端口 ${lport} (tcp+udp) → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    echo " - 备注: ${remark}"
    echo ""
    if ! ui_confirm_yes_default "确认删除？"; then
        info "已取消。"
        return
    fi

    # 备份并移除
    backup_conf
    local -a OLD_RULES_SNAPSHOT=("${RULES[@]}")
    unset 'RULES[$((choice-1))]'
    RULES=("${RULES[@]}")

    if ! write_rules_file; then
        RULES=("${OLD_RULES_SNAPSHOT[@]}")
        return
    fi
    if ! write_conf_file; then
        restore_rules_state 0 "${OLD_RULES_SNAPSHOT[@]}"
        return
    fi

    if ! reload_rules; then
        restore_rules_state 1 "${OLD_RULES_SNAPSHOT[@]}"
        err "规则加载失败，请检查配置。"
        return
    fi

    load_traffic_state
    if ! save_traffic_state; then
        err "状态文件清理失败，请检查 ${STATE_FILE}"
        return 1
    fi

    # nft 规则已成功更新后，再清理防火墙放行（RULES 已移除该条，dest_still_used 能正确判断）
    firewall_close_port "$lport" "$resolved_ip" "$dport"
    info "转发规则已删除: ${lport} → $(format_rule_target "$target_host" "$resolved_ip" "$dport")"
    log_action "删除转发: ${lport} -> ${resolved_ip}:${dport}"
    ui_wait_return
}

# ====================================================
# 功能 5：一键清空所有转发
# ====================================================
do_clear_all() {
    ui_begin_feature_screen

    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    ensure_metadata_ready_for_mutation || return
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则，无需清空。"
        ui_wait_return
        return
    fi

    printf '\n'
    warn "即将清空全部 ${#RULES[@]} 条转发规则！"
    if ! ui_confirm_no_default "确认清空？请谨慎操作！"; then
        info "已取消。"
        return
    fi

    backup_conf

    local old_rules=("${RULES[@]}")
    local -a OLD_RULES_SNAPSHOT=("${RULES[@]}")
    RULES=()
    if ! write_rules_file; then
        RULES=("${OLD_RULES_SNAPSHOT[@]}")
        return
    fi
    if ! write_conf_file; then
        restore_rules_state 0 "${OLD_RULES_SNAPSHOT[@]}"
        return
    fi

    if ! reload_rules; then
        restore_rules_state 1 "${OLD_RULES_SNAPSHOT[@]}"
        err "规则加载失败，请检查配置。"
        return
    fi

    if ! save_traffic_state; then
        err "状态文件清理失败，请检查 ${STATE_FILE}"
        return 1
    fi

    # nft 规则更新成功后，再清理外部防火墙状态，避免写入失败时产生半应用状态
    local rule lport resolved_ip dport
    for rule in "${old_rules[@]}"; do
        IFS='|' read -r _ lport _ resolved_ip dport _ _ <<< "$rule"
        firewall_close_port "$lport" "$resolved_ip" "$dport" "force"
    done
    info "所有转发规则已清空。"
    log_action "清空所有转发规则"
    ui_wait_return
}

# ====================================================
# 主菜单
# ====================================================
main_menu() {
    local choice
    while true; do
        ui_before_menu
        ui_app_banner
        printf '\n'
        ui_print_menu_notice
        if gum_enabled; then
            choice="$(ui_choose "请选择操作" \
                "1|安装 nftables" \
                "2|查看/编辑现有端口转发" \
                "3|新增端口转发" \
                "4|删除端口转发" \
                "5|一键清空所有转发" \
                "6|重置流量/恢复转发" \
                "7|诊断/自检" \
                "8|退出")" || {
                    interactive_terminal_exit_prepare
                    info "已取消。"
                    exit 0
                }
        else
            echo ""
            echo "  1) 安装 nftables"
            echo "  2) 查看/编辑现有端口转发"
            echo "  3) 新增端口转发"
            echo "  4) 删除端口转发"
            echo "  5) 一键清空所有转发"
            echo "  6) 重置流量/恢复转发"
            echo "  7) 诊断/自检"
            echo "  8) 退出"
            echo "========================================"
            printf '请选择操作 [1-8]: '
            IFS= read -r choice
        fi

        case "$choice" in
            1) do_install ;;
            2) do_list ;;
            3) do_add ;;
            4) do_delete ;;
            5) do_clear_all ;;
            6) reset_rule_traffic_interactive ;;
            7) do_diagnose ;;
            8)
                interactive_terminal_exit_prepare
                info "再见！"
                exit 0
                ;;
            *)
                err "无效选择，请输入 1-8。"
                ;;
        esac
    done
}

DOMAIN_RESOLUTION_CHANGED=0
DOMAIN_RESOLUTION_FIREWALL_UPDATES=()

refresh_rule_resolved_ips() {
    DOMAIN_RESOLUTION_CHANGED=0
    DOMAIN_RESOLUTION_FIREWALL_UPDATES=()
    local idx rule rule_id lport target_host resolved_ip dport quota_gb remark new_ip
    local -a refreshed_rules=()

    for idx in "${!RULES[@]}"; do
        rule="${RULES[$idx]}"
        IFS='|' read -r rule_id lport target_host resolved_ip dport quota_gb remark <<< "$rule"

        if ! validate_rule_id "$rule_id" || ! validate_target_host "$target_host" || ! validate_ip "$resolved_ip"; then
            refreshed_rules+=("$rule")
            continue
        fi

        if ! rule_target_is_domain "$target_host"; then
            refreshed_rules+=("$rule")
            continue
        fi

        if ! new_ip="$(resolve_target_ipv4 "$target_host")"; then
            warn "域名 ${target_host} 解析失败，保留上一次 IPv4: ${resolved_ip}"
            refreshed_rules+=("$rule")
            continue
        fi

        if [[ "$new_ip" != "$resolved_ip" ]]; then
            DOMAIN_RESOLUTION_CHANGED=1
            DOMAIN_RESOLUTION_FIREWALL_UPDATES+=("${lport}|${resolved_ip}|${new_ip}|${dport}")
            refreshed_rules+=("${rule_id}|${lport}|${target_host}|${new_ip}|${dport}|${quota_gb}|${remark}")
            log_action "域名解析更新: ${target_host} ${resolved_ip} -> ${new_ip}"
        else
            refreshed_rules+=("$rule")
        fi
    done

    RULES=("${refreshed_rules[@]}")
    return 0
}

sync_domain_resolution_firewall_updates() {
    local update lport old_ip new_ip dport
    for update in "${DOMAIN_RESOLUTION_FIREWALL_UPDATES[@]-}"; do
        IFS='|' read -r lport old_ip new_ip dport <<< "$update"
        firewall_open_port "$lport" "$new_ip" "$dport"
        firewall_close_forward_target "$lport" "$old_ip" "$dport"
    done
}

traffic_check() {
    local now="${1:-$(now_epoch)}"
    local changed=0 counter_repaired=0
    local rule rule_id quota_gb
    local current_counter period_start used_bytes last_counter blocked delta quota_limit
    local old_state_content="" old_conf_content="" old_rules_content="" had_state=0 had_conf=0 had_rules=0
    local -a OLD_RULES_SNAPSHOT=()

    if [[ -f "${STATE_FILE}" ]]; then
        old_state_content="$(cat "${STATE_FILE}")"
        had_state=1
    fi
    if [[ -f "${CONF_FILE}" ]]; then
        old_conf_content="$(cat "${CONF_FILE}")"
        had_conf=1
    fi
    if [[ -f "${RULES_FILE}" ]]; then
        old_rules_content="$(cat "${RULES_FILE}")"
        had_rules=1
    fi

    load_rules
    OLD_RULES_SNAPSHOT=("${RULES[@]}")
    ensure_state_for_rules
    load_traffic_state

    for rule in "${RULES[@]}"; do
        IFS='|' read -r rule_id _ _ _ _ quota_gb _ <<< "$rule"
        validate_rule_id "$rule_id" || continue

        current_counter="$(read_counter_bytes "${rule_id}_egress")" || {
            if (( counter_repaired == 0 )); then
                counter_repaired=1
                if ! write_conf_file; then
                    RULES=("${OLD_RULES_SNAPSHOT[@]}")
                    restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
                    return 1
                fi
                if ! reload_rules; then
                    RULES=("${OLD_RULES_SNAPSHOT[@]}")
                    restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
                    return 1
                fi
                warn "检测到流量计数器缺失，已重载 nftables 转发规则。"
                current_counter="$(read_counter_bytes "${rule_id}_egress")" || {
                    warn "读取计数器失败，跳过规则 ${rule_id}"
                    continue
                }
            else
                warn "读取计数器失败，跳过规则 ${rule_id}"
                continue
            fi
        }

        if [[ -z "${current_counter:-}" ]]; then
            warn "读取计数器失败，跳过规则 ${rule_id}"
            continue
        fi

        period_start="$(state_get STATE_PERIOD_START "$rule_id" 0)"
        used_bytes="$(state_get STATE_USED_BYTES "$rule_id" 0)"
        last_counter="$(state_get STATE_LAST_COUNTER "$rule_id" 0)"
        blocked="$(state_get STATE_BLOCKED "$rule_id" 0)"

        if (( period_start == 0 )); then
            period_start="$now"
        fi

        if (( now - period_start >= QUOTA_PERIOD_SECONDS )); then
            if [[ "$blocked" == "1" ]]; then
                changed=1
            fi
            period_start="$now"
            used_bytes=0
            blocked=0
            last_counter="$current_counter"
            state_set STATE_PERIOD_START "$rule_id" "$period_start"
            state_set STATE_USED_BYTES "$rule_id" "$used_bytes"
            state_set STATE_LAST_COUNTER "$rule_id" "$last_counter"
            state_set STATE_BLOCKED "$rule_id" "$blocked"
            continue
        fi

        delta="$(counter_delta "$current_counter" "$last_counter")"
        used_bytes=$((used_bytes + delta))
        last_counter="$current_counter"

        if [[ "$quota_gb" != "0" ]]; then
            quota_limit="$(quota_bytes "$quota_gb")"
            if (( used_bytes >= quota_limit )) && [[ "$blocked" != "1" ]]; then
                blocked=1
                changed=1
            fi
        fi

        state_set STATE_PERIOD_START "$rule_id" "$period_start"
        state_set STATE_USED_BYTES "$rule_id" "$used_bytes"
        state_set STATE_LAST_COUNTER "$rule_id" "$last_counter"
        state_set STATE_BLOCKED "$rule_id" "$blocked"
    done

    refresh_rule_resolved_ips || true
    if (( DOMAIN_RESOLUTION_CHANGED == 1 )); then
        changed=1
    fi

    if ! save_traffic_state; then
        RULES=("${OLD_RULES_SNAPSHOT[@]}")
        restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
        return 1
    fi

    if (( changed == 1 )); then
        if ! write_rules_file; then
            RULES=("${OLD_RULES_SNAPSHOT[@]}")
            restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
            return 1
        fi
        if ! write_conf_file; then
            RULES=("${OLD_RULES_SNAPSHOT[@]}")
            restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
            return 1
        fi
        if ! reload_rules; then
            RULES=("${OLD_RULES_SNAPSHOT[@]}")
            restore_traffic_check_files "$had_state" "$old_state_content" "$had_conf" "$old_conf_content" "$had_rules" "$old_rules_content" || return 1
            reload_rules >/dev/null 2>&1 || true
            return 1
        fi
        sync_domain_resolution_firewall_updates
    fi

    return 0
}

restore_traffic_check_files() {
    local had_state="$1" old_state_content="$2" had_conf="$3" old_conf_content="$4" had_rules="${5:-0}" old_rules_content="${6:-}"
    local tmp_file

    if [[ "$had_state" == "1" ]]; then
        mkdir -p "$(dirname "${STATE_FILE}")" 2>/dev/null || {
            err "无法创建状态目录 $(dirname "${STATE_FILE}")"
            return 1
        }
        if [[ -d "${STATE_FILE}" ]]; then
            err "无法恢复状态文件 ${STATE_FILE}"
            return 1
        fi
        tmp_file="${STATE_FILE}.restore.$$"
        if ! printf '%s\n' "$old_state_content" > "${tmp_file}" 2>/dev/null || ! mv -f "${tmp_file}" "${STATE_FILE}" 2>/dev/null; then
            rm -f "${tmp_file}" 2>/dev/null || true
            err "无法恢复状态文件 ${STATE_FILE}"
            return 1
        fi
    else
        if ! rm -f "${STATE_FILE}" 2>/dev/null; then
            err "无法删除状态文件 ${STATE_FILE}"
            return 1
        fi
    fi

    if [[ "$had_conf" == "1" ]]; then
        mkdir -p "$(dirname "${CONF_FILE}")" 2>/dev/null || {
            err "无法创建配置目录 $(dirname "${CONF_FILE}")"
            return 1
        }
        if [[ -d "${CONF_FILE}" ]]; then
            err "无法恢复配置文件 ${CONF_FILE}"
            return 1
        fi
        tmp_file="${CONF_FILE}.restore.$$"
        if ! printf '%s\n' "$old_conf_content" > "${tmp_file}" 2>/dev/null || ! mv -f "${tmp_file}" "${CONF_FILE}" 2>/dev/null; then
            rm -f "${tmp_file}" 2>/dev/null || true
            err "无法恢复配置文件 ${CONF_FILE}"
            return 1
        fi
    else
        if ! rm -f "${CONF_FILE}" 2>/dev/null; then
            err "无法删除配置文件 ${CONF_FILE}"
            return 1
        fi
    fi

    if [[ "$had_rules" == "1" ]]; then
        mkdir -p "$(dirname "${RULES_FILE}")" 2>/dev/null || {
            err "无法创建规则目录 $(dirname "${RULES_FILE}")"
            return 1
        }
        if [[ -d "${RULES_FILE}" ]]; then
            err "无法恢复规则文件 ${RULES_FILE}"
            return 1
        fi
        tmp_file="${RULES_FILE}.restore.$$"
        if ! printf '%s\n' "$old_rules_content" > "${tmp_file}" 2>/dev/null || ! mv -f "${tmp_file}" "${RULES_FILE}" 2>/dev/null; then
            rm -f "${tmp_file}" 2>/dev/null || true
            err "无法恢复规则文件 ${RULES_FILE}"
            return 1
        fi
    else
        if ! rm -f "${RULES_FILE}" 2>/dev/null; then
            err "无法删除规则文件 ${RULES_FILE}"
            return 1
        fi
    fi
}

run_cli() {
    case "${1:-}" in
        --traffic-check)
            check_root
            init_conf || exit 1
            traffic_check
            ;;
        "")
            check_root
            info "脚本加载中..."
            ensure_gum_available
            init_conf || exit 1
            ensure_traffic_timer_installed || true
            if [[ "${GUM_INSTALL_FAILED:-0}" == "1" ]]; then
                MENU_NOTICE="增强交互依赖 gum 安装失败，将使用基础界面"
            fi
            main_menu
            ;;
        *)
            err "未知参数: $1"
            echo "用法: $0 [--traffic-check]"
            exit 1
            ;;
    esac
}

# ============== 入口 ==============
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_cli "$@"
fi
