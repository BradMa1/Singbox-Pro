#!/bin/bash
# ============================================================
# argo.sh — Cloudflare Argo Tunnel 管理模块
# 支持临时隧道和固定隧道 (Token) 两种模式
# ============================================================
export ARGO_MOD_VERSION="${PROJECT_VERSION}"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
ARGO_METADATA_FILE="${ARGO_METADATA_FILE:-${SINGBOX_DIR}/argo_metadata.json}"

# --- 安装 cloudflared ---
_argo_install() {
    if [ -f "$CLOUDFLARED_BIN" ]; then
        local ver=$($CLOUDFLARED_BIN --version 2>/dev/null | head -1 || echo 'unknown')
        _info "cloudflared 已安装: ${ver}"
        local ans=""
        read -p "是否重新安装最新版本？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            _info "保持当前版本"
            return 0
        fi
        _info "正在重新下载 cloudflared..."
        rm -f "$CLOUDFLARED_BIN"
    fi

    _info "正在安装 cloudflared..."
    local arch=$(_get_arch)
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"

    if _download "$cf_url" "$CLOUDFLARED_BIN"; then
        chmod +x "$CLOUDFLARED_BIN"
        _success "cloudflared 安装完成"
        return 0
    fi

    # 镜像回退
    _warn "主源下载失败，尝试镜像..."
    local mirror_url="${GH_PROXY:-https://ghproxy.net/}${cf_url}"
    if _download "$mirror_url" "$CLOUDFLARED_BIN"; then
        chmod +x "$CLOUDFLARED_BIN"
        _success "cloudflared 安装完成 (镜像)"
        return 0
    fi

    _error "cloudflared 安装失败"
    return 1
}

# --- systemd 服务模板（只写入一次）---
# 临时隧道 与 固定隧道 各一个模板 unit，固定隧道 token 存到受保护文件，
# 重启 VPS 后由 systemd 自动拉起（Restart=always）。
_argo_ensure_service_template() {
    [ "$INIT_SYSTEM" = "systemd" ] || return 0
    # 注意: 此 unit 为脚本自动生成，不保留用户自定义内容，每次都重写以确保修复（如 origin 地址）生效
    cat > /etc/systemd/system/argo-tunnel@.service <<'EOF'
[Unit]
Description=Argo Tunnel (port %i)
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:%i
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/argo-fixed@.service <<'EOF'
[Unit]
Description=Argo Fixed Tunnel (port %i)
After=network.target sing-box.service
Wants=sing-box.service

[Service]
Type=simple
# 注意: 固定(named)隧道路由由 Cloudflare 云端控制，本地 --url 参数会被忽略
# 必须到 Dashboard 把该域名的 Public Hostname Service 设为 http://127.0.0.1:<端口>
ExecStart=/bin/sh -c '/usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$(cat /usr/local/etc/sing-box/argo/%i.token 2>/dev/null)"'
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF
}

# --- 启动临时隧道 ---
_argo_start_temp() {
    local port="$1"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        _argo_start_systemd_temp "$port"
    else
        _argo_start_nohup_temp "$port"
    fi
}

_argo_start_systemd_temp() {
    local port="$1"
    _argo_ensure_service_template
    _info "正在启动临时 Argo 隧道 (端口 ${port})..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "argo-tunnel@${port}" >/dev/null 2>&1

    local domain=""
    for i in $(seq 1 20); do
        sleep 1
        domain=$(journalctl -u "argo-tunnel@${port}" -n 60 --no-pager 2>/dev/null | grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -1)
        [ -n "$domain" ] && break
        [ "$((i % 3))" -eq 0 ] && _info "等待隧道就绪... (${i}s)"
    done

    if [ -z "$domain" ]; then
        _error "临时隧道启动失败，请查看日志: journalctl -u argo-tunnel@${port}"
        systemctl stop "argo-tunnel@${port}" 2>/dev/null || true
        return 1
    fi

    local clean_domain=$(echo "$domain" | sed 's|https://||')
    _success "临时隧道已启动: ${clean_domain}"
    echo "$clean_domain"
}

_argo_start_nohup_temp() {
    local port="$1"
    local log_file="/tmp/singbox_argo_${port}.log"
    local pid_file="/tmp/singbox_argo_${port}.pid"
    _info "正在启动临时 Argo 隧道 (端口 ${port})..."
    nohup "$CLOUDFLARED_BIN" tunnel --url "http://127.0.0.1:${port}" \
        --no-autoupdate > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    local domain=""
    for i in $(seq 1 15); do
        sleep 1
        if [ -f "$log_file" ]; then
            domain=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$log_file" | tail -1)
            [ -n "$domain" ] && break
        fi
        [ "$((i % 3))" -eq 0 ] && _info "等待隧道就绪... (${i}s)"
    done

    if [ -z "$domain" ]; then
        _error "临时隧道启动失败，请查看日志: $log_file"
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi

    local clean_domain=$(echo "$domain" | sed 's|https://||')
    _success "临时隧道已启动: ${clean_domain}"
    echo "$clean_domain"
}

# --- 启动固定隧道 (Token 模式) ---
# 注: 固定(named)隧道的 ingress 路由由 Cloudflare 云端控制，本地 config.yml 无法覆盖。
#     添加隧道后，必须在 Cloudflare Dashboard 把该域名的 Public Hostname Service 设为
#     http://127.0.0.1:<端口> (明文 http，非 https；127.0.0.1 非 localhost)，否则客户端超时。
_argo_start_fixed() {
    local port="$1" token="$2"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        _argo_start_systemd_fixed "$port" "$token"
    else
        _argo_start_nohup_fixed "$port" "$token"
    fi
}

# (固定隧道的 ingress 由 Cloudflare 云端控制，本地无法覆盖，故不在此生成 config.yml)

_argo_start_systemd_fixed() {
    local port="$1" token="$2"
    mkdir -p "${SINGBOX_DIR}/argo"
    chmod 700 "${SINGBOX_DIR}/argo"
    printf '%s' "$token" > "${SINGBOX_DIR}/argo/${port}.token"
    chmod 600 "${SINGBOX_DIR}/argo/${port}.token"
    _argo_ensure_service_template
    _info "正在启动固定 Argo 隧道 (端口 ${port})..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "argo-fixed@${port}" >/dev/null 2>&1
    sleep 3
    if systemctl is-active --quiet "argo-fixed@${port}" 2>/dev/null; then
        _success "固定隧道已启动 (端口 ${port})"
        return 0
    fi
    _error "固定隧道启动失败，请查看日志: journalctl -u argo-fixed@${port}"
    return 1
}

_argo_start_nohup_fixed() {
    local port="$1" token="$2"
    local log_file="/tmp/singbox_argo_fixed_${port}.log"
    local pid_file="/tmp/singbox_argo_fixed_${port}.pid"
    _info "正在启动固定 Argo 隧道 (端口 ${port})..."
    nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate run \
        --token "$token" > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
        _success "固定隧道已启动 (PID: ${pid})"
        return 0
    fi
    _error "固定隧道启动失败，请查看日志: $log_file"
    rm -f "$pid_file"
    return 1
}

# --- 停止隧道 ---
_argo_stop() {
    local port="$1"
    for svc in "argo-tunnel@${port}" "argo-fixed@${port}"; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            systemctl disable --now "$svc" 2>/dev/null || true
        fi
    done
    rm -f "${SINGBOX_DIR}/argo/${port}.token" 2>/dev/null || true
    # 兜底：清理残留 nohup 进程
    for pid_file in /tmp/singbox_argo_${port}.pid /tmp/singbox_argo_fixed_${port}.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done
    pkill -f "cloudflared.*:${port}" 2>/dev/null || true
}

# --- 停止所有隧道 ---
_argo_stop_all() {
    _info "正在停止所有 Argo 隧道..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        local units=$(systemctl list-units --all --type=service --full 2>/dev/null | grep -oE 'argo-(tunnel|fixed)@[0-9]+\.service' | sort -u)
        for svc in $units; do
            systemctl disable --now "$svc" 2>/dev/null || true
        done
    fi
    rm -f "${SINGBOX_DIR}/argo/"*.token 2>/dev/null || true
    for pid_file in /tmp/singbox_argo_*.pid /tmp/singbox_argo_fixed_*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file" 2>/dev/null)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    done
    pkill cloudflared 2>/dev/null || true
    _success "所有 Argo 隧道已停止"
}

# --- 获取 Argo 状态 ---
_argo_get_status() {
    if [ ! -f "$CLOUDFLARED_BIN" ]; then
        echo -e "${RED}○ 未安装${NC}"
        return
    fi

    local running=false

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        local ports=$(jq -r '[.[]?.local_port | tostring] | unique[]?' "$ARGO_METADATA_FILE" 2>/dev/null || echo "")
        for port in $ports; do
            if systemctl is-active --quiet "argo-tunnel@${port}" 2>/dev/null || \
               systemctl is-active --quiet "argo-fixed@${port}" 2>/dev/null; then
                running=true
                break
            fi
        done
    fi

    if [ "$running" = false ]; then
        # 回退：检查 /tmp pid 文件（非 systemd 或 VPS 升级前残留）
        for pid_file in /tmp/singbox_argo_*.pid /tmp/singbox_argo_fixed_*.pid; do
            [ -f "$pid_file" ] || continue
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                running=true
                break
            fi
        done
    fi

    if [ "$running" = true ]; then
        local count=$(_argo_count)
        echo -e "${GREEN}● 运行中${NC} (${count}隧道)"
    else
        echo -e "${YELLOW}○ 已安装 (未运行)${NC}"
    fi
}

# --- 查看隧道日志 ---
_argo_view_log() {
    local port="$1"

    if [ -n "$port" ]; then
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            local unit="argo-tunnel@${port}"
            systemctl cat "argo-fixed@${port}" >/dev/null 2>&1 && unit="argo-fixed@${port}"
            if systemctl cat "$unit" >/dev/null 2>&1; then
                echo "=== Argo 隧道日志 (端口 ${port}) ==="
                journalctl -u "$unit" -n 30 --no-pager
            else
                _warn "未找到端口 ${port} 的 Argo 隧道"
            fi
        else
            local log_file="/tmp/singbox_argo_${port}.log"
            [ -f "/tmp/singbox_argo_fixed_${port}.log" ] && log_file="/tmp/singbox_argo_fixed_${port}.log"
            if [ -f "$log_file" ]; then
                echo "=== Argo 隧道日志 (端口 ${port}) ==="
                tail -30 "$log_file"
            else
                _warn "未找到端口 ${port} 的隧道日志"
            fi
        fi
    else
        _warn "请指定端口查看日志（例如 sb → 2 → 查看日志）"
    fi
}

# --- Argo 元数据管理 ---
_argo_save_metadata() {
    local tag="$1" name="$2" domain="$3" port="$4"
    local credential_key="$5" credential_val="$6"
    local path="${7:-/}" protocol="$8" argo_type="$9" token="${10:-}"

    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"

    # 安全：metadata 文件默认权限 644（world-readable），token 不应明文落盘。
    # 真正启动隧道用的是 ${SINGBOX_DIR}/argo/<port>.token（600 权限），元数据里只存掩码。
    local token_disp=""
    if [ -n "$token" ]; then
        token_disp="${token:0:20}***"
    fi

    local meta=$(jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg domain "$domain" \
        --arg port "$port" \
        --arg cred_val "$credential_val" \
        --arg cred_key "$credential_key" \
        --arg path "$path" \
        --arg protocol "$protocol" \
        --arg type "$argo_type" \
        --arg token "$token_disp" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, domain: $domain, local_port: ($port|tonumber), ($cred_key): $cred_val, path: $path, protocol: $protocol, type: $type, token: $token, created_at: $created}}')

    _atomic_modify_json "$ARGO_METADATA_FILE" ". + $meta"
}

_argo_remove_metadata() {
    local tag="$1"
    [ ! -f "$ARGO_METADATA_FILE" ] && return 0
    _atomic_modify_json "$ARGO_METADATA_FILE" "del(.\"$tag\")"
}

_argo_list_nodes() {
    [ ! -f "$ARGO_METADATA_FILE" ] && { echo "无 Argo 节点"; return; }

    jq -r 'to_entries[] | "\(.value.name) | \(.value.domain) | :\(.value.local_port) | \(.value.protocol) | \(.value.type)"' \
        "$ARGO_METADATA_FILE" 2>/dev/null || echo "无 Argo 节点"
}

_argo_count() {
    [ ! -f "$ARGO_METADATA_FILE" ] && { echo "0"; return; }
    jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null || echo "0"
}

# --- Token 提取 ---
_argo_extract_token() {
    local input="$1"
    # 尝试从各种格式中提取 JWT token
    local token=$(echo "$input" | grep -oE 'ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
    [ -z "$token" ] && token=$(echo "$input" | grep -oE 'ey[A-Za-z0-9_-]{20,}' | head -1)
    [ -z "$token" ] && token="$input"
    echo "$token"
}

# --- 固定隧道 Dashboard 配置提示（_ui_argo_add_fixed / _ui_argo_temp_to_fixed 共用）---
# 固定(named)隧道的 ingress 路由由 Cloudflare 云端控制，本地 --url 参数会被忽略，
# 必须在 Dashboard 把该域名的 Public Hostname Service 设为 http://127.0.0.1:<端口>。
_argo_dashboard_hint() {
    local port="$1" domain="$2"
    _warn "╔═══════════════════════════════════════════════════════════╗"
    _warn "║  ⚠️  必读：固定隧道需要去 Dashboard 配 Service URL  ⚠️    ║"
    _warn "╚═══════════════════════════════════════════════════════════╝"
    _info "固定隧道路由由 Cloudflare 云端控制，脚本无法在本地设置"
    _warn "如果你不做下面这步，小火箭会显示'超时'，隧道永远不通！"
    echo ""
    _info "📌 Dashboard 配置步骤（一步一步来，不要漏）:"
    _info "  ${CYAN}①${NC} 浏览器打开 ${GREEN}https://one.dash.cloudflare.com/${NC}"
    _info "  ${CYAN}②${NC} 左侧 ${GREEN}Networks → Tunnels${NC}"
    _info "  ${CYAN}③${NC} 找到隧道名里含 ${YELLOW}${port}${NC} 的那个，点它"
    _info "  ${CYAN}④${NC} 切到 ${GREEN}Public Hostname${NC} 标签页"
    _info "  ${CYAN}⑤${NC} 找到域名 ${YELLOW}${domain}${NC} 那行，点右侧 ${GREEN}编辑${NC}"
    _info "  ${CYAN}⑥${NC} Service 这一栏："
    _info "      Type 改为: ${RED}HTTP${NC}"
    _info "      URL  改为: ${RED}http://127.0.0.1:${port}${NC}"
    _info "      ⚠️ http 不能写成 https！"
    _info "      ⚠️ 127.0.0.1 不能写成 localhost！"
    _info "      ⚠️ Path 必须留空（不要填任何东西，包括 */blog）"
    _info "  ${CYAN}⑦${NC} 点 ${GREEN}保存${NC}"
    echo ""
    _info "✅ 保存成功后无需重启任何东西，cloudflared 自动 reload，客户端立即可用"
    echo ""
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro Argo 隧道模块 v${ARGO_MOD_VERSION} ==="
    echo ""
    echo "状态: $(_argo_get_status)"
    echo "节点数: $(_argo_count)"
    echo ""
    _argo_list_nodes 2>/dev/null | while IFS='|' read -r line; do
        [ -n "$line" ] && echo "  $line"
    done
fi
