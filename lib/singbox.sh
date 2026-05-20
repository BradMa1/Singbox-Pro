#!/bin/bash
# ============================================================
# singbox.sh — Sing-box 核心安装/配置/服务管理模块
# 可被 sb.sh source 加载，也可独立运行
# ============================================================
export SINGBOX_MOD_VERSION="2.0.0"

# --- 路径定义 ---
SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CONFIG_FILE="${CONFIG_FILE:-${SINGBOX_DIR}/config.json}"
METADATA_FILE="${METADATA_FILE:-${SINGBOX_DIR}/metadata.json}"
SB_VERSION="${SB_VERSION:-1.13.12}"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh，请确保模块完整"
        exit 1
    }
fi

# --- 架构检测 ---
_get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)             echo "amd64" ;;
    esac
}

# --- 安装/更新 sing-box 核心 ---
_sb_install_core() {
    local arch=$(_get_arch)
    local version="${1:-${SB_VERSION}}"
    local tmp_dir=$(mktemp -d)
    local pkg_name="sing-box-${version}-linux-${arch}"
    # Alpine 使用 musl libc，需下载 musl 专用版本
    [ -f /etc/alpine-release ] && pkg_name="${pkg_name}-musl"
    local base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"

    _info "正在下载 sing-box v${version} (${arch})..."

    # GitHub 主源
    if ! _download "${base_url}/${pkg_name}.tar.gz" "${tmp_dir}/sing-box.tar.gz"; then
        # 镜像源回退
        _warn "GitHub 下载失败，尝试镜像源..."
        local mirror_url="https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${version}/${pkg_name}.tar.gz"
        if ! _download "${mirror_url}" "${tmp_dir}/sing-box.tar.gz"; then
            _error "sing-box 下载失败，请检查网络"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir"
    cp -f "${tmp_dir}/${pkg_name}/sing-box" "$SINGBOX_BIN" 2>/dev/null || {
        # 旧版目录结构兼容
        cp -f "${tmp_dir}/sing-box" "$SINGBOX_BIN" 2>/dev/null || {
            _error "找不到 sing-box 可执行文件"
            rm -rf "$tmp_dir"
            return 1
        }
    }

    chmod +x "$SINGBOX_BIN"
    rm -rf "$tmp_dir"

    _success "sing-box v${version} 安装完成"
    return 0
}

# --- 生成基础 config.json ---
_sb_generate_config() {
    mkdir -p "$SINGBOX_DIR"

    # 如果配置已存在且非空，先备份
    if [ -s "$CONFIG_FILE" ]; then
        local backup="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup"
        _info "已备份现有配置到: $backup"
    fi

    # 生成默认 NTP 配置 (防 SS-2022 重放攻击 bad timestamp)
    cat > "$CONFIG_FILE" << 'SBEOF'
{
    "log": {
        "level": "warn",
        "output": "/var/log/sing-box.log",
        "timestamp": true
    },
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "30m"
    },
    "dns": {
        "servers": [
            {
                "tag": "dns-local",
                "address": "223.5.5.5",
                "detour": "direct"
            },
            {
                "tag": "dns-remote",
                "address": "8.8.8.8",
                "detour": "proxy"
            }
        ],
        "rules": [
            {
                "rule_set": ["geosite-cn", "geosite-category-companies-cn"],
                "server": "dns-local"
            }
        ],
        "final": "dns-remote",
        "strategy": "prefer_ipv4"
    },
    "route": {
        "rule_set": [
            {
                "tag": "geosite-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/SagerNet/sing-geosite/raw/refs/heads/rule-set/geosite-cn.srs"
            },
            {
                "tag": "geosite-category-companies-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/SagerNet/sing-geosite/raw/refs/heads/rule-set/geosite-category-companies-cn.srs"
            },
            {
                "tag": "geoip-cn",
                "type": "remote",
                "format": "binary",
                "url": "https://github.com/SagerNet/sing-geoip/raw/refs/heads/rule-set/geoip-cn.srs"
            }
        ],
        "rules": [
            {
                "rule_set": ["geosite-cn", "geosite-category-companies-cn"],
                "outbound": "direct"
            },
            {
                "rule_set": ["geoip-cn"],
                "outbound": "direct"
            }
        ],
        "final": "proxy"
    },
    "inbounds": [],
    "outbounds": [
        {
            "tag": "direct",
            "type": "direct"
        },
        {
            "tag": "proxy",
            "type": "selector",
            "outbounds": ["direct"]
        }
    ]
}
SBEOF

    _success "config.json 已生成"
}

# --- 写入元数据 ---
_sb_init_metadata() {
    if [ ! -f "$METADATA_FILE" ]; then
        cat > "$METADATA_FILE" << 'METAEOF'
{
    "version": "2.0.0",
    "created_at": "",
    "server_ip": "",
    "domain": "",
    "protocols": {},
    "argo": {}
}
METAEOF
    fi
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    local ip=$(_get_public_ip)
    _atomic_modify_json "$METADATA_FILE" ".version = \"2.0.0\" | .created_at = \"$now\" | .server_ip = \"${ip:-127.0.0.1}\""
}

# --- 创建 systemd/OpenRC 服务 ---
_sb_setup_service() {
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1

    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        cat > /etc/init.d/sing-box << 'SBOEPENRC'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="true"
pidfile="/run/sing-box.pid"
SBOEPENRC
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
    fi
}

# --- 重启服务并验证 ---
_sb_restart_and_verify() {
    _manage_service "restart"
    sleep 2

    if [ "$INIT_SYSTEM" == "systemd" ]; then
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            _success "sing-box 服务运行正常"
            return 0
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            _success "sing-box 服务运行正常"
            return 0
        fi
    fi

    if [ "$INIT_SYSTEM" == "openrc" ]; then
        _error "sing-box 启动失败，请检查日志: cat /var/log/sing-box.log"
    else
        _error "sing-box 启动失败，请检查日志: journalctl -u sing-box -n 30"
    fi
    return 1
}

# --- 检查 sing-box 是否已安装 ---
_sb_is_installed() {
    [ -f "$SINGBOX_BIN" ] && [ -f "$CONFIG_FILE" ]
}

_require_singbox() {
    if ! _sb_is_installed; then
        _error "sing-box 未安装，请先运行 install.sh 部署"
        return 1
    fi
    return 0
}

# --- 获取 sing-box 版本 ---
_sb_get_version() {
    if [ -f "$SINGBOX_BIN" ]; then
        "$SINGBOX_BIN" version 2>/dev/null | head -n1 | awk '{print $3}'
    else
        echo "未安装"
    fi
}

# --- 获取服务状态 ---
_sb_get_status() {
    if ! _sb_is_installed; then
        echo "${RED}○ 未安装${NC}"
        return
    fi

    if [ "$INIT_SYSTEM" == "systemd" ]; then
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            echo "${GREEN}● 运行中${NC}"
        else
            echo "${RED}○ 已停止${NC}"
        fi
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            echo "${GREEN}● 运行中${NC}"
        else
            echo "${RED}○ 已停止${NC}"
        fi
    else
        echo "${YELLOW}○ 未知${NC}"
    fi
}

# --- 获取已配置的协议 ---
_sb_get_protocols() {
    [ ! -f "$CONFIG_FILE" ] && { echo "无"; return; }
    jq -r '[.inbounds[].type] | unique | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "解析失败"
}

# --- 获取入站节点数量 ---
_sb_get_inbound_count() {
    [ ! -f "$CONFIG_FILE" ] && { echo "0"; return; }
    jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null || echo "0"
}

# --- 备份配置 ---
_sb_backup_config() {
    _require_singbox || return 1
    local backup="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup"
    _info "配置已备份到: $backup"
}

# ============================================================
# DNS 管理 — IPv6 优先 / 流媒体 DNS 解锁
# ============================================================

IPV6_DNS_STATE="${SINGBOX_DIR}/.ipv6_dns_enabled"
STREAMING_DNS_STATE="${SINGBOX_DIR}/.streaming_dns"

# --- IPv6 DNS 状态 ---
_dns_ipv6_status() {
    if [ -f "$IPV6_DNS_STATE" ]; then
        echo "${GREEN}● IPv6 优先${NC}"
    else
        echo "${YELLOW}○ IPv4 优先${NC}（默认）"
    fi
}

# --- 启用 IPv6 DNS ---
_dns_ipv6_enable() {
    local ipv6=$(timeout 3 curl -s6 ifconfig.me 2>/dev/null)
    [ -z "$ipv6" ] && { _error "本机无 IPv6 地址，无法启用"; return 1; }

    _sb_backup_config
    _atomic_modify_json "$CONFIG_FILE" '
        .dns.strategy = "prefer_ipv6" |
        (.dns.servers[] | select(.tag == "dns-local") | .address) = "2400:3200::1" |
        (.dns.servers[] | select(.tag == "dns-remote") | .address) = "2001:4860:4860::8888"
    '
    touch "$IPV6_DNS_STATE"
    _sb_restart_and_verify
    _success "IPv6 DNS 优先已启用 — 出站连接将优先使用 IPv6"
}

# --- 禁用 IPv6 DNS ---
_dns_ipv6_disable() {
    _sb_backup_config
    _atomic_modify_json "$CONFIG_FILE" '
        .dns.strategy = "prefer_ipv4" |
        (.dns.servers[] | select(.tag == "dns-local") | .address) = "223.5.5.5" |
        (.dns.servers[] | select(.tag == "dns-remote") | .address) = "8.8.8.8"
    '
    rm -f "$IPV6_DNS_STATE"
    _sb_restart_and_verify
    _success "已恢复 IPv4 DNS 优先"
}

# --- 流媒体 DNS 状态 ---
_streaming_dns_status() {
    if [ -f "$STREAMING_DNS_STATE" ]; then
        local addr=$(cat "$STREAMING_DNS_STATE")
        echo "${GREEN}● ${addr}${NC}"
    else
        echo "${YELLOW}○ 未设置${NC}"
    fi
}

# --- 设置流媒体 DNS ---
_streaming_dns_set() {
    local addr="$1"
    [ -z "$addr" ] && { _error "请提供 DNS 地址"; return 1; }
    echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || {
        _warn "地址格式不标准: $addr，继续..."
    }

    _sb_backup_config

    # 先清理旧配置（避免重复）
    if jq -e '.dns.servers[] | select(.tag == "dns-streaming")' "$CONFIG_FILE" >/dev/null 2>&1; then
        _atomic_modify_json "$CONFIG_FILE" 'del(.dns.servers[] | select(.tag == "dns-streaming"))'
    fi
    if jq -e '.dns.rules[] | select(.server == "dns-streaming")' "$CONFIG_FILE" >/dev/null 2>&1; then
        _atomic_modify_json "$CONFIG_FILE" 'del(.dns.rules[] | select(.server == "dns-streaming"))'
    fi

    # 添加新的流媒体 DNS
    _atomic_modify_json "$CONFIG_FILE" '.dns.servers += [{"tag":"dns-streaming","address":"'"$addr"'","detour":"proxy"}]'
    _atomic_modify_json "$CONFIG_FILE" '.dns.rules += [{
        "domain_suffix": [
            "netflix.com", "nflxvideo.net", "nflxext.com",
            "disneyplus.com", "disney-plus.net",
            "hbo.com", "hbomax.com", "max.com",
            "hulu.com", "hulustream.com",
            "amazon.com", "primevideo.com",
            "youtube.com", "googlevideo.com",
            "spotify.com",
            "tiktok.com", "tiktokcdn.com",
            "dazn.com", "paramountplus.com",
            "peacocktv.com", "appletv.com"
        ],
        "server": "dns-streaming"
    }]'
    echo "$addr" > "$STREAMING_DNS_STATE"
    _sb_restart_and_verify
    _success "流媒体 DNS 已设置: ${addr}"
}

# --- 移除流媒体 DNS ---
_streaming_dns_remove() {
    if ! jq -e '.dns.servers[] | select(.tag == "dns-streaming")' "$CONFIG_FILE" >/dev/null 2>&1; then
        [ -f "$STREAMING_DNS_STATE" ] && rm -f "$STREAMING_DNS_STATE"
        return 0
    fi

    _sb_backup_config
    _atomic_modify_json "$CONFIG_FILE" 'del(.dns.servers[] | select(.tag == "dns-streaming"))'
    _atomic_modify_json "$CONFIG_FILE" 'del(.dns.rules[] | select(.server == "dns-streaming"))'
    rm -f "$STREAMING_DNS_STATE"
    _sb_restart_and_verify
    _success "流媒体 DNS 已移除"
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro singbox 模块 v${SINGBOX_MOD_VERSION} ==="
    echo ""
    echo "系统: $(_get_os_info)"
    echo "Init:  ${INIT_SYSTEM:-未检测}"
    echo "核心版本: v$(_sb_get_version)"
    echo "服务状态: $(_sb_get_status)"
    echo "协议: $(_sb_get_protocols)"
    echo "节点数: $(_sb_get_inbound_count)"
fi
