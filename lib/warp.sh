#!/bin/bash
# ============================================================
# warp.sh — WARP SOCKS5 代理模块
# 使用 warp-plus 为 sing-box 提供全局 WARP 出口
# ============================================================
export WARP_MOD_VERSION="${PROJECT_VERSION}"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

WARP_DIR="${WARP_DIR:-/usr/local/etc/warp}"
WARP_BIN="${WARP_BIN:-${WARP_DIR}/warp-plus}"
WARP_VERSION="${WARP_VERSION:-1.2.6}"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"
WARP_METADATA_FILE="${WARP_METADATA_FILE:-${SINGBOX_DIR:-/usr/local/etc/sing-box}/warp-meta.json}"

# 默认 AI 分流域名列表
_WARP_DEFAULT_DOMAINS="openai.com chat.openai.com api.openai.com claude.ai api.claude.ai anthropic.ai gemini.google.com bard.google.com copilot.microsoft.com"
_WARP_DNS_TAG="dns-warp"
_WARP_ROUTE_TAG="warp-domain-rule"

# --- 安装 warp-plus ---
_warp_install() {
    if [ -f "$WARP_BIN" ]; then
        _info "WARP 已安装"
        return 0
    fi

    _info "正在安装 warp-plus v${WARP_VERSION}..."
    mkdir -p "$WARP_DIR"

    local arch=$(_get_arch)
    local base_url="https://github.com/bepass-org/warp-plus/releases/download/v${WARP_VERSION}"
    local zip_name="warp-plus_linux-${arch}.zip"
    local tmp_zip="${WARP_DIR}/${zip_name}"

    # 下载 zip
    if ! _download "${base_url}/${zip_name}" "$tmp_zip"; then
        _warn "主源下载失败，尝试镜像..."
        if ! _download "${GH_PROXY:-https://ghproxy.net/}${base_url}/${zip_name}" "$tmp_zip"; then
            _error "warp-plus 下载失败"
            return 1
        fi
    fi

    # 解压
    if ! command -v unzip &>/dev/null; then
        _pkg_install unzip 2>/dev/null || { _error "请先安装 unzip"; rm -f "$tmp_zip"; return 1; }
    fi
    unzip -o "$tmp_zip" -d "$WARP_DIR" >/dev/null 2>&1 || { _error "解压失败"; rm -f "$tmp_zip"; return 1; }
    rm -f "$tmp_zip"

    chmod +x "$WARP_BIN"
    _success "warp-plus v${WARP_VERSION} 安装完成"
    return 0
}

# --- 启动 WARP SOCKS5 代理 ---
_warp_start() {
    if ! [ -f "$WARP_BIN" ]; then
        _error "warp-plus 未安装，请先运行安装"
        return 1
    fi

    # 检查是否已运行
    if _warp_is_running; then
        _info "WARP 已在运行"
        return 0
    fi

    _info "正在启动 WARP SOCKS5 代理 (端口 ${WARP_SOCKS_PORT})..."
    mkdir -p "$WARP_DIR"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        # 写启动 wrapper，便于 systemd 调用与重启自恢复
        cat > "${WARP_DIR}/warp-start.sh" <<EOF
#!/bin/bash
exec ${WARP_BIN} -b "127.0.0.1:${WARP_SOCKS_PORT}"
EOF
        chmod +x "${WARP_DIR}/warp-start.sh"
        cat > /etc/systemd/system/warp-plus.service <<'EOF'
[Unit]
Description=WARP Plus SOCKS5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/etc/warp/warp-start.sh
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now warp-plus >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet warp-plus 2>/dev/null || _warp_is_running; then
            _success "WARP SOCKS5 代理已启动 (127.0.0.1:${WARP_SOCKS_PORT})"
            return 0
        fi
        _error "WARP 启动失败，请查看日志: journalctl -u warp-plus"
        return 1
    fi

    # 非 systemd 回退：nohup
    nohup "$WARP_BIN" -b "127.0.0.1:${WARP_SOCKS_PORT}" \
        > "${WARP_DIR}/warp.log" 2>&1 &
    local pid=$!
    echo "$pid" > "${WARP_DIR}/warp.pid"

    sleep 2
    if _warp_is_running; then
        _success "WARP SOCKS5 代理已启动 (127.0.0.1:${WARP_SOCKS_PORT})"
        return 0
    fi

    _error "WARP 启动失败，请查看日志: ${WARP_DIR}/warp.log"
    return 1
}

# --- 停止 WARP ---
_warp_stop() {
    if [ "$INIT_SYSTEM" = "systemd" ] && systemctl cat warp-plus >/dev/null 2>&1; then
        systemctl disable --now warp-plus 2>/dev/null || true
        rm -f /etc/systemd/system/warp-plus.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    if ! _warp_is_running; then
        _info "WARP 未在运行"
        return 0
    fi

    local pid=$(cat "${WARP_DIR}/warp.pid" 2>/dev/null)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        rm -f "${WARP_DIR}/warp.pid"
    fi
    pkill -f "warp-plus" 2>/dev/null || true
    _success "WARP 已停止"
}

# --- 卸载 WARP ---
_warp_uninstall() {
    _warn "正在卸载 WARP..."

    _warp_stop 2>/dev/null || true
    _warp_remove_outbound 2>/dev/null || true
    rm -f "$WARP_BIN"
    rm -rf "$WARP_DIR"
    _success "WARP 卸载完成"
}

# --- 检查 WARP 运行状态 ---
_warp_is_running() {
    if systemctl is-active --quiet warp-plus 2>/dev/null; then
        return 0
    fi
    local pid=$(cat "${WARP_DIR}/warp.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    # 兜底：检查端口
    ss -tlnp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT} " && return 0
    return 1
}

_warp_get_status() {
    if [ ! -f "$WARP_BIN" ]; then
        echo -e "${RED}○ 未安装${NC}"
        return
    fi

    if _warp_is_running; then
        echo -e "${GREEN}● 运行中${NC} (:${WARP_SOCKS_PORT})"
    else
        echo -e "${YELLOW}○ 已安装 (未运行)${NC}"
    fi
}

# --- 初始化 WARP 元数据 ---
_warp_init_metadata() {
    [ ! -f "$WARP_METADATA_FILE" ] && cat > "$WARP_METADATA_FILE" << 'WEOF'
{
    "enabled": false,
    "domains": [],
    "custom_domains": []
}
WEOF
}

# --- 添加 WARP DNS 服务器（经过 WARP SOCKS5 的 DNS） ---
_warp_add_dns_server() {
    # 如果 warp DNS tag 已存在则跳过
    if jq -e ".dns.servers[] | select(.tag == \"$_WARP_DNS_TAG\")" "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi

    local warp_dns_json=$(jq -n \
        --arg tag "$_WARP_DNS_TAG" \
        '{
            "tag": $tag,
            "type": "https",
            "server": "https://1.1.1.1/dns-query",
            "detour": "warp-socks5"
        }')

    _atomic_modify_json "$CONFIG_FILE" ".dns.servers += [$warp_dns_json]"
}

# --- 移除 WARP DNS 服务器 ---
_warp_remove_dns_server() {
    _atomic_modify_json "$CONFIG_FILE" "del(.dns.servers[] | select(.tag == \"$_WARP_DNS_TAG\"))" 2>/dev/null || true
}

# --- 获取当前所有 WARP 分流域名（默认+自定义） ---
_warp_get_all_domains() {
    _warp_init_metadata
    local defaults=$(echo "$_WARP_DEFAULT_DOMAINS")
    local custom=$(jq -r '.custom_domains | join(" ")' "$WARP_METADATA_FILE" 2>/dev/null || echo "")
    echo "${defaults} ${custom}"
}

# --- 获取路由规则列表 ---
_warp_get_route_rules() {
    jq -r --arg tag "$_WARP_ROUTE_TAG" \
        '.route.rules[]? | select(.outbound == $tag) | .domain[]? // empty' \
        "$CONFIG_FILE" 2>/dev/null || true
}

# --- 添加单个域名到 WARP 路由规则 ---
_warp_add_domain() {
    local domain="$1"
    domain=$(echo "$domain" | sed 's/^\*\.\?//' | tr '[:upper:]' '[:lower:]' | xargs)

    [ -z "$domain" ] && return 1

    # 初始化元数据
    _warp_init_metadata

    # 检查是否已在路由规则中
    local already_added=$(jq -r --arg tag "$_WARP_ROUTE_TAG" --arg d "$domain" \
        '.route.rules[]? | select(.outbound == $tag and .domain | index($d) != null) | .domain[0] // empty' \
        "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$already_added" ]; then
        _info "域名 $domain 已在分流列表中"
        return 0
    fi

    # 仅自定义域名写入 custom_domains（默认域名不写）
    local is_default=false
    for def in $_WARP_DEFAULT_DOMAINS; do
        [ "$def" = "$domain" ] && { is_default=true; break; }
    done
    if ! $is_default; then
        _atomic_modify_json "$WARP_METADATA_FILE" ".custom_domains += [\"$domain\"]" 2>/dev/null || true
    fi

    # 添加 WARP DNS 服务器（如果没有）
    _warp_add_dns_server

    # 添加域名路由规则
    local rule_json=$(jq -n \
        --arg tag "$_WARP_ROUTE_TAG" \
        --arg d "$domain" \
        '{"outbound": $tag, "domain": [$d]}')

    _atomic_modify_json "$CONFIG_FILE" ".route.rules += [$rule_json]"

    # 同时添加 DNS 规则
    local dns_rule_json=$(jq -n \
        --arg tag "$_WARP_DNS_TAG" \
        --arg d "$domain" \
        '{"type": "domain", "server": $tag, "domain": [$d]}')

    _atomic_modify_json "$CONFIG_FILE" ".dns.rules += [$dns_rule_json]"

    _info "已添加域名到 WARP 分流: $domain"
}

# --- 移除单个自定义域名 ---
_warp_remove_domain() {
    local domain="$1"
    domain=$(echo "$domain" | sed 's/^\*\.\?//' | tr '[:upper:]' '[:lower:]' | xargs)

    [ -z "$domain" ] && return 1

    # 默认域名不允许删除
    for def in $_WARP_DEFAULT_DOMAINS; do
        if [ "$def" = "$domain" ]; then
            _warn "默认域名 $domain 不允许删除"
            return 1
        fi
    done

    # 从自定义域名列表移除
    _atomic_modify_json "$WARP_METADATA_FILE" \
        ".custom_domains -= [\"$domain\"]" 2>/dev/null || true

    # 移除对应路由规则和 DNS 规则
    _atomic_modify_json "$CONFIG_FILE" \
        ".route.rules = [.route.rules[] | select(not (.outbound == \"$_WARP_ROUTE_TAG\" and .domain == [\"$domain\"]))]" 2>/dev/null || true
    _atomic_modify_json "$CONFIG_FILE" \
        ".dns.rules = [.dns.rules[] | select(not (.server == \"$_WARP_DNS_TAG\" and .domain == [\"$domain\"]))]" 2>/dev/null || true

    _info "已从 WARP 分流移除: $domain"
}

# --- 重置所有域名到默认列表 ---
_warp_reset_domains() {
    # 清除所有自定义域名
    _atomic_modify_json "$WARP_METADATA_FILE" ".custom_domains = []" 2>/dev/null || true

    # 移除所有 warp 相关的路由规则和 DNS 规则
    _atomic_modify_json "$CONFIG_FILE" \
        ".route.rules = [.route.rules[] | select(.outbound != \"$_WARP_ROUTE_TAG\")]" 2>/dev/null || true
    _atomic_modify_json "$CONFIG_FILE" \
        ".dns.rules = [.dns.rules[] | select(.server != \"$_WARP_DNS_TAG\")]" 2>/dev/null || true

    # 重新添加默认域名
    for d in $_WARP_DEFAULT_DOMAINS; do
        _warp_add_domain "$d" >/dev/null 2>&1 || true
    done

    _info "已重置 WARP 分流域名到默认列表"
}

# --- 添加 WARP 到 sing-box 出站 + 初始化域名路由 ---
_warp_add_outbound() {
    local tag="warp-socks5"

    # 检查是否已存在
    if jq -e ".outbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then
        _info "WARP 出站已存在于配置中"
    else
        local outbound_json=$(jq -n \
            --arg tag "$tag" \
            --arg port "$WARP_SOCKS_PORT" \
            '{
                "tag": $tag,
                "type": "socks",
                "server": "127.0.0.1",
                "server_port": ($port|tonumber),
                "version": "5"
            }')

        _atomic_modify_json "$CONFIG_FILE" ".outbounds += [$outbound_json]"
    fi

    # 添加到 proxy 选择器
    _atomic_modify_json "$CONFIG_FILE" \
        "(.outbounds[] | select(.tag == \"proxy\") | .outbounds) += [\"$tag\"]" 2>/dev/null || true

    # 标记 WARP 已启用
    _warp_init_metadata
    _atomic_modify_json "$WARP_METADATA_FILE" ".enabled = true" 2>/dev/null || true

    # 初始化默认域名路由（首次启用时）
    local existing_domains=$(_warp_get_route_rules)
    if [ -z "$existing_domains" ]; then
        _info "正在配置 WARP 域名分流..."
        for d in $_WARP_DEFAULT_DOMAINS; do
            _warp_add_domain "$d" >/dev/null 2>&1 || true
        done
    fi

    _info "WARP 出站已添加到配置"
}

# --- 移除 WARP 出站 ---
_warp_remove_outbound() {
    local tag="warp-socks5"
    _atomic_modify_json "$CONFIG_FILE" "del(.outbounds[] | select(.tag == \"$tag\"))" 2>/dev/null || true
    # 从 proxy 选择器移除
    _atomic_modify_json "$CONFIG_FILE" \
        "(.outbounds[] | select(.tag == \"proxy\") | .outbounds) -= [\"$tag\"]" 2>/dev/null || true
    # 移除 WARP DNS
    _warp_remove_dns_server
    # 移除所有 warp 域名路由
    _atomic_modify_json "$CONFIG_FILE" \
        ".route.rules = [.route.rules[] | select(.outbound != \"$_WARP_ROUTE_TAG\")]" 2>/dev/null || true
    _atomic_modify_json "$CONFIG_FILE" \
        ".dns.rules = [.dns.rules[] | select(.server != \"$_WARP_DNS_TAG\")]" 2>/dev/null || true
    # 标记 WARP 已禁用
    _atomic_modify_json "$WARP_METADATA_FILE" ".enabled = false" 2>/dev/null || true
    _info "WARP 出站已从配置移除"
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro WARP 模块 v${WARP_MOD_VERSION} ==="
    echo ""
    echo "状态: $(_warp_get_status)"
    echo "端口: ${WARP_SOCKS_PORT}"
fi
