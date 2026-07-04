#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.0"

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

MIN_BUFFER_BYTES=$((64 * 1024 * 1024))
MAX_BUFFER_BYTES=$((512 * 1024 * 1024))

LATENCY_MS=""
BANDWIDTH_MBPS=""
TUNING_ENABLED=0
BBR_ENABLED=0

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

    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        . "${CONFIG_FILE}" 2>/dev/null || true
    fi

    is_positive_int "${LATENCY_MS:-}" || LATENCY_MS=""
    is_positive_int "${BANDWIDTH_MBPS:-}" || BANDWIDTH_MBPS=""
    [[ "${TUNING_ENABLED:-0}" =~ ^[01]$ ]] || TUNING_ENABLED=0
    [[ "${BBR_ENABLED:-0}" =~ ^[01]$ ]] || BBR_ENABLED=0
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

calc_buffer_max() {
    local bdp="$1"
    local target

    # Keep enough room for Linux packet metadata and advertised window overhead.
    target=$((bdp * 4))

    if ((target < MIN_BUFFER_BYTES)); then
        target="${MIN_BUFFER_BYTES}"
    elif ((target > MAX_BUFFER_BYTES)); then
        target="${MAX_BUFFER_BYTES}"
    fi

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
    )

    [[ -f "${BACKUP_FILE}" ]] && return 0

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

    tmp="$(mktemp)"
    for key in "${keys[@]}"; do
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
        iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi

    printf '%s\n' "${iface}"
}

apply_qdisc() {
    local qdisc="${1:-fq}"
    local iface

    has_cmd ip || return 0
    has_cmd tc || return 0

    iface="$(default_iface)"
    [[ -n "${iface}" ]] || return 0

    tc qdisc replace dev "${iface}" root "${qdisc}" >/dev/null 2>&1 || \
        warn "无法把 ${iface} 的 TCP 队列切换为 ${qdisc}，可能是内核未启用该 qdisc。"
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
                fq|fq_codel|cake|pfifo_fast)
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

    load_config
    if [[ "${TUNING_ENABLED}" == "1" || "${BBR_ENABLED}" == "1" ]]; then
        apply_qdisc fq
    fi
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

    if [[ -n "${SCRIPT_URL}" ]] && has_cmd curl; then
        info "正在安装 tcp-tuning 命令..."
        if curl -fsSL "${SCRIPT_URL}" -o "${tmp}" && install -m 755 "${tmp}" "${BIN_PATH}"; then
            rm -f "${tmp}"
            ok "tcp-tuning 命令已安装：${BIN_PATH}"
            return 0
        fi
        warn "无法从 Raw 地址安装 tcp-tuning，尝试使用当前脚本。"
    fi

    if [[ -r "${source_path}" && "${source_path}" != /dev/fd/* && "${source_path}" != /proc/*/fd/* ]]; then
        install -m 755 "${source_path}" "${BIN_PATH}"
        rm -f "${tmp}"
        ok "tcp-tuning 命令已安装：${BIN_PATH}"
        return 0
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

    apply_qdisc fq
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

    apply_qdisc fq

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
    local input

    while true; do
        if [[ -n "${default}" ]]; then
            read -r -p "${prompt} [${default}]: " input
            input="${input:-${default}}"
        else
            read -r -p "${prompt}: " input
        fi

        if is_positive_int "${input}"; then
            printf '%s\n' "${input}"
            return 0
        fi

        err "请输入正整数。"
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

    LATENCY_MS="$(prompt_positive_int "请输入 RTT 延迟，单位 ms" "${old_latency}")"
    BANDWIDTH_MBPS="$(prompt_positive_int "请输入瓶颈带宽，单位 Mbps" "${old_bandwidth}")"
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

        apply_qdisc fq
        if has_cmd systemctl && [[ -f "${SERVICE_FILE}" ]]; then
            systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
        fi
        ok "参数已更新并重新应用。"
    else
        ok "参数已保存。现在可以执行：1. 开启调优"
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
    printf '\n'
    printf '%s\n' "-----------------------------------------------"
    printf '%s\n' "  1. 开启调优"
    printf '%s\n' "  2. 关闭调优"
    printf '%s\n' "  3. 开启 BBR"
    printf '%s\n' "  4. 关闭 BBR"
    printf '%s\n' "  5. 修改延迟和带宽"
    printf '%s\n' "  6. 卸载脚本"
    printf '%s\n' "  0. 退出"
    printf '%s\n' "-----------------------------------------------"
    printf '\n'
}

main_menu() {
    local choice

    need_root

    while true; do
        show_main_menu
        read -r -p "请输入选项 [0-6]: " choice

        case "${choice}" in
            1) enable_tuning || true; pause ;;
            2) disable_tuning || true; pause ;;
            3) enable_bbr || true; pause ;;
            4) disable_bbr || true; pause ;;
            5) modify_link_config || true; pause ;;
            6) uninstall_all || true; pause ;;
            0) exit 0 ;;
            *) err "请输入 0-6。"; pause ;;
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
        printf '%s\n' "用法：$0 [install|menu|apply|enable|disable|bbr-on|bbr-off|config|uninstall]"
        exit 1
        ;;
esac
