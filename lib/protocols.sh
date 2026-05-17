#!/bin/bash
# ============================================================
# protocols.sh — Singbox-Pro 5协议处理模块
# VLESS Reality / AnyTLS / TUIC V5 / Hysteria2 / VMess WebSocket
# ============================================================
export PROTO_MOD_VERSION="2.0.0"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

# --- 默认配置 ---
DEFAULT_SNI="${DEFAULT_SNI:-www.amd.com}"
DEFAULT_ALPN="${DEFAULT_ALPN:-h2,http/1.1}"

# ============================================================
# 1. VLESS Reality
# ============================================================

_proto_reality_config() {
    local port="$1" uuid="$2" sni="${3:-$DEFAULT_SNI}"
    local short_id="${4:-}"
    local flow="${5:-xtls-rprx-vision}"
    local server_ip="$6"

    [ -z "$short_id" ] && short_id=$(openssl rand -hex 8 2>/dev/null || _random_hex 8)
    [ -z "$server_ip" ] && server_ip=$(_get_public_ip)

    local keypair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)
    local private_key=$(echo "$keypair" | grep "PrivateKey:" | awk '{print $2}')
    _REALITY_PUBKEY=$(echo "$keypair" | grep "PublicKey:" | awk '{print $2}')
    [ -z "$private_key" ] && { private_key=$("$SINGBOX_BIN" generate rand --hex 32 2>/dev/null); _REALITY_PUBKEY=""; }

    cat << EOF
{
    "type": "vless",
    "tag": "vless-reality-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        {
            "uuid": "${uuid}",
            "flow": "${flow}"
        }
    ],
    "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
            "enabled": true,
            "handshake": {
                "server": "${sni}",
                "server_port": 443
            },
            "private_key": "${private_key}",
            "short_id": ["${short_id}"]
        }
    }
}
EOF
}

_proto_reality_uri() {
    local uuid="$1" server_ip="$2" port="$3" sni="${4:-$DEFAULT_SNI}"
    local short_id="$5" name="$6" flow="${7:-xtls-rprx-vision}"
    local ep=$(_url_encode "$name")

    local pbk="$8"
    [ -z "$pbk" ] && {
        # 回退: 从 config.json 提取私钥后推算公钥不可行，尝试元数据
        # 实际不应走到这里 — 新节点必定传 pbk
        pbk=""
    }
    local fp="chrome"

    echo -n "vless://${uuid}@${server_ip}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${short_id}#${ep}"
}

# ============================================================
# 2. AnyTLS
# ============================================================

_proto_anytls_config() {
    local port="$1" password="$2"

    cat << EOF
{
    "type": "anytls",
    "tag": "anytls-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        {
            "password": "${password}"
        }
    ],
    "tls": {
        "enabled": true,
        "certificate_path": "${SINGBOX_DIR}/cert.pem",
        "key_path": "${SINGBOX_DIR}/key.pem"
    }
}
EOF
}

_proto_anytls_uri() {
    local password="$1" server_ip="$2" port="$3" name="$4"
    local ep=$(_url_encode "$name")
    echo -n "anytls://${password}@${server_ip}:${port}?insecure=1#${ep}"
}

# ============================================================
# 3. TUIC V5
# ============================================================

_proto_tuic_config() {
    local port="$1" uuid="$2" password="$3"

    cat << EOF
{
    "type": "tuic",
    "tag": "tuic-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        {
            "uuid": "${uuid}",
            "password": "${password}"
        }
    ],
    "congestion_control": "bbr",
    "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${SINGBOX_DIR}/cert.pem",
        "key_path": "${SINGBOX_DIR}/key.pem"
    }
}
EOF
}

_proto_tuic_uri() {
    local uuid="$1" password="$2" server_ip="$3" port="$4" name="$5"
    local ep=$(_url_encode "$name")
    echo -n "tuic://${uuid}:${password}@${server_ip}:${port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${ep}"
}

# ============================================================
# 4. Hysteria2
# ============================================================

_proto_hy2_config() {
    local port="$1" password="$2"

    cat << EOF
{
    "type": "hysteria2",
    "tag": "hysteria2-${port}",
    "listen": "::",
    "listen_port": ${port},
    "up_mbps": 1000,
    "down_mbps": 1000,
    "users": [
        {
            "password": "${password}"
        }
    ],
    "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${SINGBOX_DIR}/cert.pem",
        "key_path": "${SINGBOX_DIR}/key.pem"
    }
}
EOF
}

_proto_hy2_uri() {
    local password="$1" server_ip="$2" port="$3" name="$4"

    # 如果有域名则用域名
    local host="$server_ip"
    if [ -n "${SERVER_DOMAIN:-}" ]; then
        host="$SERVER_DOMAIN"
    fi

    local ep=$(_url_encode "$name")
    echo -n "hysteria2://${password}@${host}:${port}/?insecure=1#${ep}"
}

# ============================================================
# 5. VMess WebSocket
# ============================================================

_proto_vmess_ws_config() {
    local port="$1" uuid="$2" ws_path="${3:-/ws}"

    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"

    cat << EOF
{
    "type": "vmess",
    "tag": "vmess-ws-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        {
            "uuid": "${uuid}",
            "alterId": 0
        }
    ],
    "transport": {
        "type": "ws",
        "path": "${ws_path}",
        "headers": {},
        "early_data_header_name": "Sec-WebSocket-Protocol"
    }
}
EOF
}

_proto_vmess_ws_uri() {
    local uuid="$1" server_ip="$2" port="$3" ws_path="${4:-/ws}"
    local name="$5"
    local ep=$(_url_encode "$name")

    # VMess 分享格式: vmess://base64(json)
    local vmess_json=$(jq -n \
        --arg v "2" \
        --arg ps "$name" \
        --arg add "$server_ip" \
        --arg port "$port" \
        --arg id "$uuid" \
        --arg path "$ws_path" \
        --arg net "ws" \
        --arg type "none" \
        --arg host "" \
        --arg tls "" \
        '{
            v: $v,
            ps: $ps,
            add: $add,
            port: $port,
            id: $id,
            aid: "0",
            scy: "auto",
            net: $net,
            type: $type,
            host: $host,
            path: $path,
            tls: $tls,
            sni: "",
            alpn: ""
        }')

    local b64=$(echo -n "$vmess_json" | base64 | tr -d '\n\r ')
    echo -n "vmess://${b64}"
}

# ============================================================
# 证书管理 (TLS 协议共用)
# ============================================================

_proto_generate_cert() {
    local cert_dir="$SINGBOX_DIR"

    if [ -f "${cert_dir}/cert.pem" ] && [ -f "${cert_dir}/key.pem" ]; then
        _info "TLS 证书已存在，跳过生成"
        return 0
    fi

    _info "正在生成自签名 TLS 证书..."
    openssl req -x509 -newkey rsa:2048 -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/cert.pem" -days 3650 -nodes \
        -subj "/CN=sing-box-pro" 2>/dev/null

    if [ -f "${cert_dir}/cert.pem" ] && [ -f "${cert_dir}/key.pem" ]; then
        _success "TLS 证书已生成"
        return 0
    fi

    _error "证书生成失败，请检查 openssl 是否安装"
    return 1
}

# ============================================================
# 添加入站到配置
# ============================================================

_proto_add_inbound() {
    local inbound_json="$1"

    if ! _atomic_modify_json "$CONFIG_FILE" ".inbounds += [${inbound_json}]"; then
        _error "添加入站配置失败"
        return 1
    fi

    # 同步 outbounds: proxy selector 加入新节点
    _proto_sync_outbounds
    return 0
}

# ============================================================
# 删除入站
# ============================================================

_proto_remove_inbound() {
    local tag="$1"

    if ! _atomic_modify_json "$CONFIG_FILE" "del(.inbounds[] | select(.tag == \"$tag\"))"; then
        _error "删除入站失败: $tag"
        return 1
    fi
    _info "已删除入站: $tag"

    # 同步 outbounds: proxy selector 移除该节点
    _proto_sync_outbounds
    return 0
}

# ============================================================
# 同步 outbounds — 根据当前 inbounds 更新 proxy selector
# ============================================================

_proto_sync_outbounds() {
    # 构建 proxy selector outbounds 列表
    # 注意: selector 只能引用 outbound tag，不能引用 inbound tag
    # VPS 服务端场景下，selector 只需 direct + 可选 warp
    local outbounds='["direct"]'

    if jq -e '.outbounds[] | select(.tag == "warp-socks5")' "$CONFIG_FILE" >/dev/null 2>&1; then
        outbounds='["direct","warp-socks5"]'
    fi

    _atomic_modify_json "$CONFIG_FILE" \
        "(.outbounds[] | select(.tag == \"proxy\") | .outbounds) = ${outbounds}" 2>/dev/null || true
}

# ============================================================
# 获取节点 URI
# ============================================================

_proto_get_uri() {
    local server_ip="${1:-$(_get_public_ip)}"
    local port="$2" proto="$3" name="$4"
    shift 4 2>/dev/null || true

    case "$proto" in
        reality)
            local uuid="$1" sni="${2:-$DEFAULT_SNI}" short_id="$3" flow="${4:-xtls-rprx-vision}" pbk="${5:-}"
            _proto_reality_uri "$uuid" "$server_ip" "$port" "$sni" "$short_id" "$name" "$flow" "$pbk"
            ;;
        anytls)
            local password="$1"
            _proto_anytls_uri "$password" "$server_ip" "$port" "$name"
            ;;
        tuic)
            local uuid="$1" password="$2"
            _proto_tuic_uri "$uuid" "$password" "$server_ip" "$port" "$name"
            ;;
        hysteria2)
            local password="$1"
            _proto_hy2_uri "$password" "$server_ip" "$port" "$name"
            ;;
        vmess-ws)
            local uuid="$1" ws_path="${2:-/ws}"
            _proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name"
            ;;
        *)
            _error "不支持的协议: $proto"
            return 1
            ;;
    esac
}

# ============================================================
# 参数提取 (从 config.json 中读取已配置节点参数)
# ============================================================

_proto_list_inbounds() {
    [ ! -f "$CONFIG_FILE" ] && return 1

    jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null
}

_proto_get_inbound_detail() {
    local tag="$1"
    [ ! -f "$CONFIG_FILE" ] && return 1

    jq -c ".inbounds[] | select(.tag == \"$tag\")" "$CONFIG_FILE" 2>/dev/null
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro protocols 模块 v${PROTO_MOD_VERSION} ==="
    echo ""
    echo "支持的协议:"
    echo "  1. VLESS Reality  (TLS + reality)"
    echo "  2. AnyTLS"
    echo "  3. TUIC V5         (UDP + BBR)"
    echo "  4. Hysteria2       (QUIC)"
    echo "  5. VMess WebSocket (WS)"
    echo ""
    if _sb_is_installed 2>/dev/null; then
        echo "已配置的入站:"
        _proto_list_inbounds | while read -r line; do
            local tag=$(echo "$line" | jq -r .tag)
            local type=$(echo "$line" | jq -r .type)
            local port=$(echo "$line" | jq -r .listen_port)
            echo "  ${type}  :${port}  ($tag)"
        done
    fi
fi
