#!/bin/bash
# ============================================================
# install.sh — Singbox-Pro v2 一键部署脚本
# 仅负责首次部署：安装依赖 → 下载核心 → 下载模块 → 初始配置
# 管理功能请使用: sb 命令
# ============================================================
set -euo pipefail

export SCRIPT_VERSION="2.0.2"
# SB_VERSION 由 lib/core.sh 统一定义（SSOT），安装阶段在下载模块后从中读取

# --- 颜色 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; NC='\033[0m'

_info()  { echo -e "${CYAN}[信息]${NC} $1"; }
_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
_warn()  { echo -e "${YELLOW}[注意]${NC} $1"; }
_err()   { echo -e "${RED}[错误]${NC} $1"; exit 1; }

# --- 路径 ---
SINGBOX_DIR="/usr/local/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
INSTALL_DIR="/usr/local/share/singbox-pro"
LIB_DIR="${INSTALL_DIR}/lib"
SB_SCRIPT="${INSTALL_DIR}/sb.sh"
SHORTCUT="/usr/local/bin/sb"

# --- GitHub 仓库 ---
REPO_RAW="https://raw.githubusercontent.com/BradMa1/Singbox-Pro/main"

# --- 检测 ---
_check_root() {
    [ "$EUID" -eq 0 ] || _err "请使用 root 权限运行: sudo bash install.sh"
}

_detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
    else
        OS="unknown"
    fi
}

_get_arch() {
    local a=$(uname -m)
    case $a in x86_64|amd64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; *) echo "amd64" ;; esac
}

# --- 下载 ---
_dl() {
    curl -fsSL --connect-timeout 10 --max-time 120 "$1" -o "$2" 2>/dev/null || \
    wget -qO "$2" "$1" 2>/dev/null
}

_dl_with_fallback() {
    local url="$1" target="$2" desc="$3"
    if _dl "$url" "$target"; then
        return 0
    fi
    _warn "${desc} 主源下载失败，尝试镜像..."
    local mirror="${GH_MIRROR:-https://ghproxy.net/}${url}"
    if _dl "$mirror" "$target"; then
        return 0
    fi
    return 1
}

# ============================================================
# 第一步: 安装系统依赖
# ============================================================
_step_deps() {
    _info "正在安装系统依赖..."

    _detect_os

    case "$OS" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            # 修复常见的已 EOL Debian 源问题（bullseye 等）
            # 1. 注释掉主源文件中的 backports 行
            if [ -f /etc/apt/sources.list ]; then
                sed -i '/backports/s/^deb/# deb/' /etc/apt/sources.list 2>/dev/null || true
            fi
            # 2. 删除 backports 源列表文件（常见问题：/etc/apt/sources.list.d/backports.list）
            for f in /etc/apt/sources.list.d/*; do
                [ -f "$f" ] && grep -q "backports" "$f" 2>/dev/null && rm -f "$f"
            done
            apt-get update -qq 2>/dev/null || apt-get update -qq
            apt-get install -y curl wget openssl jq tar gzip net-tools iproute2 dnsutils >/dev/null 2>&1
            ;;
        alpine)
            apk update >/dev/null 2>&1
            apk add --no-cache curl wget openssl jq tar gzip net-tools iproute2 bash bind-tools >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y curl wget openssl jq tar gzip net-tools iproute bind-utils >/dev/null 2>&1
            else
                yum install -y curl wget openssl jq tar gzip net-tools iproute bind-utils >/dev/null 2>&1
            fi
            ;;
        *)
            _warn "未识别的系统 (${OS})，尝试继续..."
            ;;
    esac

    # 验证关键依赖（curl / wget 至少其一，jq / openssl 必须）
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        _err "核心依赖 curl 或 wget 均未安装，请先安装其中之一"
    fi
    for cmd in jq openssl; do
        command -v "$cmd" &>/dev/null || _err "核心依赖 ${cmd} 安装失败"
    done

    _ok "系统依赖就绪"
}

# ============================================================
# 第二步: 下载 sing-box 核心
# ============================================================
_step_singbox() {
    # SB_VERSION 定义为 lib/core.sh（SSOT），模块已在前一步下载
    if [ -z "${SB_VERSION:-}" ] && [ -f "${LIB_DIR}/core.sh" ]; then
        source "${LIB_DIR}/core.sh" 2>/dev/null || true
    fi
    local version="${SB_VERSION:-1.13.14}"

    if [ -f "$SINGBOX_BIN" ]; then
        local current=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $3}' || echo "?")
        _info "sing-box 已安装: v${current}"
        read -p "重新安装/更新? [y/N]: " reinstall
        [ "$reinstall" != "y" ] && [ "$reinstall" != "Y" ] && return 0
    fi

    local arch=$(_get_arch)
    local pkg="sing-box-${version}-linux-${arch}"
    # Alpine 使用 musl libc，需下载 musl 专用版本
    [ "$OS" == "alpine" ] && pkg="${pkg}-musl"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${pkg}.tar.gz"

    _info "正在下载 sing-box v${version} (${arch})..."
    local tmp=$(mktemp -d)

    if ! _dl_with_fallback "$url" "${tmp}/sing-box.tar.gz" "sing-box"; then
        rm -rf "$tmp"
        _err "sing-box 下载失败，请检查网络连接"
    fi

    tar -xzf "${tmp}/sing-box.tar.gz" -C "$tmp"
    cp -f "${tmp}/${pkg}/sing-box" "$SINGBOX_BIN" 2>/dev/null || \
        cp -f "${tmp}/sing-box" "$SINGBOX_BIN" 2>/dev/null || {
        rm -rf "$tmp"
        _err "找不到 sing-box 可执行文件"
    }

    chmod +x "$SINGBOX_BIN"
    rm -rf "$tmp"
    _ok "sing-box v${version} 安装完成"
}

# ============================================================
# 第三步: 下载管理脚本和模块
# ============================================================
_step_scripts() {
    _info "正在下载管理脚本和模块..."

    mkdir -p "$LIB_DIR"

    # 下载入口脚本
    if _dl_with_fallback "${REPO_RAW}/sb.sh" "$SB_SCRIPT" "sb.sh"; then
        chmod +x "$SB_SCRIPT"
        _ok "sb.sh"
    else
        _err "sb.sh 下载失败"
    fi

    # 下载模块
    local modules=("core.sh" "singbox.sh" "protocols.sh" "argo.sh" "warp.sh" "relay.sh" "ui.sh")
    for mod in "${modules[@]}"; do
        if _dl_with_fallback "${REPO_RAW}/lib/${mod}" "${LIB_DIR}/${mod}" "lib/${mod}"; then
            echo -e "  ${GREEN}√${NC} lib/${mod}"
        else
            _err "lib/${mod} 下载失败"
        fi
    done

    # 创建快捷命令
    ln -sf "$SB_SCRIPT" "$SHORTCUT"
    chmod +x "$SHORTCUT" 2>/dev/null || true
    _ok "快捷命令 sb 已就绪"
}

# ============================================================
# 第四步: 生成初始配置
# ============================================================
_step_config() {
    _info "正在生成初始配置..."

    mkdir -p "$SINGBOX_DIR"

    # 优先使用 lib 模块生成完整配置（含 dns / route / ntp），
    # 否则回退到内嵌极简配置（保证裸安装也能启动）
    if [ -f "${LIB_DIR}/core.sh" ] && [ -f "${LIB_DIR}/singbox.sh" ]; then
        # shellcheck disable=SC1091
        source "${LIB_DIR}/core.sh" 2>/dev/null || true
        # shellcheck disable=SC1091
        source "${LIB_DIR}/singbox.sh" 2>/dev/null || true
        _sb_generate_config
        _sb_init_metadata
        _ok "配置文件已生成（含 DNS / 路由 / NTP 完整配置）"
    else
        _warn "未找到 lib 模块，使用内嵌极简配置"
        # 如果配置已存在，备份
        if [ -s "${SINGBOX_DIR}/config.json" ]; then
            cp "${SINGBOX_DIR}/config.json" "${SINGBOX_DIR}/config.json.backup.$(date +%Y%m%d_%H%M%S)"
            _info "已备份现有配置"
        fi
        cat > "${SINGBOX_DIR}/config.json" << 'CONFEOF'
{
    "log": {
        "level": "warn",
        "output": "/var/log/sing-box.log",
        "timestamp": true
    },
    "inbounds": [],
    "outbounds": [
        {"tag": "direct", "type": "direct"},
        {
            "tag": "proxy",
            "type": "selector",
            "outbounds": ["direct"]
        }
    ]
}
CONFEOF
        cat > "${SINGBOX_DIR}/metadata.json" << 'CONFEOF'
{"version": "2.0.2", "created_at": "", "server_ip": "", "protocols": {}, "argo": {}}
CONFEOF
        _ok "配置文件已生成（极简模式）"
    fi
}

# ============================================================
# 第五步: 设置 systemd 服务
# ============================================================
_step_service() {
    _info "正在设置系统服务..."

    # 检测 init 系统
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_DIR}/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1

        # 启动并验证
        _info "正在启动 sing-box..."
        systemctl restart sing-box
        sleep 2

        if systemctl is-active --quiet sing-box; then
            _ok "sing-box 服务已启动"
        else
            _warn "sing-box 启动可能存在问题，请稍后检查: systemctl status sing-box"
            _warn "常见原因: 空 inbounds 配置，添加节点后会自动恢复正常"
        fi

    elif command -v rc-service &>/dev/null; then
        cat > /etc/init.d/sing-box << 'SVCALPINE'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="true"
pidfile="/run/sing-box.pid"
SVCALPINE
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart 2>/dev/null || true
        _ok "sing-box OpenRC 服务已设置"
    else
        _warn "无法识别 init 系统，请手动设置服务"
    fi

    # 设置日志轮转（如果系统支持 logrotate）
    if command -v logrotate &>/dev/null && [ ! -f /etc/logrotate.d/sing-box ]; then
        cat > /etc/logrotate.d/sing-box << 'LOGROTEOF'
/var/log/sing-box.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTEOF
        _ok "日志轮转已配置 (保留 7 天，自动压缩)"
    fi
}

# ============================================================
# 第六步: 防火墙提示
# ============================================================
_step_firewall_hint() {
    echo ""
    _info "=========================================="
    _info "  部署完成!"
    _info "=========================================="
    echo ""

    # 获取公网 IP（curl / wget 二选一）
    local ip=$(timeout 5 curl -s4 icanhazip.com 2>/dev/null || \
               timeout 5 curl -s4 ipinfo.io/ip 2>/dev/null || \
               timeout 5 wget -qO- icanhazip.com 2>/dev/null || \
               timeout 5 wget -qO- ipinfo.io/ip 2>/dev/null || \
               echo "未知")

    echo -e "  ${CYAN}服务器 IP:${NC} ${ip}"
    echo -e "  ${CYAN}管理命令:${NC} sb"
    echo ""

    echo -e "  ${YELLOW}【重要】下一步操作:${NC}"
    echo -e "    1. 运行 ${GREEN}sb${NC} 进入管理面板添加节点"
    echo -e "    2. 添加节点后，检查端口是否监听: ${GREEN}ss -tlnp${NC}"
    echo -e "    3. ${YELLOW}检查 VPS 面板防火墙是否放行对应端口${NC}"
    echo -e "    4. 对于 TLS 协议 (AnyTLS/TUIC/Hy2), 可先生成证书"
    echo ""

    echo -e "  ${YELLOW}【快速命令】${NC}"
    echo -e "    sb          管理面板"
    echo -e "    sb status   查看状态"
    echo -e "    sb restart  重启服务"
    echo -e "    sb log      实时日志"
    echo ""

    echo -e "  ${YELLOW}【文件位置】${NC}"
    echo -e "    脚本: ${INSTALL_DIR}/"
    echo -e "    配置: ${SINGBOX_DIR}/config.json"
    echo -e "    日志: /var/log/sing-box.log"
    echo ""
    echo -e "  ${CYAN}正在进入管理面板...${NC}"
    sleep 1
}

# ============================================================
# 主流程
# ============================================================

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        Singbox-Pro v${SCRIPT_VERSION} 一键部署           ║${NC}"
echo -e "${CYAN}║        Multi-Protocol Proxy Suite              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════╝${NC}"
echo ""

_check_root
_step_deps
_step_scripts
_step_singbox
_step_config
_step_service
_step_firewall_hint

# 自动进入管理面板
if command -v sb &>/dev/null; then
    exec sb
else
    echo -e "  ${YELLOW}快捷命令 sb 未就绪，请手动运行: bash ${SB_SCRIPT}${NC}"
fi
