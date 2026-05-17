#!/bin/bash
# ============================================================
# argo.sh — Cloudflare Argo Tunnel 管理模块
# 支持临时隧道和固定隧道 (Token) 两种模式
# ============================================================
export ARGO_MOD_VERSION="2.0.0"

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
        _info "cloudflared 已安装: $($CLOUDFLARED_BIN --version 2>/dev/null | head -1 || echo 'unknown')"
        return 0
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
    local mirror_url="https://ghproxy.net/${cf_url}"
    if _download "$mirror_url" "$CLOUDFLARED_BIN"; then
        chmod +x "$CLOUDFLARED_BIN"
        _success "cloudflared 安装完成 (镜像)"
        return 0
    fi

    _error "cloudflared 安装失败"
    return 1
}

# --- 启动临时隧道 ---
_argo_start_temp() {
    local port="$1" protocol="${2:-tcp}"
    local log_file="/tmp/singbox_argo_${port}.log"
    local pid_file="/tmp/singbox_argo_${port}.pid"

    _info "正在启动临时 Argo 隧道 (端口 ${port})..."

    nohup "$CLOUDFLARED_BIN" tunnel --url "http://localhost:${port}" \
        --no-autoupdate > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    # 等待隧道域名出现
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
_argo_start_fixed() {
    local port="$1" token="$2"
    local log_file="/tmp/singbox_argo_fixed_${port}.log"
    local pid_file="/tmp/singbox_argo_fixed_${port}.pid"

    _info "正在启动固定 Argo 隧道 (端口 ${port})..."

    nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate run \
        --token "$token" \
        --url "http://localhost:${port}" > "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"

    sleep 3

    if ! kill -0 "$pid" 2>/dev/null; then
        _error "固定隧道启动失败，请查看日志: $log_file"
        _error "请确认已在 Cloudflare Dashboard 配置 Public Hostname → http://localhost:${port}"
        rm -f "$pid_file"
        return 1
    fi

    _success "固定隧道已启动 (PID: ${pid})"
    return 0
}

# --- 停止隧道 ---
_argo_stop() {
    local port="$1"

    for pid_file in /tmp/singbox_argo_${port}.pid /tmp/singbox_argo_fixed_${port}.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                _info "已停止 Argo 隧道 (端口 ${port}, PID ${pid})"
            fi
            rm -f "$pid_file"
        fi
    done

    # 兜底：清理可能的残留进程
    pkill -f "cloudflared.*localhost:${port}" 2>/dev/null || true
}

# --- 停止所有隧道 ---
_argo_stop_all() {
    _info "正在停止所有 Argo 隧道..."
    for pid_file in /tmp/singbox_argo_*.pid /tmp/singbox_argo_fixed_*.pid; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
            rm -f "$pid_file"
        fi
    done
    pkill cloudflared 2>/dev/null || true
    _success "所有 Argo 隧道已停止"
}

# --- 获取 Argo 状态 ---
_argo_get_status() {
    if [ ! -f "$CLOUDFLARED_BIN" ]; then
        echo "${RED}○ 未安装${NC}"
        return
    fi

    local running=false
    for pid_file in /tmp/singbox_argo_*.pid /tmp/singbox_argo_fixed_*.pid; do
        [ -f "$pid_file" ] || continue
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            running=true
            break
        fi
    done

    if [ "$running" = true ]; then
        # 只统计进程实际存活的 PID 文件数量
        local count=0
        for pid_file in /tmp/singbox_argo_*.pid /tmp/singbox_argo_fixed_*.pid; do
            [ -f "$pid_file" ] || continue
            local pid=$(cat "$pid_file" 2>/dev/null)
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ((count++))
        done
        echo "${GREEN}● 运行中${NC} (${count}隧道)"
    else
        echo "${YELLOW}○ 已安装 (未运行)${NC}"
    fi
}

# --- 查看隧道日志 ---
_argo_view_log() {
    local port="$1"

    if [ -n "$port" ]; then
        local log_file="/tmp/singbox_argo_${port}.log"
        [ -f "/tmp/singbox_argo_fixed_${port}.log" ] && log_file="/tmp/singbox_argo_fixed_${port}.log"

        if [ -f "$log_file" ]; then
            echo "=== Argo 隧道日志 (端口 ${port}) ==="
            tail -30 "$log_file"
        else
            _warn "未找到端口 ${port} 的隧道日志"
        fi
    else
        # 显示最新日志
        local latest_log=$(ls -t /tmp/singbox_argo_*.log /tmp/singbox_argo_fixed_*.log 2>/dev/null | head -1)
        if [ -f "$latest_log" ]; then
            echo "=== Argo 隧道日志 (最新) ==="
            tail -30 "$latest_log"
        else
            _warn "未找到隧道日志"
        fi
    fi
}

# --- Argo 元数据管理 ---
_argo_save_metadata() {
    local tag="$1" name="$2" domain="$3" port="$4"
    local credential_key="$5" credential_val="$6"
    local path="${7:-/}" protocol="$8" argo_type="$9" token="${10:-}"

    [ ! -f "$ARGO_METADATA_FILE" ] && echo '{}' > "$ARGO_METADATA_FILE"

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
        --arg token "$token" \
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
