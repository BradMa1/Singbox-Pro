#!/bin/bash
# ============================================================
# sb.sh — Singbox-Pro v2 主入口
# 引导加载所有功能模块，启动管理面板
#
# 用法:
#   sb              # 启动管理面板
#   sb status       # 查看状态
#   sb restart      # 重启 sing-box 服务
#
# 安装后可通过快捷键 sb 直接调用
# ============================================================
set -euo pipefail

# SCRIPT_VERSION / PROJECT_VERSION 由 core.sh 统一定义（SSOT），加载模块后自动获取
export SCRIPT_NAME="Singbox-Pro"

# --- 路径定义 ---
SELF_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"
LIB_DIR="${SCRIPT_DIR}/lib"

# --- 快捷命令安装 ---
SHORTCUT_PATH="/usr/local/bin/sb"

_install_shortcut() {
    # 如果在 VPS 上运行，创建 sb 快捷命令
    if [ "$EUID" -eq 0 ] && [ "$SELF_PATH" != "$SHORTCUT_PATH" ]; then
        ln -sf "$SELF_PATH" "$SHORTCUT_PATH" 2>/dev/null || true
    fi
}

# --- 加载模块 ---
_load_modules() {
    local modules=(
        "core.sh"
        "singbox.sh"
        "protocols.sh"
        "argo.sh"
        "warp.sh"
        "relay.sh"
        "ui.sh"
    )

    local missing=""
    for mod in "${modules[@]}"; do
        if [ -f "${LIB_DIR}/${mod}" ]; then
            source "${LIB_DIR}/${mod}"
        else
            missing="${missing} ${mod}"
        fi
    done

    if [ -n "$missing" ]; then
        echo -e "\033[0;31m[错误]\033[0m 缺少模块:${missing}"
        echo ""
        echo "请确保 lib/ 目录完整，或重新运行 install.sh"
        exit 1
    fi
}

# --- 检查依赖 ---
_check_deps() {
    # 硬依赖：jq / curl 必须存在（JSON 解析与下载）
    local hard_missing=""
    for cmd in jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            hard_missing="$hard_missing $cmd"
        fi
    done
    if [ -n "$hard_missing" ]; then
        echo -e "\033[0;31m[错误]\033[0m 缺少核心依赖:${hard_missing}"
        echo "请运行: apt-get install -y jq curl"
        exit 1
    fi

    # 软依赖：openssl 仅 TLS 协议 (AnyTLS/TUIC/Hy2) 生成证书时需要。
    # 容器 apt 源失效时可能装不上，但不应阻断面板本身启动（非 TLS 协议仍可用）。
    if ! command -v openssl &>/dev/null; then
        echo -e "\033[0;33m[注意]\033[0m openssl 未安装：使用 TLS 类协议 (AnyTLS/TUIC/Hy2) 前请先安装（apt-get install -y openssl 或静态方式）"
    fi
}

# --- 主入口 ---
main() {
    _install_shortcut

    case "${1:-}" in
        status)
            _check_deps
            _load_modules
            echo "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ==="
            echo ""
            echo "系统: $(_get_os_info)"
            echo "Init:  ${INIT_SYSTEM:-未检测}"
            echo "Sing-box: v$(_sb_get_version)  $(_sb_get_status)"
            echo "Argo: $(_argo_get_status)"
            echo "WARP: $(_warp_get_status)"
            echo "节点: $(_sb_get_inbound_count) 个"
            echo "协议: $(_sb_get_protocols)"
            ;;

        restart)
            _check_deps
            _load_modules
            _sb_restart_and_verify
            ;;

        stop)
            _check_deps
            _load_modules
            _manage_service "stop"
            ;;

        log)
            _check_deps
            _load_modules
            if [ -f /var/log/sing-box.log ]; then
                tail -f /var/log/sing-box.log
            else
                journalctl -u sing-box -f --no-pager
            fi
            ;;

        backup)
            _check_deps
            _load_modules
            _sb_backup_config
            ;;

        upgrade)
            _check_deps
            _load_modules
            _sb_upgrade_scripts
            ;;

        upgrade-config)
            # v2.1.0 新增：一键升级老证书(无SAN)+ 老 DNS(8.8.8.8/223.5.5.5)
            _check_deps
            _load_modules
            _sb_upgrade_legacy_config
            ;;

        health)
            _check_deps
            _load_modules
            _sb_health_check
            ;;

        install)
            # 在 VPS 上首次安装时调用
            echo "请使用 install.sh 进行首次部署:"
            echo "  bash install.sh"
            ;;

        help|--help|-h)
            echo "Singbox-Pro v${SCRIPT_VERSION} — 多协议代理管理面板"
            echo ""
            echo "用法: sb [命令]"
            echo ""
            echo "命令:"
            echo "  (无参数)    启动管理面板"
            echo "  status      查看运行状态"
            echo "  health      深度健康检查"
            echo "  restart     重启 sing-box 服务"
            echo "  stop        停止 sing-box 服务"
            echo "  log         查看实时日志"
            echo "  upgrade     升级管理脚本到最新版"
            echo "  upgrade-config  升级老证书/SAN + 老 DNS (8.8.8.8→1.1.1.1)"
            echo "  backup      备份配置"
            echo "  help        显示此帮助"
            ;;

        *)
            # 检查 root 权限
            if [ "$EUID" -ne 0 ]; then
                echo -e "\033[0;31m[错误]\033[0m 管理面板需要 root 权限"
                echo "请使用: sudo sb"
                exit 1
            fi

            _check_deps
            _load_modules

            # 检查 sing-box 是否已安装，未安装则提示
            if ! _sb_is_installed 2>/dev/null; then
                echo -e "\033[0;33m[注意]\033[0m sing-box 未安装"
                echo "请先运行: bash install.sh"
                echo ""
                read -p "按回车键退出..."
                exit 1
            fi

            # 启动主菜单
            # 检测老证书/老 DNS（v2.1.0 引入），给老用户升级提示
            _sb_check_legacy_config
            _ui_main_menu
            ;;
    esac
}

main "$@"
