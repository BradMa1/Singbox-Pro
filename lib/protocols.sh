#!/bin/bash
# ============================================================
# protocols.sh — Singbox-Pro 协议处理模块
# VLESS Reality / AnyTLS / TUIC V5 / Hysteria2 / VMess WebSocket
# + Trojan / Shadowsocks 2022 / SOCKS5
# ============================================================
export PROTO_MOD_VERSION="${PROJECT_VERSION}"

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
    local public_key=$(echo "$keypair" | grep "PublicKey:" | awk '{print $2}')
    [ -z "$private_key" ] && { private_key=$("$SINGBOX_BIN" generate rand --hex 32 2>/dev/null); public_key=""; }

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
    # 公钥跟在 JSON 后输出，调用方需解析
    echo "REALITY_PBK=${public_key}"
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

# VLESS over WebSocket + TLS 链接 (sing-box 1.11+ 原生支持, 替代已移除的 VMess)
# 与 Reality 不同: 用普通 TLS (证书 SAN 需含公网 IP, _proto_generate_cert 已处理),
# 不需要 pbk/sid。客户端 (v2rayN sing-box 核心) 信任证书或开跳过证书验证即可。
_proto_vless_ws_uri() {
    local uuid="$1" server_ip="$2" port="$3" sni="${4:-$server_ip}"
    local ws_path="${5:-/ws}" name="$6"
    local ep=$(_url_encode "$name")
    local penc=$(_url_encode "$ws_path")
    # 进阶(真实证书): host/sni 用域名且去掉 insecure; 默认(自签): IP + insecure=1
    local host="$server_ip" insecure=""
    if _real_cert_ready; then
        host="$SERVER_DOMAIN"
        sni="$SERVER_DOMAIN"
    else
        insecure="&insecure=1"
    fi
    echo -n "vless://${uuid}@${host}:${port}?type=ws&security=tls&sni=${sni}&fp=chrome&path=${penc}${insecure}#${ep}"
}

# 从 reality 私钥推导公钥 (X25519)。
# 用途: 节点分享 fallback — 当 metadata.json 的 key 与 config tag 因外部改端口等原因
# 不一致、导致按 tag 查不到 public_key 时, 直接从 config 的 reality inbound 私钥推导,
# 避免生成的 vless:// 链接 pbk 为空 (v2rayN 导入后 Reality 握手失败 / 跳过测试)。
# 依赖 python3 + cryptography; 不可用时返回空并告警 (不阻断其他节点)。
_reality_pubkey_from_config() {
    local priv="$1"
    [ -z "$priv" ] && return 1
    command -v python3 >/dev/null 2>&1 || { _warn "python3 不可用, 无法推导 reality 公钥"; return 1; }
    local pub
    pub=$(python3 - "$priv" <<'PYEOF' 2>/dev/null
import base64, sys
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
priv = sys.argv[1]
pad = (-len(priv)) % 4
k = base64.urlsafe_b64decode(priv + '=' * pad)
pk = X25519PrivateKey.from_private_bytes(k)
raw = pk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
print(base64.urlsafe_b64encode(raw).decode().rstrip('='))
PYEOF
)
    [ -n "$pub" ] && echo "$pub"
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
    # 进阶(真实证书): host 改用域名且不再跳过验证; 默认(自签): IP + insecure=1
    local host="$server_ip" qs=""
    if _real_cert_ready; then
        host="$SERVER_DOMAIN"
    else
        qs="?insecure=1"
    fi
    echo -n "anytls://${password}@${host}:${port}${qs}#${ep}"
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
    # 进阶(真实证书): host 用域名且去掉 allow_insecure; 默认(自签): IP + allow_insecure=1
    local host="$server_ip" extra=""
    if _real_cert_ready; then
        host="$SERVER_DOMAIN"
    else
        extra="&allow_insecure=1"
    fi
    echo -n "tuic://${uuid}:${password}@${host}:${port}?version=5&congestion_control=bbr&udp_relay_mode=native&alpn=h3${extra}#${ep}"
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

    # 进阶(真实证书): host 用域名且去掉 insecure; 默认(自签): IP + insecure=1
    local host="$server_ip" insecure=""
    if _real_cert_ready; then
        host="$SERVER_DOMAIN"
    else
        insecure="?insecure=1"
    fi

    local ep=$(_url_encode "$name")
    echo -n "hysteria2://${password}@${host}:${port}/${insecure}#${ep}"
}

# ============================================================
# 5. Trojan (TLS, 真证书 HTTPS 外形, 路径放行)
# ============================================================
# Trojan 流量长得跟正常 HTTPS 一模一样, 不像 ws 会被 L7 按特征拦截;
# 与 VLESS-Reality 互补: reality 靠伪造 TLS 握手, trojan 靠真证书伪装真实网站。
# 证书: 优先用 acme 真实证书 (cert.sh 签发), 回退自签 (SAN 已含公网 IP)。
# 注意: Trojan 服务端 inbound 必须配 TLS; 自签场景客户端需 allowInsecure=1。

_proto_trojan_config() {
    local port="$1" password="$2"
    local cert_path="${3:-${SINGBOX_DIR}/cert.pem}"
    local key_path="${4:-${SINGBOX_DIR}/key.pem}"
    local sni="${5:-${SERVER_DOMAIN:-www.example.com}}"

    cat << EOF
{
    "type": "trojan",
    "tag": "trojan-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        { "password": "${password}" }
    ],
    "tls": {
        "enabled": true,
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}",
        "server_name": "${sni}"
    }
}
EOF
}

_proto_trojan_uri() {
    local password="$1" server_ip="$2" port="$3" name="$4"
    local sni="${5:-$server_ip}"
    local insecure="${6:-1}"
    # 进阶(真实证书): host/sni 改用域名且去掉 insecure; 默认(自签): IP + insecure=1
    local host="$server_ip"
    if _real_cert_ready; then
        insecure="0"
        if [ -n "${SERVER_DOMAIN:-}" ]; then
            host="$SERVER_DOMAIN"
            sni="$SERVER_DOMAIN"
        fi
    fi
    local ep=$(_url_encode "$name")
    echo -n "trojan://${password}@${host}:${port}?security=tls&sni=${sni}&allowInsecure=${insecure}#${ep}"
}

# ============================================================
# 6. Shadowsocks 2022 (AEAD, 轻量兜底/老设备)
# ============================================================
# 2022 系列为 AEAD 增强版, 密码学强度高于旧 ss (rc4/md5 等已淘汰)。
# 这里用 2022-blake3-aes-256-gcm (PSK 32 字节 base64)。
# 优势: 极轻量, 低端路由/嵌入式设备/老旧客户端都能跑; 作兜底节点。

_proto_ss2022_config() {
    local port="$1" psk="$2"
    local method="${3:-2022-blake3-aes-256-gcm}"

    cat << EOF
{
    "type": "shadowsocks",
    "tag": "ss2022-${port}",
    "listen": "::",
    "listen_port": ${port},
    "method": "${method}",
    "password": "${psk}"
}
EOF
}

_proto_ss2022_uri() {
    local method="$1" psk="$2" server_ip="$3" port="$4" name="$5"
    local ep=$(_url_encode "$name")
    # SIP002 标准: ss://base64(method:password)@host:port#name
    # 内部 PSK 已是 base64 (含 +/ =), 外层 base64 后会再编码, 无需手动转 url-safe
    local userinfo=$(printf '%s:%s' "$method" "$psk" | base64 2>/dev/null | tr -d '\n=')
    echo -n "ss://${userinfo}@${server_ip}:${port}#${ep}"
}

# ============================================================
# 7. SOCKS5 (明文, 带用户名/密码认证)
# ============================================================
# 说明: SOCKS5 本身无加密, 仅适合可信网络或作本地/中转跳板, 不建议直连公网当主力节点。
# 这里按用户要求提供「带认证的 SOCKS5 服务端 inbound」, 用于:
#   - 本地工具/爬虫走代理; - 作为 relay 中转机的入口跳板 (配合下游加密协议)。
# ⚠️ 直连公网暴露 SOCKS5 有被扫描滥用的风险, 脚本仅生成配置, 是否暴露由用户自行决定。

_proto_socks5_config() {
    local port="$1" user="$2" pass="$3"

    cat << EOF
{
    "type": "socks",
    "tag": "socks5-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        { "username": "${user}", "password": "${pass}" }
    ]
}
EOF
}

_proto_socks5_uri() {
    local user="$1" pass="$2" server_ip="$3" port="$4" name="$5"
    local ep=$(_url_encode "$name")
    echo -n "socks5://${user}:${pass}@${server_ip}:${port}#${ep}"
}

# ============================================================
# 8. VMess WebSocket
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
    "tls": {
        "certificate_path": "${SINGBOX_DIR}/cert.pem",
        "key_path": "${SINGBOX_DIR}/key.pem"
    },
    "transport": {
        "type": "ws",
        "path": "${ws_path}",
        "headers": {},
        "early_data_header_name": "Sec-WebSocket-Protocol"
    }
}
EOF
}

# VLESS over WebSocket + TLS 服务端 inbound (sing-box 1.11+ 原生, 替代已移除的 VMess)
# 注意: 不带 flow (xtls-rprx-vision 用于 reality/tcp, vless-ws 不需要)
_proto_vless_ws_config() {
    local port="$1" uuid="$2" ws_path="${3:-/ws}"

    [[ ! "$ws_path" == /* ]] && ws_path="/${ws_path}"

    cat << EOF
{
    "type": "vless",
    "tag": "vless-ws-${port}",
    "listen": "::",
    "listen_port": ${port},
    "users": [
        { "uuid": "${uuid}" }
    ],
    "tls": {
        "certificate_path": "${SINGBOX_DIR}/cert.pem",
        "key_path": "${SINGBOX_DIR}/key.pem"
    },
    "transport": {
        "type": "ws",
        "path": "${ws_path}",
        "headers": {}
    }
}
EOF
}

_proto_vmess_ws_uri() {
    local uuid="$1" server_ip="$2" port="$3" ws_path="${4:-/ws}"
    local name="$5"
    local fp=$(_cert_sha256)

    # VMess 完整 Xray 配置 (v2rayN「从剪贴板导入」专用):
    #   - security=tls + pinnedPeerCertificateChainSha256 固定证书 (Xray 核心用, 自签 CA 不被信任)
    #   - allowInsecure=true 兼容 v2rayN sing_box 核心:
    #       v2rayN 转换 Xray 配置到 sing-box 时, tlsSettings.pinnedPeerCertificateChainSha256
    #       会被丢弃 (sing-box 原生 VMess 用 certificate_public_key_sha256, 字段名/编码都不同,
    #       v2rayN 转换器不会换算), 没有 allowInsecure 时 sing_box 核心下自签证书校验必失败 -> -1
    #       allowInsecure=true 会被转换为 sing-box tls.insecure, 跳过证书校验, 核心通用
    #   - Xray 2026-08-01 后 allowInsecure=true 仍可用 (前提是同时配置 pinned 证书哈希,
    #     即本配置同时含 pin + allowInsecure=true, 满足 Xray 8/1 例外条款)
    # 导入方式: 复制下面整段 JSON → v2rayN「设置 → 从剪贴板导入」
    jq -nc \
        --arg addr "$server_ip" \
        --arg port "$port" \
        --arg id "$uuid" \
        --arg path "$ws_path" \
        --arg sni "$server_ip" \
        --arg fp "$fp" \
        '{
            outbounds: [{
                protocol: "vmess",
                tag: "proxy",
                settings: {
                    vnext: [{
                        address: $addr,
                        port: ($port|tonumber),
                        users: [{ id: $id, alterId: 0, security: "auto" }]
                    }]
                },
                streamSettings: {
                    network: "ws",
                    wsSettings: { path: $path, headers: {} },
                    security: "tls",
                    tlsSettings: {
                        serverName: $sni,
                        pinnedPeerCertificateChainSha256: $fp,
                        allowInsecure: true
                    }
                }
            }]
        }'
}

_proto_vmess_ws_standard_uri() {
    # 标准 vmess:// 分享链接 (base64 json), 小火箭 / v2rayN 标准导入均支持
    # 注意: 标准格式无法携带证书指纹, 自签证书需客户端手动「允许不安全」
    # (小火箭仍支持 allowInsecure, 不在 8.1 弃用名单; v2rayN 仅作备选导入)
    local uuid="$1" server_ip="$2" port="$3" ws_path="${4:-/ws}"
    local name="$5"
    local vmess_json=$(jq -nc \
        --arg v "2" \
        --arg ps "$name" \
        --arg add "$server_ip" \
        --arg port "$port" \
        --arg id "$uuid" \
        --arg path "$ws_path" \
        --arg tls "tls" \
        --arg sni "$server_ip" \
        '{
            v: $v,
            ps: $ps,
            add: $add,
            port: $port,
            id: $id,
            aid: "0",
            scy: "auto",
            net: "ws",
            type: "none",
            host: "",
            path: $path,
            tls: $tls,
            sni: $sni,
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

    if [ "${1:-}" != "force" ] && [ -f "${cert_dir}/cert.pem" ] && [ -f "${cert_dir}/key.pem" ]; then
        _info "TLS 证书已存在，跳过生成（如需更新 SAN 请用: sb renew-cert）"
        return 0
    fi

    _info "正在生成自签名 TLS 证书..."
    # SAN 必须包含公网 IP: TUIC / VMess 等依赖真实 TLS 校验的协议, 其分享链接
    # 不能带 insecure=1 (TUIC 带会触发小火箭 v4 回退 bug; VMess 标准格式不支持),
    # 只能靠证书 SAN 覆盖连接用的公网 IP 才能握手通过。仅含 127.0.0.1 会导致这两个协议失败。
    local pub_ip=""
    pub_ip=$(curl -s --max-time 8 icanhazip.com 2>/dev/null)
    [ -z "$pub_ip" ] && pub_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local san="DNS:sing-box-pro,DNS:localhost,IP:127.0.0.1"
    [ -n "$pub_ip" ] && san="${san},IP:${pub_ip}"
    openssl req -x509 -newkey rsa:2048 -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/cert.pem" -days 3650 -nodes \
        -subj "/CN=sing-box-pro" \
        -addext "subjectAltName=${san}" 2>/dev/null

    if [ -f "${cert_dir}/cert.pem" ] && [ -f "${cert_dir}/key.pem" ]; then
        _success "TLS 证书已生成（SAN: ${san}）"
        return 0
    fi

    _error "证书生成失败，请检查 openssl 是否安装"
    return 1
}

# 重生成证书: SAN 自动包含公网 IP (解决 TUIC/VMess 依赖真实 TLS 校验却无 SAN 覆盖公网 IP 的问题)
_sb_renew_cert() {
    _info "重生成 TLS 证书（SAN 将包含公网 IP）..."
    _proto_generate_cert force || return 1
    _info "重启 sing-box 使新证书生效..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sing-box 2>/dev/null && sleep 2
    elif command -v service >/dev/null 2>&1; then
        service sing-box restart 2>/dev/null && sleep 2
    fi
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        _success "sing-box 已重启，新证书生效"
    else
        _warn "无法确认 sing-box 状态，请手动检查: systemctl status sing-box"
    fi
    # 自动打印 VMess 新链接(标准 vmess:// + v2rayN 完整 Xray 配置), 用户直接复制重导
    # 这样证书重生成 → VMess pin 更新 一站式完成, 避免因旧 pin 导致 TLS 失败
    _sb_print_vmess_links_after_renew
}

_sb_print_vmess_links_after_renew() {
    local cfg="${SINGBOX_CFG:-/usr/local/etc/sing-box/config.json}"
    [ -f "$cfg" ] || { _warn "未找到 $cfg, 跳过自动打印 VMess 链接"; return 0; }

    local server_ip=$(_get_public_ip 2>/dev/null || hostname -I | awk '{print $1}')
    [ -n "$server_ip" ] || { _warn "无法检测公网 IP, 跳过"; return 0; }

    local new_fp=$(_cert_sha256)
    local count=0
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  证书已重生成, VMess 节点的 pinnedPeerCertificateChainSha256 已变化  ║${NC}"
    echo -e "${YELLOW}║  请用下方「新链接」覆盖 v2rayN 中的旧 VMess 节点 (旧 pin 已失效)       ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}新证书 pin (DER sha256, hex): ${GREEN}${new_fp}${NC}"
    echo ""

    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r '.tag // empty')
        local type=$(echo "$line" | jq -r '.type // empty')
        local port=$(echo "$line" | jq -r '.listen_port // empty')
        [ "$type" = "vmess" ] || continue
        local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
        local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
        local name="$tag"
        local std=$(_proto_vmess_ws_standard_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
        local full=$(_proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
        echo -e "${GREEN}━━━ [$tag] ━━━${NC}"
        echo -e "  标准 vmess:// (小火箭): ${std}"
        echo -e "  完整 Xray 配置 (v2rayN): ${full}"
        echo ""
        count=$((count + 1))
    done < <(jq -c '.inbounds[]? | select(.type=="vmess")' "$cfg" 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}  (未发现 vmess inbound, 无需重导)${NC}"
    else
        echo -e "${CYAN}👉 复制「完整 Xray 配置」整段 JSON → v2rayN「设置 → 从剪贴板导入」覆盖旧节点${NC}"
        echo -e "${CYAN}   或用「标准 vmess://」导入小火箭${NC}"
    fi
    echo ""
}

# ============================================================
# 证书指纹 (TLS 协议共用, 供 Xray 系客户端证书固定/pinned 验证)
# ============================================================
# 重要 (2026-08-01 背景 / share link 策略):
#   Xray 于 2026-08-01 禁用 allowInsecure, 纯 Xray 内核客户端(v2rayNG 等)的自签证书场景
#   必须改用证书固定(pinned)。脚本已为 VMess 提供 Xray 的 pinnedPeerCertificateChainSha256(证书哈希)。
#   但 sing-box 系与 Xray 系的 pinned 字段语义分裂:
#     - sing-box 1.13+ 字段为 certificate_public_key_sha256(「证书公钥」哈希)
#     - Xray 系 TUIC/H2/AnyTLS 的 pinned_cert_sha256 要的是「证书」哈希
#   而 share link 的 pinned_cert_sha256 在 v2rayN 等客户端解析时语义不确定, 易连不通
#   (实测: 填公钥哈希但客户端按证书哈希校验 → 永远对不上 → 握手失败, 且不回退 insecure)。
#   因此 AnyTLS/TUIC/Hysteria2 的分享链接统一用 insecure=1 / allow_insecure=1 跳过验证 ——
#   这是 sing-box 内核(tls.insecure 字段)的合法行为, 不受 Xray 8/1 禁令影响。
#   主力客户端 v2rayN 选 sing_box 模式即走 sing-box 内核, 可安心使用。
#   纯 Xray 客户端请用 VLESS-Reality(免验证) / VMess(证书哈希 pin), 不依赖 insecure。

# 真实证书就绪判定: 设了 SERVER_DOMAIN(或持久化 .server_domain) 且 acme 证书已落地
# 供各协议 URI 生成函数判断是否切换到「域名 host + 去掉 insecure」的进阶模式
_real_cert_ready() {
    local domain="${SERVER_DOMAIN:-}"
    [ -z "$domain" ] && [ -f "${SINGBOX_DIR}/.server_domain" ] && \
        domain="$(cat "${SINGBOX_DIR}/.server_domain" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$domain" ] || return 1
    local acme_dir="${CERT_ACME_DIR:-${SINGBOX_DIR}/acme}"
    [ -f "${acme_dir}/${domain}/fullchain.pem" ] && return 0
    return 1
}

_cert_public_key_sha256() {
    # sing-box 1.13.0+ 证书固定用: 「证书公钥(SPKI)的 SHA-256」base64 编码
    # 官方生成命令:
    #   openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der \
    #     | openssl dgst -sha256 -binary | openssl enc -base64
    # 注意: 是「公钥哈希」, 不是「证书哈希」! 这是 2026 年 pin 能连通的关键。
    # 参数 $1: 证书路径 (默认 ${SINGBOX_DIR}/cert.pem)
    local cert="${1:-${SINGBOX_DIR}/cert.pem}"
    [ -f "$cert" ] || { echo ""; return 1; }
    openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl enc -base64 -A 2>/dev/null
}

_cert_sha256() {
    # Xray VMess tlsSettings.pinnedPeerCertificateChainSha256 用: 证书 SHA-256 (hex, 无冒号)
    # 注意这是「证书哈希」(Xray 语义), 与 sing-box 的「公钥哈希」(_cert_public_key_sha256) 不同!
    # 参数 $1: 证书路径 (默认 ${SINGBOX_DIR}/cert.pem)
    local cert="${1:-${SINGBOX_DIR}/cert.pem}"
    [ -f "$cert" ] || { echo ""; return 1; }
    openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
        | sed -E 's/^[^=]*=//; s/://g' | tr 'A-Z' 'a-z'
}

# ============================================================
# 协议 / 传输 / flow 兼容性校验 (P0 #1, v2.1.9)
# ============================================================
# 背景:
#   - 2026-07-31 确诊 69.42.222.160 前端 L7 拦截裸 WebSocket;
#   - 更早的存量 bug (vless-ws-50006 带 xtls-rprx-vision) 证明「ws + flow」这类
#     矛盾配置能进入生产。sing-box 对部分组合只是忽略/告警仍能启动, 但客户端必连不通。
# sing-box 语义规则:
#   - flow (xtls-rprx-vision) 仅对 type=vless 有效;
#   - 且要求 tls.reality.enabled == true (flow 是 reality 专属特性);
#   - 且 transport 必须为 tcp (无 transport, 或 transport.type=="tcp");
#     ws/grpc 上跑 vision 不被支持。
# 任何 inbound 违反上述 → 视为无效配置, 阻止写入/重启。
# 参数: $1 配置文件路径 (默认 $CONFIG_FILE)
# 返回: 0 = 全部合规; 1 = 存在违规 (并打印违规项到 stderr)
_proto_validate_flow_compat() {
    local cfg="${1:-$CONFIG_FILE}"
    [ -f "$cfg" ] || { _error "校验失败: 找不到配置文件 $cfg"; return 1; }
    command -v jq >/dev/null 2>&1 || { _warn "jq 不可用, 跳过 flow 兼容性校验"; return 0; }

    # 用 jq 抽出所有违规 inbound 的 "tag :: 原因"
    local bad_list
    bad_list=$(jq -r '
        (.inbounds // []) | .[] |
        (.tag) as $tag |
        (.type) as $type |
        (.tls.reality.enabled // false) as $reality |
        (.transport.type // "tcp") as $transport |
        ((.users // []) | map(.flow // "") | map(select(length>0)) | length) as $flow_count |
        (if $flow_count > 0 then
            (if $type != "vless" then
                "flow 仅支持 vless, 但本 inbound type=\($type)"
            elif $reality != true then
                "flow(xtls-rprx-vision) 要求 tls.reality.enabled=true, 但 reality 未启用"
            elif $transport != "tcp" then
                "flow(xtls-rprx-vision) 仅支持 TCP 传输, 但 transport=\($transport) (ws/grpc 不支持 vision)"
            else
                empty
            end)
         else empty end) as $reason |
        (if $reason != "" then "\($tag) :: \($reason)" else empty end)
    ' "$cfg" 2>/dev/null)

    if [ -n "$bad_list" ]; then
        _error "协议/传输/flow 兼容性校验失败 — 以下 inbound 配置矛盾:"
        echo "$bad_list" | while IFS= read -r line; do
            echo -e "    ${RED}✗${NC} $line" >&2
        done
        _error "请修正后再写入/重启 (ws/tuic/hysteria2/anytls/vmess 等绝不能带 flow; vless 带 flow 必须 reality+tcp)。"
        return 1
    fi
    return 0
}

# ============================================================
# 添加入站到配置
# ============================================================

_proto_add_inbound() {
    local inbound_json="$1"

    # P0 #1: 写入前先校验「协议/传输/flow 兼容性」, 杜绝 ws+flow 等矛盾配置进入生产
    _proto_validate_flow_compat "$CONFIG_FILE" || return 1

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
        vmess-ws|vless-ws)
            local uuid="$1" ws_path="${2:-/ws}"
            if [ "$proto" = "vless-ws" ]; then
                # 注意: _proto_vless_ws_uri 签名比 vmess 多一个 sni 参数 (第4位),
                # 必须显式传 sni (默认=server_ip), 否则 ws_path/name 会整体错位一位
                _proto_vless_ws_uri "$uuid" "$server_ip" "$port" "$server_ip" "$ws_path" "$name"
            else
                _proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name"
            fi
            ;;
        trojan)
            local password="$1" sni="${2:-$server_ip}" insecure="${3:-1}"
            _proto_trojan_uri "$password" "$server_ip" "$port" "$name" "$sni" "$insecure"
            ;;
        shadowsocks)
            local method="$1" psk="$2"
            _proto_ss2022_uri "$method" "$psk" "$server_ip" "$port" "$name"
            ;;
        socks)
            local user="$1" pass="$2"
            _proto_socks5_uri "$user" "$pass" "$server_ip" "$port" "$name"
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
    echo "  1. VLESS Reality  (TLS + reality, 抗封锁)"
    echo "  2. AnyTLS"
    echo "  3. TUIC V5         (UDP + BBR)"
    echo "  4. Hysteria2       (QUIC)"
    echo "  5. Trojan          (TLS, 真证书 HTTPS 外形, 路径放行)"
    echo "  6. Shadowsocks2022 (AEAD, 轻量兜底)"
    echo "  7. SOCKS5          (明文, 带认证, 作跳板/本地代理)"
    echo "  8. VLESS WebSocket (WS, 经 Argo 隧道使用, 不直接对外暴露)"
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
