#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.2.0"

# 上传到 GitHub 后，如需使用自己的 Raw 地址，可通过环境变量覆盖。
SCRIPT_URL="${TCP_TUNING_SCRIPT_URL:-https://raw.githubusercontent.com/DarkJimiHole/tcp-optimization/main/install.sh}"

BIN_PATH="/usr/local/bin/tcp-tuning"
CONFIG_DIR="/usr/local/etc/tcp-tuning"
CONFIG_FILE="${CONFIG_DIR}/config"
BACKUP_FILE="${CONFIG_DIR}/sysctl.backup"
SYSCTL_FILE="/etc/sysctl.d/99-tcp-tuning.conf"
MODULES_FILE="/etc/modules-load.d/tcp-tuning.conf"
SERVICE_NAME="tcp-tuning"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

MIN_BUFFER_BYTES=$((16 * 1024 * 1024))
MAX_BUFFER_BYTES=$((512 * 1024 * 1024))
FLOOR_BUFFER_BYTES=$((4 * 1024 * 1024))

MAX_LATENCY_MS=10000
MAX_BANDWIDTH_MBPS=1000000

LATENCY_MS=""
BANDWIDTH_MBPS=""
TUNING_ENABLED=0
BBR_ENABLED=0
SHAPE_MBPS=0

if [[ -t 1 ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    RESET=""
fi

ok() { printf '%s\n' "${GREEN}$*${RESET}" >&2; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}" >&2; }
err() { printf '%s\n' "${RED}$*${RESET}" >&2; }
info() { printf '%s\n' "${CYAN}$*${RESET}" >&2; }

clear_screen() {
    command -v clear >/dev/null 2>&1 && clear || printf '\033c'
}

pause() {
    printf '\n'
    read -r -p "按回车键返回菜单..." _ || true
}

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_positive_int() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

sysctl_value() {
    sysctl -n "$1" 2>/dev/null | tr -d '\r'
}

load_config() {
    LATENCY_MS=""
    BANDWIDTH_MBPS=""
    TUNING_ENABLED=0
    BBR_ENABLED=0
    SHAPE_MBPS=0

    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        . "${CONFIG_FILE}" 2>/dev/null || true
    fi

    is_positive_int "${LATENCY_MS:-}" || LATENCY_MS=""
    is_positive_int "${BANDWIDTH_MBPS:-}" || BANDWIDTH_MBPS=""
    [[ "${TUNING_ENABLED:-0}" =~ ^[01]$ ]] || TUNING_ENABLED=0
    [[ "${BBR_ENABLED:-0}" =~ ^[01]$ ]] || BBR_ENABLED=0
    is_positive_int "${SHAPE_MBPS:-}" || SHAPE_MBPS=0
}

save_config() {
    local tmp

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

    tmp="$(mktemp)"
    {
        printf 'LATENCY_MS=%s\n' "${LATENCY_MS:-}"
        printf 'BANDWIDTH_MBPS=%s\n' "${BANDWIDTH_MBPS:-}"
        printf 'TUNING_ENABLED=%s\n' "${TUNING_ENABLED:-0}"
        printf 'BBR_ENABLED=%s\n' "${BBR_ENABLED:-0}"
        printf 'SHAPE_MBPS=%s\n' "${SHAPE_MBPS:-0}"
    } >"${tmp}"

    install -m 600 "${tmp}" "${CONFIG_FILE}"
    rm -f "${tmp}"
}

has_link_config() {
    load_config
    is_positive_int "${LATENCY_MS}" && is_positive_int "${BANDWIDTH_MBPS}"
}

calc_bdp_bytes() {
    local latency_ms="$1"
    local bandwidth_mbps="$2"

    printf '%s\n' "$((latency_ms * bandwidth_mbps * 125))"
}

ceil_to_mib() {
    local bytes="$1"
    local mib=$((1024 * 1024))

    printf '%s\n' "$((((bytes + mib - 1) / mib) * mib))"
}

# Per-socket cap: at most 1/8 of RAM, so a few slow-client sockets on a small
# VPS cannot push the whole box into TCP memory pressure.
calc_buffer_cap() {
    local mem_kb mem_cap
    local cap="${MAX_BUFFER_BYTES}"

    mem_kb="$(awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    if is_positive_int "${mem_kb}"; then
        mem_cap=$((mem_kb * 1024 / 8))
        ((mem_cap < cap)) && cap="${mem_cap}"
    fi
    ((cap < FLOOR_BUFFER_BYTES)) && cap="${FLOOR_BUFFER_BYTES}"

    printf '%s\n' "${cap}"
}

calc_buffer_max() {
    local bdp="$1"
    local target cap

    # BBR keeps up to ~2x BDP in flight, and only ~50-75% of rmem becomes
    # advertised window (skb truesize overhead), so 3x BDP covers both sides.
    target=$((bdp * 3))
    cap="$(calc_buffer_cap)"

    ((target < MIN_BUFFER_BYTES)) && target="${MIN_BUFFER_BYTES}"
    ((target > cap)) && target="${cap}"

    ceil_to_mib "${target}"
}

format_bytes() {
    local bytes="$1"

    if has_cmd awk; then
        awk -v b="${bytes}" 'BEGIN {
            mib = b / 1024 / 1024;
            if (mib >= 1024) {
                printf "%.2f GiB", mib / 1024;
            } else if (mib >= 10) {
                printf "%.0f MiB", mib;
            } else {
                printf "%.2f MiB", mib;
            }
        }'
    else
        printf '%s MiB' "$(((bytes + 1024 * 1024 - 1) / 1024 / 1024))"
    fi
}

link_summary() {
    local bdp buffer

    if ! has_link_config; then
        warn "尚未设置延迟和带宽。"
        return 1
    fi

    bdp="$(calc_bdp_bytes "${LATENCY_MS}" "${BANDWIDTH_MBPS}")"
    buffer="$(calc_buffer_max "${bdp}")"

    printf '\n'
    info "当前链路参数：RTT ${LATENCY_MS} ms，瓶颈带宽 ${BANDWIDTH_MBPS} Mbps"
    info "BDP 约为 $(format_bytes "${bdp}")，脚本将使用 $(format_bytes "${buffer}") 作为 TCP 收发缓冲上限。"
}

backup_current_sysctl() {
    local tmp key value
    local keys=(
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_window_scaling"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.tcp_sack"
        "net.ipv4.tcp_moderate_rcvbuf"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.somaxconn"
        "net.ipv4.tcp_max_syn_backlog"
        "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.tcp_slow_start_after_idle"
        "net.ipv4.tcp_mtu_probing"
        "net.core.netdev_max_backlog"
    )

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

    tmp="$(mktemp)"
    # Keep existing entries (the true pre-tuning values) and only add keys
    # introduced by newer versions, which this runs before applying.
    [[ -f "${BACKUP_FILE}" ]] && cat "${BACKUP_FILE}" >"${tmp}"
    for key in "${keys[@]}"; do
        grep -q "^${key//./\\.}=" "${tmp}" && continue
        value="$(sysctl_value "${key}" || true)"
        [[ -n "${value}" ]] && printf '%s=%s\n' "${key}" "${value}" >>"${tmp}"
    done

    install -m 600 "${tmp}" "${BACKUP_FILE}"
    rm -f "${tmp}"
}

restore_sysctl_backup() {
    local line key value

    [[ -f "${BACKUP_FILE}" ]] || return 0

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ -n "${key}" && "${key}" != "${value}" ]] || continue
        sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
    done <"${BACKUP_FILE}"
}

available_cc_contains() {
    local cc="$1"
    local available

    available="$(sysctl_value net.ipv4.tcp_available_congestion_control || true)"
    [[ " ${available} " == *" ${cc} "* ]]
}

ensure_bbr_available() {
    available_cc_contains bbr && return 0

    if has_cmd modprobe; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    available_cc_contains bbr
}

fallback_congestion_control() {
    if available_cc_contains cubic; then
        printf '%s\n' "cubic"
    elif available_cc_contains reno; then
        printf '%s\n' "reno"
    else
        sysctl_value net.ipv4.tcp_congestion_control || printf '%s\n' "reno"
    fi
}

default_iface() {
    local iface

    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
    if [[ -z "${iface}" ]]; then
        iface="$(ip -o -6 route show to default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi
    if [[ -z "${iface}" ]]; then
        iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi

    printf '%s\n' "${iface}"
}

tx_queue_count() {
    local iface="$1"
    local queues=(/sys/class/net/"${iface}"/queues/tx-*)

    [[ -e "${queues[0]}" ]] || { printf '1\n'; return 0; }
    printf '%s\n' "${#queues[@]}"
}

# Expects net.core.default_qdisc to already be set to the wanted qdisc.
apply_qdisc() {
    local qdisc="${1:-fq}"
    local iface

    has_cmd ip || return 0
    has_cmd tc || return 0

    iface="$(default_iface)"
    [[ -n "${iface}" ]] || return 0

    # On multiqueue NICs keep mq at the root; a fresh mq creates one
    # default_qdisc child per TX queue instead of funnelling all queues
    # through a single qdisc lock. Replacing an existing mq is a no-op that
    # keeps stale children, so drop any tc-created root first (this fails
    # harmlessly when the root is still the kernel default).
    if (($(tx_queue_count "${iface}") > 1)); then
        tc qdisc del dev "${iface}" root >/dev/null 2>&1 || true
        tc qdisc replace dev "${iface}" root handle 1: mq >/dev/null 2>&1 && return 0
    fi

    tc qdisc replace dev "${iface}" root "${qdisc}" >/dev/null 2>&1 || \
        warn "无法把 ${iface} 的 TCP 队列切换为 ${qdisc}，可能是内核未启用该 qdisc。"
}

# cake must be the single root qdisc to shape the aggregate rate.
apply_cake_shaping() {
    local mbps="$1"
    local iface

    has_cmd ip && has_cmd tc || return 1

    iface="$(default_iface)"
    [[ -n "${iface}" ]] || return 1

    if has_cmd modprobe; then
        modprobe sch_cake >/dev/null 2>&1 || true
    fi

    tc qdisc replace dev "${iface}" root cake bandwidth "${mbps}mbit" >/dev/null 2>&1
}

apply_managed_qdisc() {
    load_config

    if [[ "${TUNING_ENABLED}" == "1" && "${SHAPE_MBPS}" -gt 0 ]]; then
        apply_cake_shaping "${SHAPE_MBPS}" && return 0
        warn "无法启用 cake 整形（内核可能未提供 sch_cake），已改用 fq。"
        apply_qdisc fq
    elif [[ "${TUNING_ENABLED}" == "1" || "${BBR_ENABLED}" == "1" ]]; then
        apply_qdisc fq
    fi
}

restore_qdisc_from_backup() {
    local saved

    [[ -f "${BACKUP_FILE}" ]] || return 0
    saved="$(awk -F= '$1=="net.core.default_qdisc" {print $2; exit}' "${BACKUP_FILE}" 2>/dev/null || true)"

    case "${saved}" in
        fq|fq_codel|cake|pfifo_fast)
            apply_qdisc "${saved}"
            ;;
    esac
}

current_qdisc() {
    local iface qdisc fallback

    if has_cmd ip && has_cmd tc; then
        iface="$(default_iface)"
        if [[ -n "${iface}" ]]; then
            qdisc="$(tc qdisc show dev "${iface}" 2>/dev/null | awk 'NR==1 {print $2}')"
            case "${qdisc}" in
                cake)
                    printf '%s\n' "cake（出口整形）"
                    return 0
                    ;;
                fq|fq_codel|pfifo_fast)
                    printf '%s\n' "${qdisc}"
                    return 0
                    ;;
            esac
        fi
    fi

    fallback="$(sysctl_value net.core.default_qdisc || true)"
    case "${fallback}" in
        fq|fq_codel|cake|pfifo_fast)
            printf '%s\n' "${fallback}"
            ;;
        *)
            printf '%s\n' "未知"
            ;;
    esac
}

service_status_text() {
    if [[ ! -f "${SERVICE_FILE}" ]]; then
        printf '%s未安装%s' "${YELLOW}" "${RESET}"
    elif has_cmd systemctl && systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        printf '%s运行中%s' "${GREEN}" "${RESET}"
    else
        printf '%s未运行%s' "${RED}" "${RESET}"
    fi
}

bbr_status_text() {
    local cc

    cc="$(sysctl_value net.ipv4.tcp_congestion_control || true)"
    if [[ "${cc}" == "bbr" ]]; then
        printf '%s已开启%s' "${GREEN}" "${RESET}"
    else
        printf '%s未开启%s' "${YELLOW}" "${RESET}"
    fi
}

latency_text() {
    load_config
    if [[ -n "${LATENCY_MS}" ]]; then
        printf '%s ms' "${LATENCY_MS}"
    else
        printf '%s' "未设置"
    fi
}

bandwidth_text() {
    load_config
    if [[ -n "${BANDWIDTH_MBPS}" ]]; then
        printf '%s Mbps' "${BANDWIDTH_MBPS}"
    else
        printf '%s' "未设置"
    fi
}

shape_text() {
    load_config
    if [[ "${SHAPE_MBPS}" -gt 0 ]]; then
        printf '%s Mbps' "${SHAPE_MBPS}"
    else
        printf '%s' "未开启"
    fi
}

write_modules_file() {
    local tmp

    load_config
    if [[ "${BBR_ENABLED}" == "1" ]]; then
        tmp="$(mktemp)"
        printf '%s\n' "tcp_bbr" >"${tmp}"
        install -m 644 "${tmp}" "${MODULES_FILE}"
        rm -f "${tmp}"
    else
        rm -f "${MODULES_FILE}"
    fi
}

render_sysctl_file() {
    local tmp bdp buffer

    load_config

    if [[ "${TUNING_ENABLED}" != "1" && "${BBR_ENABLED}" != "1" ]]; then
        rm -f "${SYSCTL_FILE}"
        return 0
    fi

    if [[ "${BBR_ENABLED}" == "1" ]] && ! ensure_bbr_available; then
        err "当前内核未提供 BBR：$(sysctl_value net.ipv4.tcp_available_congestion_control || printf '未知')"
        return 1
    fi

    if [[ "${TUNING_ENABLED}" == "1" ]] && ! has_link_config; then
        err "尚未设置延迟和带宽，请先执行：5. 修改延迟和带宽"
        return 1
    fi

    tmp="$(mktemp)"
    {
        printf '%s\n' "# Managed by tcp-tuning ${VERSION}."
        printf '%s\n' "# BDP = bandwidth_mbps * latency_ms * 125 bytes."
        printf '%s\n' "# Do not edit this file manually; run tcp-tuning instead."
        printf '\n'

        if [[ "${BBR_ENABLED}" == "1" ]]; then
            printf '%s\n' "net.core.default_qdisc = fq"
            printf '%s\n' "net.ipv4.tcp_congestion_control = bbr"
        elif [[ "${TUNING_ENABLED}" == "1" ]]; then
            printf '%s\n' "net.core.default_qdisc = fq"
        fi

        if [[ "${TUNING_ENABLED}" == "1" ]]; then
            bdp="$(calc_bdp_bytes "${LATENCY_MS}" "${BANDWIDTH_MBPS}")"
            buffer="$(calc_buffer_max "${bdp}")"

            printf '\n'
            printf '%s\n' "net.ipv4.tcp_window_scaling = 1"
            printf '%s\n' "net.ipv4.tcp_timestamps = 1"
            printf '%s\n' "net.ipv4.tcp_sack = 1"
            printf '%s\n' "net.ipv4.tcp_moderate_rcvbuf = 1"
            printf '%s\n' "net.core.rmem_max = ${buffer}"
            printf '%s\n' "net.core.wmem_max = ${buffer}"
            printf '%s\n' "net.ipv4.tcp_rmem = 4096 131072 ${buffer}"
            printf '%s\n' "net.ipv4.tcp_wmem = 4096 65536 ${buffer}"
            printf '%s\n' "net.core.somaxconn = 8192"
            printf '%s\n' "net.ipv4.tcp_max_syn_backlog = 8192"
            printf '%s\n' "net.ipv4.tcp_notsent_lowat = 131072"
            printf '%s\n' "net.ipv4.tcp_slow_start_after_idle = 0"
            printf '%s\n' "net.ipv4.tcp_mtu_probing = 1"
            printf '%s\n' "net.core.netdev_max_backlog = 16384"
        fi
    } >"${tmp}"

    install -m 644 "${tmp}" "${SYSCTL_FILE}"
    rm -f "${tmp}"
}

apply_managed_sysctl() {
    local quiet="${1:-0}"

    [[ -f "${SYSCTL_FILE}" ]] || return 0

    if [[ "${quiet}" == "1" ]]; then
        sysctl -p "${SYSCTL_FILE}" >/dev/null
    else
        sysctl -p "${SYSCTL_FILE}"
    fi
}

apply_now() {
    local quiet="${1:-0}"

    need_root
    if ! render_sysctl_file; then
        return 1
    fi

    if ! apply_managed_sysctl "${quiet}"; then
        err "sysctl 应用失败。"
        return 1
    fi

    apply_managed_qdisc
}

install_self() {
    local source_path
    local tmp

    source_path="${BASH_SOURCE[0]}"
    tmp="$(mktemp)"

    if [[ -x "${BIN_PATH}" && "${source_path}" == "${BIN_PATH}" ]]; then
        rm -f "${tmp}"
        return 0
    fi

    # A local file is what the user actually ran (possibly edited), so it wins
    # over the Raw URL; the download is only for `bash <(curl ...)` installs.
    if [[ -r "${source_path}" && "${source_path}" != /dev/fd/* && "${source_path}" != /proc/*/fd/* ]]; then
        install -m 755 "${source_path}" "${BIN_PATH}"
        rm -f "${tmp}"
        ok "tcp-tuning 命令已安装：${BIN_PATH}"
        return 0
    fi

    if [[ -n "${SCRIPT_URL}" ]] && has_cmd curl; then
        info "正在安装 tcp-tuning 命令..."
        if curl -fsSL "${SCRIPT_URL}" -o "${tmp}" && install -m 755 "${tmp}" "${BIN_PATH}"; then
            rm -f "${tmp}"
            ok "tcp-tuning 命令已安装：${BIN_PATH}"
            return 0
        fi
    fi

    rm -f "${tmp}"
    warn "无法自动安装 tcp-tuning 命令。请把脚本保存到本地文件后重新运行。"
    return 1
}

quick_install() {
    clear_screen
    printf '%s\n' "${BOLD}安装 TCP 网络调优管理脚本${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    load_config
    save_config

    if install_self; then
        ok "安装完成。"
        info "输入 tcp-tuning 打开管理菜单。"
        info "首次开启调优前，请先在菜单中执行：5. 修改延迟和带宽"
    fi
}

install_service() {
    local tmp

    if ! install_self; then
        return 1
    fi

    if ! has_cmd systemctl; then
        warn "未检测到 systemd，已应用当前配置，但不会安装自启动服务。"
        return 0
    fi

    tmp="$(mktemp)"
    cat >"${tmp}" <<EOF
[Unit]
Description=TCP Network Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH} apply --quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    install -m 644 "${tmp}" "${SERVICE_FILE}"
    rm -f "${tmp}"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

enable_tuning() {
    clear_screen
    printf '%s\n' "${BOLD}开启调优${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root

    if ! has_link_config; then
        err "开启调优前必须先设置延迟和带宽。"
        info "请先执行：5. 修改延迟和带宽"
        return 1
    fi

    backup_current_sysctl

    TUNING_ENABLED=1
    if ensure_bbr_available; then
        BBR_ENABLED=1
    else
        BBR_ENABLED=0
        warn "当前内核未提供 BBR，将只应用窗口和队列调优。"
    fi
    save_config

    write_modules_file
    if ! render_sysctl_file; then
        return 1
    fi

    if ! apply_managed_sysctl 0; then
        err "sysctl 应用失败。"
        return 1
    fi

    apply_managed_qdisc
    install_service || true

    if has_cmd systemctl && [[ -f "${SERVICE_FILE}" ]]; then
        systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || warn "服务启动失败，请执行：systemctl status ${SERVICE_NAME}"
    fi

    link_summary || true
    ok "TCP 调优已开启。"
}

disable_tuning() {
    clear_screen
    printf '%s\n' "${BOLD}关闭调优${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    load_config

    TUNING_ENABLED=0
    BBR_ENABLED=0
    save_config

    if has_cmd systemctl && [[ -f "${SERVICE_FILE}" ]]; then
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    rm -f "${SYSCTL_FILE}" "${MODULES_FILE}"
    restore_sysctl_backup
    restore_qdisc_from_backup

    if has_cmd systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    ok "TCP 调优已关闭，并已尝试恢复开启前的 sysctl 值。"
}

enable_bbr() {
    clear_screen
    printf '%s\n' "${BOLD}开启 BBR${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    backup_current_sysctl

    if ! ensure_bbr_available; then
        err "当前内核不支持 BBR。可用拥塞控制：$(sysctl_value net.ipv4.tcp_available_congestion_control || printf '未知')"
        return 1
    fi

    load_config
    BBR_ENABLED=1
    save_config

    write_modules_file
    if ! render_sysctl_file; then
        return 1
    fi

    if ! apply_managed_sysctl 0; then
        err "sysctl 应用失败。"
        return 1
    fi

    apply_managed_qdisc

    ok "BBR 已开启。"
}

disable_bbr() {
    local fallback

    clear_screen
    printf '%s\n' "${BOLD}关闭 BBR${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    load_config

    BBR_ENABLED=0
    save_config

    write_modules_file
    if ! render_sysctl_file; then
        return 1
    fi

    if ! apply_managed_sysctl 0; then
        warn "部分 sysctl 应用失败，请检查 ${SYSCTL_FILE}。"
    fi

    fallback="$(fallback_congestion_control)"
    sysctl -w "net.ipv4.tcp_congestion_control=${fallback}" >/dev/null 2>&1 || true

    if [[ "${TUNING_ENABLED}" != "1" ]]; then
        restore_qdisc_from_backup
    fi

    ok "BBR 已关闭，当前拥塞控制：$(sysctl_value net.ipv4.tcp_congestion_control || printf '未知')"
}

prompt_positive_int() {
    local prompt="$1"
    local default="${2:-}"
    local max="${3:-}"
    local input

    while true; do
        if [[ -n "${default}" ]]; then
            read -r -p "${prompt} [${default}]: " input
            input="${input:-${default}}"
        else
            read -r -p "${prompt}: " input
        fi

        if is_positive_int "${input}" && { [[ -z "${max}" ]] || ((${#input} <= ${#max} && input <= max)); }; then
            printf '%s\n' "${input}"
            return 0
        fi

        err "请输入正整数${max:+（不超过 ${max}）}。"
    done
}

modify_link_config() {
    local old_latency old_bandwidth

    clear_screen
    printf '%s\n' "${BOLD}修改延迟和带宽${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    load_config

    old_latency="${LATENCY_MS:-}"
    old_bandwidth="${BANDWIDTH_MBPS:-}"

    info "带宽请填写两端之间的实际瓶颈带宽。例：本地 500M、VPS 1G，则填 500。"
    info "RTT 请填写 ping 出来的往返延迟，例如 150。"
    printf '\n'

    LATENCY_MS="$(prompt_positive_int "请输入 RTT 延迟，单位 ms" "${old_latency}" "${MAX_LATENCY_MS}")"
    BANDWIDTH_MBPS="$(prompt_positive_int "请输入瓶颈带宽，单位 Mbps" "${old_bandwidth}" "${MAX_BANDWIDTH_MBPS}")"
    save_config

    link_summary || true

    if [[ "${TUNING_ENABLED}" == "1" ]]; then
        if ! render_sysctl_file; then
            return 1
        fi

        if ! apply_managed_sysctl 0; then
            err "sysctl 应用失败。"
            return 1
        fi

        apply_managed_qdisc
        if has_cmd systemctl && [[ -f "${SERVICE_FILE}" ]]; then
            systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
        ok "参数已更新并重新应用。"
    else
        ok "参数已保存。现在可以执行：1. 开启调优"
    fi
}

modify_shaping() {
    local input suggest

    clear_screen
    printf '%s\n' "${BOLD}设置出口整形（cake）${RESET}"
    printf '%s\n\n' "----------------------------------------"

    need_root
    load_config

    info "整形会把本机出口（VPS -> 客户端方向）总速率压到设定值，"
    info "让排队发生在本机 cake 中，而不是在上游限速器处被直接丢包。"
    info "只在稳定阶段重传仍然偏高时才建议开启，通常取瓶颈带宽的 90%-95%。"
    info "输入 0 关闭整形。"
    printf '\n'

    suggest="${SHAPE_MBPS}"
    if [[ "${suggest}" -eq 0 && -n "${BANDWIDTH_MBPS}" ]]; then
        suggest=$((BANDWIDTH_MBPS * 92 / 100))
        ((suggest > 0)) || suggest=1
    fi

    while true; do
        read -r -p "请输入整形速率，单位 Mbps [${suggest}]: " input
        input="${input:-${suggest}}"
        if [[ "${input}" == "0" ]] || { is_positive_int "${input}" && ((${#input} <= ${#MAX_BANDWIDTH_MBPS} && input <= MAX_BANDWIDTH_MBPS)); }; then
            break
        fi
        err "请输入 0 或不超过 ${MAX_BANDWIDTH_MBPS} 的正整数。"
    done

    SHAPE_MBPS="${input}"
    save_config

    if [[ "${TUNING_ENABLED}" != "1" ]]; then
        ok "已保存，开启调优后生效。"
        return 0
    fi

    if [[ "${SHAPE_MBPS}" -gt 0 ]]; then
        if apply_cake_shaping "${SHAPE_MBPS}"; then
            ok "cake 出口整形已开启：${SHAPE_MBPS} Mbps"
        else
            SHAPE_MBPS=0
            save_config
            apply_managed_qdisc
            err "无法启用 cake 整形，内核可能未提供 sch_cake。已关闭整形并恢复 fq。"
            return 1
        fi
    else
        apply_managed_qdisc
        ok "出口整形已关闭，已恢复 fq。"
    fi
}

uninstall_all() {
    local input

    clear_screen
    printf '%s\n' "${BOLD}卸载脚本${RESET}"
    printf '%s\n\n' "----------------------------------------"
    warn "此操作会删除 tcp-tuning 命令、服务、配置文件，并尝试恢复开启前的 sysctl 值。"
    read -r -p "按回车确认卸载，输入 n 取消: " input

    if [[ "${input}" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return 0
    fi

    need_root

    if has_cmd systemctl; then
        systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    restore_sysctl_backup
    restore_qdisc_from_backup

    rm -f "${SYSCTL_FILE}" "${MODULES_FILE}" "${SERVICE_FILE}" "${BIN_PATH}"
    rm -rf "${CONFIG_DIR}"

    if has_cmd systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    ok "卸载完成。"
    exit 0
}

show_main_menu() {
    clear_screen
    printf '%s\n' "${BOLD}        TCP 网络调优 管理脚本${RESET}"
    printf '%s\n' "==============================================="
    printf '\n'
    printf '服务状态： %s\n' "$(service_status_text)"
    printf 'BBR 状态： %s\n' "$(bbr_status_text)"
    printf 'TCP 队列： %s\n' "$(current_qdisc)"
    printf '适用延迟： %s\n' "$(latency_text)"
    printf '带宽大小： %s\n' "$(bandwidth_text)"
    printf '出口整形： %s\n' "$(shape_text)"
    printf '\n'
    printf '%s\n' "-----------------------------------------------"
    printf '%s\n' "  1. 开启调优"
    printf '%s\n' "  2. 关闭调优"
    printf '%s\n' "  3. 开启 BBR"
    printf '%s\n' "  4. 关闭 BBR"
    printf '%s\n' "  5. 修改延迟和带宽"
    printf '%s\n' "  6. 设置出口整形（cake）"
    printf '%s\n' "  7. 卸载脚本"
    printf '%s\n' "  0. 退出"
    printf '%s\n' "-----------------------------------------------"
    printf '\n'
}

main_menu() {
    local choice

    need_root

    while true; do
        show_main_menu
        read -r -p "请输入选项 [0-7]: " choice

        case "${choice}" in
            1) enable_tuning || true; pause ;;
            2) disable_tuning || true; pause ;;
            3) enable_bbr || true; pause ;;
            4) disable_bbr || true; pause ;;
            5) modify_link_config || true; pause ;;
            6) modify_shaping || true; pause ;;
            7) uninstall_all || true; pause ;;
            0) exit 0 ;;
            *) err "请输入 0-7。"; pause ;;
        esac
    done
}

running_from_process_substitution() {
    [[ "${BASH_SOURCE[0]}" == /dev/fd/* || "${BASH_SOURCE[0]}" == /proc/*/fd/* ]]
}

case "${1:-}" in
    install|--install)
        quick_install
        ;;
    apply)
        if [[ "${2:-}" == "--quiet" ]]; then
            apply_now 1
        else
            apply_now 0
        fi
        ;;
    enable|--enable)
        enable_tuning
        ;;
    disable|--disable)
        disable_tuning
        ;;
    bbr-on|--bbr-on)
        enable_bbr
        ;;
    bbr-off|--bbr-off)
        disable_bbr
        ;;
    config|--config)
        modify_link_config
        ;;
    shape|--shape)
        modify_shaping
        ;;
    uninstall|--uninstall)
        uninstall_all
        ;;
    menu|--menu)
        main_menu
        ;;
    "")
        if running_from_process_substitution; then
            quick_install
        else
            main_menu
        fi
        ;;
    *)
        err "未知参数：$1"
        printf '%s\n' "用法：$0 [install|menu|apply|enable|disable|bbr-on|bbr-off|config|shape|uninstall]"
        exit 1
        ;;
esac
