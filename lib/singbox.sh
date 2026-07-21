#!/bin/bash
# ============================================================
# singbox.sh — Sing-box 核心安装/配置/服务管理模块
# 可被 sb.sh source 加载，也可独立运行
# ============================================================
export SINGBOX_MOD_VERSION="2.0.2"

# --- 路径定义 ---
SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CONFIG_FILE="${CONFIG_FILE:-${SINGBOX_DIR}/config.json}"
METADATA_FILE="${METADATA_FILE:-${SINGBOX_DIR}/metadata.json}"
# SB_VERSION 从 core.sh 获取（SSOT），独立运行也可通过下方 source 获得

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
    local version="${1:-${SB_VERSION:-1.13.14}}"
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
        local mirror_url="${GH_PROXY:-https://ghproxy.net/}https://github.com/SagerNet/sing-box/releases/download/v${version}/${pkg_name}.tar.gz"
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
    local ver="${SCRIPT_VERSION:-2.0.2}"
    if [ ! -f "$METADATA_FILE" ]; then
        jq -n --arg v "$ver" '{
            version: $v,
            created_at: "",
            server_ip: "",
            domain: "",
            protocols: {},
            argo: {}
        }' > "$METADATA_FILE"
    fi
    local now=$(date '+%Y-%m-%d %H:%M:%S')
    local ip=$(_get_public_ip)
    _atomic_modify_json "$METADATA_FILE" ".version = \"$ver\" | .created_at = \"$now\" | .server_ip = \"${ip:-127.0.0.1}\""
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

# --- nohup 方式管理服务（无 systemd / openrc 的容器环境）---
_sb_manage_nohup() {
    local action="$1"
    local pid_file="/run/sing-box.pid"
    local log_file="/var/log/sing-box.log"

    case "$action" in
        start|restart)
            # 先停掉已有进程（按 pid 文件 + 进程名兜底）
            if [ -f "$pid_file" ]; then
                local old_pid
                old_pid=$(cat "$pid_file" 2>/dev/null)
                [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null || true
                rm -f "$pid_file"
            fi
            pkill -f "${SINGBOX_BIN} run -c ${CONFIG_FILE}" 2>/dev/null || true
            sleep 1
            nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >"$log_file" 2>&1 &
            echo $! > "$pid_file"
            _info "sing-box 已通过 nohup 启动 (PID $(cat "$pid_file" 2>/dev/null))"
            ;;
        stop)
            if [ -f "$pid_file" ]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null)
                [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
                rm -f "$pid_file"
            fi
            pkill -f "${SINGBOX_BIN} run -c ${CONFIG_FILE}" 2>/dev/null || true
            _info "sing-box 已停止"
            ;;
        status)
            if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
                echo "sing-box 运行中 (nohup, PID $(cat "$pid_file"))"
            else
                echo "sing-box 已停止"
            fi
            ;;
    esac
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
        _error "sing-box 启动失败，请检查日志: journalctl -u sing-box -n 30"
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if rc-service sing-box status 2>/dev/null | grep -q "started"; then
            _success "sing-box 服务运行正常"
            return 0
        fi
        _error "sing-box 启动失败，请检查日志: cat /var/log/sing-box.log"
    else
        # nohup 模式：检查进程是否存活
        local pid_file="/run/sing-box.pid"
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
            _success "sing-box 服务运行正常 (nohup, PID $(cat "$pid_file"))"
            return 0
        fi
        _error "sing-box 启动失败，请检查日志: cat /var/log/sing-box.log"
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
        local pid_file="/run/sing-box.pid"
        if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
            echo "${GREEN}● 运行中 (nohup)${NC}"
        else
            echo "${RED}○ 已停止${NC}"
        fi
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
# 脚本升级
# ============================================================

_sb_upgrade_scripts() {
    echo -e "${CYAN}=== 升级管理脚本 ===${NC}"
    echo ""

    local repo="https://raw.githubusercontent.com/BradMa1/Singbox-Pro/main"
    local mirror="${GH_PROXY:-https://ghproxy.net/}${repo}"
    local lib_dir="$(dirname "$(readlink -f "$0")")/lib"

    # 先检测最新版本号
    _info "正在检查最新版本..."
    local remote_ver
    remote_ver=$(curl -fsSL --connect-timeout 10 "${repo}/install.sh" 2>/dev/null | grep -oP 'SCRIPT_VERSION="\K[^"]+' || echo "")
    if [ -z "$remote_ver" ]; then
        _warn "主源检查失败，尝试镜像..."
        remote_ver=$(curl -fsSL --connect-timeout 10 "${mirror}" 2>/dev/null | grep -oP 'SCRIPT_VERSION="\K[^"]+' || echo "")
    fi

    [ -z "$remote_ver" ] && { _error "无法检测最新版本，请检查网络"; read -p "按回车键返回..."; return 1; }

    echo -e "  当前版本: ${SCRIPT_VERSION:-2.0.0}"
    echo -e "  最新版本: ${remote_ver}"
    echo ""

    # 备份
    local backup_dir="${lib_dir}/../.backup.$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    local files_to_upgrade=(
        "sb.sh|${repo}/sb.sh"
        "lib/core.sh|${repo}/lib/core.sh"
        "lib/singbox.sh|${repo}/lib/singbox.sh"
        "lib/protocols.sh|${repo}/lib/protocols.sh"
        "lib/argo.sh|${repo}/lib/argo.sh"
        "lib/warp.sh|${repo}/lib/warp.sh"
        "lib/relay.sh|${repo}/lib/relay.sh"
        "lib/ui.sh|${repo}/lib/ui.sh"
    )

    local success=0 fail=0
    for entry in "${files_to_upgrade[@]}"; do
        local fname="${entry%%|*}"
        local furl="${entry##*|}"
        local target

        if [ "$fname" = "sb.sh" ]; then
            target="$(dirname "$(readlink -f "$0")")/../sb.sh"
        else
            target="${lib_dir}/${fname#lib/}"
        fi
        target="$(readlink -f "$target")"

        # 备份
        [ -f "$target" ] && cp "$target" "${backup_dir}/"

        # 下载
        if curl -fsSL --connect-timeout 15 --max-time 60 "$furl" -o "$target" 2>/dev/null; then
            [ -x "$target" ] || chmod +x "$target"
            echo -e "  ${GREEN}✓${NC} ${fname}"
            ((success++))
        else
            # 镜像回退
            local fmirror="${furl/${repo}/${mirror}}"
            if curl -fsSL --connect-timeout 15 --max-time 60 "$fmirror" -o "$target" 2>/dev/null; then
                [ -x "$target" ] || chmod +x "$target"
                echo -e "  ${GREEN}✓${NC} ${fname} (镜像)"
                ((success++))
            else
                # 恢复备份
                [ -f "${backup_dir}/${fname##*/}" ] && cp "${backup_dir}/${fname##*/}" "$target"
                echo -e "  ${RED}✗${NC} ${fname}"
                ((fail++))
            fi
        fi
    done

    echo ""
    if [ "$fail" -eq 0 ]; then
        _success "所有 ${success} 个文件升级成功！"
        _info "备份文件: ${backup_dir}"
        if [ "$success" -gt 0 ] && [ "$fail" -eq 0 ]; then
            echo -e "  ${YELLOW}建议执行 sb restart 重启服务使变更生效${NC}"
        fi
    else
        _warn "${success} 成功，${fail} 失败"
        _info "备份文件: ${backup_dir}"
    fi

    read -p "按回车键返回..."
}

# ============================================================
# 深度健康检查
# ============================================================

_sb_health_check() {
    local exit_code=0

    _include_status() {
        local label="$1" status="$2"
        if [ "$status" = "ok" ]; then
            echo -e "  ${GREEN}✓${NC} ${label}"
        elif [ "$status" = "warn" ]; then
            echo -e "  ${YELLOW}○${NC} ${label}"
            exit_code=1
        else
            echo -e "  ${RED}✗${NC} ${label}"
            exit_code=1
        fi
    }

    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}       Singbox-Pro 深度健康检查${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo ""

    # 1. 核心依赖
    echo -e "${BLUE}── 核心依赖 ──${NC}"
    for cmd in jq curl openssl; do
        if command -v "$cmd" &>/dev/null; then
            local ver=$("$cmd" --version 2>/dev/null | head -1)
            _include_status "$cmd ($ver)" "ok"
        else
            _include_status "$cmd (未安装)" "fail"
        fi
    done
    echo ""

    # 2. sing-box 二进制
    echo -e "${BLUE}── sing-box ──${NC}"
    if [ -f "$SINGBOX_BIN" ]; then
        local sv=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $3}')
        _include_status "二进制文件 ($SINGBOX_BIN v$sv)" "ok"

        # 检查配置有效性
        if "$SINGBOX_BIN" check -c "$CONFIG_FILE" &>/dev/null; then
            _include_status "配置文件 (config.json 语法正确)" "ok"
        else
            _include_status "配置文件 (config.json 语法错误)" "fail"
        fi

        # 进程状态
        if _sb_is_installed; then
            local status_text=$(_sb_get_status)
            if echo "$status_text" | grep -q "运行中"; then
                _include_status "服务状态 (运行中)" "ok"
            else
                _include_status "服务状态 (已停止)" "fail"
            fi
        fi
    else
        _include_status "二进制文件 (未安装)" "fail"
    fi
    echo ""

    # 3. 端口监听
    echo -e "${BLUE}── 端口监听 ──${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        local inbound_count=$(jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$inbound_count" -eq 0 ]; then
            _include_status "入站节点 (0 个，无节点在监听)" "warn"
        else
            echo "  共 ${inbound_count} 个节点:"
            jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null | while IFS= read -r node; do
                local ntype=$(echo "$node" | jq -r '.type')
                local nport=$(echo "$node" | jq -r '.listen_port')
                if _verify_port_listen "$nport" "${ntype}"; then
                    echo -e "    ${GREEN}✓${NC} ${ntype}:${nport} (监听正常)"
                else
                    echo -e "    ${RED}✗${NC} ${ntype}:${nport} (端口未监听)"
                fi
            done 2>/dev/null || true
        fi
    fi
    echo ""

    # 4. DNS 解析
    echo -e "${BLUE}── DNS 解析 ──${NC}"
    if command -v nslookup &>/dev/null || command -v dig &>/dev/null || command -v host &>/dev/null; then
        local dns_ok="ok"
        local domain_ip=""
        for domain in "google.com" "baidu.com"; do
            domain_ip=$(_dns_resolve "$domain" 2>/dev/null || true)
            if [ -n "$domain_ip" ]; then
                echo -e "    ${GREEN}✓${NC} ${domain} (${domain_ip})"
            else
                echo -e "    ${YELLOW}○${NC} ${domain} (解析超时/失败)"
                dns_ok="warn"
            fi
        done
        if [ "$dns_ok" = "ok" ]; then
            _include_status "DNS 整体状况" "ok"
        else
            _include_status "DNS 整体状况 (部分异常)" "warn"
        fi
    else
        _include_status "DNS 工具 (未安装 nslookup/dig/host)" "warn"
    fi
    echo ""

    # 5. 系统资源
    echo -e "${BLUE}── 系统资源 ──${NC}"
    local mem_total mem_used
    if [ -f /proc/meminfo ]; then
        mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        mem_used=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        mem_used=$(( (mem_total - mem_used) / 1024 ))
        mem_total=$(( mem_total / 1024 ))
        echo -e "    内存: ${mem_used}M / ${mem_total}M"
        if [ "$mem_used" -gt "$((mem_total * 9 / 10))" ]; then
            _include_status "内存使用 (${mem_used}M / ${mem_total}M, 超过 90%)" "warn"
        else
            _include_status "内存使用 (${mem_used}M / ${mem_total}M)" "ok"
        fi
    fi

    local disk_usage
    disk_usage=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo 0)
    echo -e "    磁盘: ${disk_usage}%"
    if [ "$disk_usage" -gt 90 ]; then
        _include_status "磁盘使用 (${disk_usage}%, 超过 90%)" "warn"
    elif [ "$disk_usage" -gt 80 ]; then
        _include_status "磁盘使用 (${disk_usage}%)" "ok"
    else
        _include_status "磁盘使用率 (${disk_usage}%)" "ok"
    fi

    local uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local uptime_days=$((uptime_secs / 86400))
    echo -e "    运行时间: ${uptime_days} 天"
    echo ""

    # 6. 扩展服务
    echo -e "${BLUE}── 扩展服务 ──${NC}"

    # Argo
    local argo_status=$(_argo_get_status 2>/dev/null || echo "未知")
    if echo "$argo_status" | grep -q "运行中"; then
        _include_status "Argo 隧道 ($argo_status)" "ok"
    elif echo "$argo_status" | grep -q "未安装"; then
        _include_status "Argo (未安装)" "warn"
    else
        _include_status "Argo ($argo_status)" "warn"
    fi

    # WARP
    local warp_status=$(_warp_get_status 2>/dev/null || echo "未知")
    if echo "$warp_status" | grep -q "运行中"; then
        _include_status "WARP ($warp_status)" "ok"
    elif echo "$warp_status" | grep -q "未安装"; then
        _include_status "WARP (未安装)" "ok"
    else
        _include_status "WARP ($warp_status)" "warn"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  ${GREEN}✓ 所有检查通过，系统运行正常${NC}"
    else
        echo -e "  ${YELLOW}○ 部分检查未通过，请参考以上标记处理${NC}"
    fi
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo ""

    return $exit_code
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
