#!/bin/bash
# ============================================================
# warp.sh — WARP SOCKS5 代理模块
# 使用 warp-plus 为 sing-box 提供全局 WARP 出口
# ============================================================
export WARP_MOD_VERSION="2.0.0"

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
        if ! _download "https://ghproxy.net/${base_url}/${zip_name}" "$tmp_zip"; then
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
        echo "${RED}○ 未安装${NC}"
        return
    fi

    if _warp_is_running; then
        echo "${GREEN}● 运行中${NC} (:${WARP_SOCKS_PORT})"
    else
        echo "${YELLOW}○ 已安装 (未运行)${NC}"
    fi
}

# --- 添加 WARP 到 sing-box 出站 ---
_warp_add_outbound() {
    local tag="warp-socks5"

    # 检查是否已存在
    if jq -e ".outbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" >/dev/null 2>&1; then
        _info "WARP 出站已存在于配置中"
        return 0
    fi

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

    # 添加到 proxy 选择器
    _atomic_modify_json "$CONFIG_FILE" \
        "(.outbounds[] | select(.tag == \"proxy\") | .outbounds) += [\"$tag\"]" 2>/dev/null || true

    _info "WARP 出站已添加到配置"
}

# --- 移除 WARP 出站 ---
_warp_remove_outbound() {
    local tag="warp-socks5"
    _atomic_modify_json "$CONFIG_FILE" "del(.outbounds[] | select(.tag == \"$tag\"))"
    # 从 proxy 选择器移除
    _atomic_modify_json "$CONFIG_FILE" \
        "(.outbounds[] | select(.tag == \"proxy\") | .outbounds) -= [\"$tag\"]" 2>/dev/null || true
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
