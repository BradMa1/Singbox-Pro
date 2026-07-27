#!/bin/bash
# ============================================================
# relay.sh — 中转/端口转发管理模块
# 支持：协议中转 (落地机→中转机) + iptables 端口转发
# ============================================================
export RELAY_MOD_VERSION="2.0.8"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

# --- 中转元数据 ---
export RELAY_CONFIG_DIR="${RELAY_CONFIG_DIR:-/etc/sing-box}"
RELAY_META="${RELAY_META:-${RELAY_CONFIG_DIR}/relay.json}"
PF_META="${PF_META:-${RELAY_CONFIG_DIR}/pf.json}"
# 确保 METADATA_FILE 有默认值（singbox.sh 也可能设置）
export METADATA_FILE="${METADATA_FILE:-${SINGBOX_DIR:-/usr/local/etc/sing-box}/metadata.json}"

# ============================================================
# 中转 Token 生成
# ============================================================

_relay_ensure() {
    mkdir -p "$RELAY_CONFIG_DIR"
    [ -f "$RELAY_META" ] || echo '[]' > "$RELAY_META"
}

# 根据选中的入站节点生成落地 Token（outbound JSON）
_relay_gen_token() {
    local tag="$1" node="$2"
    local addr="${CUSTOM_IP:-$(_get_public_ip)}"
    local ntype=$(echo "$node" | jq -r '.type')
    local nport=$(echo "$node" | jq -r '.listen_port')
    local token_json="{\"type\":\"${ntype}\",\"server\":\"${addr}\",\"server_port\":${nport}"

    case "$ntype" in
        vless)
            local uuid=$(echo "$node" | jq -r '.users[0].uuid')
            local flow=$(echo "$node" | jq -r '.users[0].flow // ""')
            token_json="${token_json},\"uuid\":\"${uuid}\""
            [ -n "$flow" ] && [ "$flow" != "null" ] && token_json="${token_json},\"flow\":\"${flow}\""
            # 复制 TLS 配置，但移除 reality.handshake（outbound 不支持该字段）
            local tls=$(echo "$node" | jq -c '.tls // {}')
            if [ "$(echo "$tls" | jq '.enabled // false')" = "true" ]; then
                local tls_clean=$(echo "$tls" | jq 'if .reality then .reality |= del(.handshake, .private_key) | .reality.short_id = (.reality.short_id[0] // "") else . end')
                # Reality outbound 必须有 public_key（从 metadata 读取）和 utls 指纹
                if [ "$(echo "$tls" | jq '.reality.enabled // false')" = "true" ]; then
                    # 从 metadata 提取 public_key（落地机生成节点时保存）
                    local pbk=""
                    if [ -n "$METADATA_FILE" ] && [ -f "$METADATA_FILE" ]; then
                        pbk=$(jq -r ".protocols.\"${tag}\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                    fi
                    # 如果 metadata 里没有，从 inbound 的 reality.short_id 所在层级尝试取公钥字段
                    if [ -z "$pbk" ]; then
                        pbk=$(echo "$tls" | jq -r '.reality.public_key // empty')
                    fi
                    # 在 reality 对象中注入 public_key
                    if [ -n "$pbk" ]; then
                        tls_clean=$(echo "$tls_clean" | jq --arg pbk "$pbk" '.reality.public_key = $pbk')
                    fi
                    # VLESS Reality outbound 必须有 utls 指纹
                    tls_clean=$(echo "$tls_clean" | jq '. + {"utls": {"enabled": true, "fingerprint": "chrome"}}')
                fi
                token_json="${token_json},\"tls\":${tls_clean}"
            fi
            local trans=$(echo "$node" | jq -c '.transport // {}')
            [ "$trans" != "{}" ] && token_json="${token_json},\"transport\":${trans}"
            ;;
        tuic)
            local uuid=$(echo "$node" | jq -r '.users[0].uuid')
            local psk=$(echo "$node" | jq -r '.users[0].password')
            token_json="${token_json},\"uuid\":\"${uuid}\",\"password\":\"${psk}\""
            local tls=$(echo "$node" | jq -c '.tls // {}')
            [ "$tls" != "{}" ] && token_json="${token_json},\"tls\":${tls}"
            ;;
        hysteria2)
            local psk=$(echo "$node" | jq -r '.users[0].password')
            token_json="${token_json},\"password\":\"${psk}\""
            local tls=$(echo "$node" | jq -c '.tls // {}')
            [ "$tls" != "{}" ] && token_json="${token_json},\"tls\":${tls}"
            local obfs=$(echo "$node" | jq -c '.obfs // {}')
            [ "$obfs" != "{}" ] && token_json="${token_json},\"obfs\":${obfs}"
            ;;
        anytls)
            local psk=$(echo "$node" | jq -r '.users[0].password')
            token_json="${token_json},\"password\":\"${psk}\""
            local tls=$(echo "$node" | jq -c '.tls // {}')
            [ "$tls" != "{}" ] && token_json="${token_json},\"tls\":${tls}"
            ;;
        shadowsocks)
            local method=$(echo "$node" | jq -r '.method')
            local password=$(echo "$node" | jq -r '.password')
            token_json="${token_json},\"method\":\"${method}\",\"password\":\"${password}\""
            ;;
    esac
    token_json="${token_json}}"
    echo "$token_json"
}

# ============================================================
# 中转管理菜单
# ============================================================

_relay_main_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 中转管理 ===${NC}"
        echo ""
        echo -e "  落地机: 搭建了代理节点的机器（本机通常是落地机）"
        echo -e "  线路机: 负责转发流量的中转机器"
        echo ""
        echo -e "  落地机操作:"
        echo -e "    ${GREEN}[1]${NC} 生成线路机安装脚本（VLESS Reality 中转）"
        echo -e "    ${GREEN}[2]${NC} 生成全协议中转 Token（发给中转机）"
        echo ""
        echo -e "  中转机操作:"
        echo -e "    ${GREEN}[3]${NC} 导入落地 Token（配置中转入站）"
        echo -e "    ${GREEN}[4]${NC} 查看中转路由"
        echo -e "    ${GREEN}[5]${NC} 删除中转路由"
        echo ""
        echo -e "  端口转发 (iptables):"
        echo -e "    ${GREEN}[6]${NC} 端口转发管理"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-6]: " opt

        case "$opt" in
            1) _relay_gen_install_script ;;
            2) _relay_gen_landing_token ;;
            3) _relay_import_token ;;
            4) _relay_view_routes ;;
            5) _relay_delete_route ;;
            6) _relay_port_forward_menu ;;
            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 1) 生成线路机安装脚本（VLESS Reality 中转）
# ============================================================

_relay_gen_install_script() {
    clear
    echo -e "${CYAN}=== 生成线路机安装脚本（VLESS Reality 中转）===${NC}"
    echo ""
    _info "此功能基于当前的 VLESS Reality 节点生成一个可在其他 VPS 上运行的安装脚本"
    echo ""

    # 查找 VLESS Reality 入站
    local vless_node=$(jq -c '.inbounds[] | select(.type == "vless" and .tls.reality)' "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -z "$vless_node" ]; then
        _error "当前没有 VLESS Reality 节点。请先添加一个 VLESS Reality 节点。"
        echo ""
        _info "操作步骤: sb → 1 → 1 (VLESS Reality)"
        read -p "按回车键返回..."
        return
    fi

    local vless_port=$(echo "$vless_node" | jq -r '.listen_port')
    local vless_uuid=$(echo "$vless_node" | jq -r '.users[0].uuid')
    local vless_sni=$(echo "$vless_node" | jq -r '.tls.server_name // "addons.mozilla.org"')
    local vless_tag=$(echo "$vless_node" | jq -r '.tag // ""')
    local landing_pbk=""
    if [ -n "$METADATA_FILE" ] && [ -f "$METADATA_FILE" ] && [ -n "$vless_tag" ]; then
        landing_pbk=$(jq -r ".protocols.\"${vless_tag}\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
    fi
    [ -z "$landing_pbk" ] && { _error "无法获取 VLESS Reality 公钥，请确认 metadata.json 存在且节点已保存"; read -p "按回车键返回..."; return; }

    local pub_ip="${CUSTOM_IP:-$(_get_public_ip)}"
    local relay_script="/tmp/relay-install.sh"

    _info "正在生成脚本..."

    cat > "$relay_script" <<'RELAYEOF'
#!/usr/bin/env bash
set -euo pipefail
RED='\033[1;31m'; GREEN='\033[1;32m'; BLUE='\033[1;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }; ok() { echo -e "${GREEN}[OK]${NC} $*"; }; err() { echo -e "${RED}[ERR]${NC} $*" >&2; }
[ "$(id -u)" != "0" ] && err "需要 root 权限" && exit 1

detect_os() {
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in alpine) OS=alpine;; debian|ubuntu) OS=debian;; centos|rhel|fedora|rocky|almalinux) OS=redhat;; *) OS=unknown;; esac
}
detect_os

info "系统: ${OS}，正在安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates sing-box --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community >/dev/null 2>&1 ;;
    debian) apt-get update -y >/dev/null 2>&1; apt-get install -y curl jq bash openssl ca-certificates >/dev/null 2>&1; bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null 2>&1 ;;
    redhat) yum install -y curl jq bash openssl ca-certificates >/dev/null 2>&1; bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null 2>&1 ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep PublicKey | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "监听端口（回车随机 20000-65000）: " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

# 检测 sing-box 安装路径（优先本项目路径 /usr/local，回退官方 /usr）
if [ -x /usr/local/bin/sing-box ]; then
    SB_BIN=/usr/local/bin/sing-box
    SB_DIR=/usr/local/etc/sing-box
elif [ -x /usr/bin/sing-box ]; then
    SB_BIN=/usr/bin/sing-box
    SB_DIR=/etc/sing-box
else
    # 默认按 Singbox-Pro 安装路径
    SB_BIN=/usr/local/bin/sing-box
    SB_DIR=/usr/local/etc/sing-box
fi
RELAY_CONFIG_DIR="$SB_DIR"
mkdir -p "$RELAY_CONFIG_DIR"
cat > "${RELAY_CONFIG_DIR}/config.json" <<EOF
{"log":{"level":"info"},"inbounds":[{"type":"vless","tag":"vless-in","listen":"::","listen_port":$LISTEN_PORT,"users":[{"uuid":"$UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"__REALITY_SNI__","reality":{"enabled":true,"handshake":{"server":"__REALITY_SNI__","server_port":443},"private_key":"$REALITY_PK","short_id":["$REALITY_SID"]}}}],"outbounds":[{"type":"vless","tag":"relay-out","server":"__LANDING_IP__","server_port":__LANDING_PORT__,"uuid":"__LANDING_UUID__","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"addons.mozilla.org","reality":{"enabled":true,"public_key":"__LANDING_PBK__"},"utls":{"enabled":true,"fingerprint":"chrome"}}},{"type":"direct","tag":"direct"}],"route":{"rules":[{"inbound":"vless-in","outbound":"relay-out"}],"final":"direct"}}
EOF

cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${SB_DIR}/config.json
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box || { err "启动失败"; exit 1; }

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")
echo ""; info "线路机部署完成！"
echo "vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"
RELAYEOF

    # 替换占位符
    for p in __LANDING_IP__ __LANDING_PORT__ __LANDING_UUID__ __LANDING_PBK__ __REALITY_SNI__; do
        case "$p" in
            __LANDING_IP__) sed -i "s~__LANDING_IP__~${pub_ip}~g" "$relay_script" ;;
            __LANDING_PORT__) sed -i "s~__LANDING_PORT__~${vless_port}~g" "$relay_script" ;;
            __LANDING_UUID__) sed -i "s~__LANDING_UUID__~${vless_uuid}~g" "$relay_script" ;;
            __LANDING_PBK__) sed -i "s~__LANDING_PBK__~${landing_pbk}~g" "$relay_script" ;;
            __REALITY_SNI__) sed -i "s~__REALITY_SNI__~${vless_sni}~g" "$relay_script" ;;
        esac
    done

    chmod +x "$relay_script"

    echo ""
    echo -e "${CYAN}=== 线路机安装脚本内容（选中复制后到线路机执行）===${NC}"
    echo -e "${YELLOW}提示：下方为完整脚本内容，全选复制，粘贴到线路机执行${NC}"
    echo ""
    cat "$relay_script"
    echo ""
    echo -e "${CYAN}--- 完整脚本文件路径 ---${NC}"
    echo -e "  ${GREEN}${relay_script}${NC}"
    echo -e "  ${CYAN}上传并在线路机上执行:${NC}"
    echo -e "  scp ${relay_script} root@线路机IP:/tmp/"
    echo -e "  ssh root@线路机IP 'bash /tmp/relay-install.sh'"
    echo ""
    read -p "按回车键返回..."
}

# ============================================================
# 2) 落地机：生成全协议中转 Token
# ============================================================

_relay_gen_landing_token() {
    clear
    echo -e "${CYAN}=== 落地机 — 生成中转 Token ===${NC}"
    echo ""
    _relay_ensure

    # 读取所有入站节点
    local nodes=$(jq -c '.inbounds[]' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$nodes" ] && { _error "未找到任何落地节点，请先添加节点"; read -p "按回车键返回..."; return 1; }

    local i=1
    local -A relay_choices
    echo "  选择要中转的落地节点:"
    echo ""
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        local ntype=$(echo "$node" | jq -r '.type')
        local nport=$(echo "$node" | jq -r '.listen_port')
        local ntag=$(echo "$node" | jq -r '.tag // ""')
        echo -e "    ${GREEN}[$i]${NC} ${ntype}:${nport}${ntag:+ (${ntag})}"
        relay_choices[$i]="$node"
        i=$((i + 1))
    done <<< "$nodes"

    echo ""
    echo -n "  选择节点编号 (多选用空格分隔，如 1 3 5，回车默认全选): "; read -r ch

    # 空输入默认为全选
    if [ -z "$ch" ]; then
        ch=""
        for idx in "${!relay_choices[@]}"; do
            ch="${ch}${idx} "
        done
        ch=${ch% }  # 去掉末尾空格
    fi

    # 支持空格分隔多选，逐个生成 Token
    local all_tokens=""
    for sel_num in $ch; do
        sel_num=$(echo "$sel_num" | tr -d ' ')  # 去掉可能的空格
        [ -z "${relay_choices[$sel_num]}" ] && { _error "无效选择: $sel_num"; continue; }

        local sel="${relay_choices[$sel_num]}"
        local sel_tag=$(echo "$sel" | jq -r '.tag // "relay"')
        local sel_type=$(echo "$sel" | jq -r '.type')
        local sel_port=$(echo "$sel" | jq -r '.listen_port')
        local token=$(_relay_gen_token "$sel_tag" "$sel")
        if [ -z "$token" ]; then
            _error "节点 ${sel_tag} (${sel_type}:${sel_port}) Token 生成失败，跳过"
            continue
        fi

        local b64=$(echo -n "$token" | base64 -w0 2>/dev/null || echo -n "$token" | base64 | tr -d '\n')
        all_tokens="${all_tokens}--- ${sel_tag} (${sel_type}:${sel_port}) ---\n${b64}\n\n"
    done

    if [ -z "$all_tokens" ]; then
        _error "没有任何 Token 生成成功"
        read -p "按回车键返回..."
        return
    fi

    echo ""
    echo -e "  ${CYAN}=== 落地 Token 列表（复制到中转机）===${NC}"
    echo -e "${YELLOW}提示：每组 --- 分隔一个节点，中转机 sb → 8 → 3 逐个导入${NC}"
    echo ""
    echo -e "${GREEN}${all_tokens}${NC}"
    echo ""
    _info "中转机操作: sb → 8 → 3，粘贴上面的 Base64 Token（每个节点单独导入）"
    echo ""

    echo -n "保存 Token 到文件（回车跳过）: "; read -r save_t
    [ -n "$save_t" ] && { echo -e "$all_tokens" > "$save_t"; _success "已保存到 $save_t"; }

    read -p "按回车键返回..."
}

# ============================================================
# 3) 中转机：导入落地 Token
# ============================================================

_relay_import_token() {
    clear
    echo -e "${CYAN}=== 中转机 — 导入落地 Token ===${NC}"
    echo ""
    _relay_ensure

    echo "  从落地机获取的 Base64 Token:"
    echo -n "  粘贴 Token 或输入文件路径: "; read -r token_in
    [ -z "$token_in" ] && { _warn "Token 不能为空"; read -p "按回车键返回..."; return; }

    local token_json=""
    if [ -f "$token_in" ]; then
        token_json=$(cat "$token_in" | base64 -d 2>/dev/null || cat "$token_in")
    else
        token_json=$(echo -n "$token_in" | base64 -d 2>/dev/null || echo "$token_in")
    fi

    echo "$token_json" | jq . >/dev/null 2>&1 || { _error "Token 格式无效，请确认复制完整"; read -p "按回车键返回..."; return; }

    local rtype=$(echo "$token_json" | jq -r '.type')
    local rserver=$(echo "$token_json" | jq -r '.server')
    local rport=$(echo "$token_json" | jq -r '.server_port')
    local rtag="relay-${rtype}-${rport}"

    _info "识别落地: ${rtype} → ${rserver}:${rport}"
    echo ""

    local lport=$(_random_port 10000 60000)
    echo -n "  本机监听端口（回车随机 ${lport}）: "; read -r input_lport
    lport="${input_lport:-$lport}"

    # 检查端口冲突
    if _check_port_occupied "$lport" "tcp"; then
        _error "端口 ${lport} 已被占用"
        read -p "按回车键返回..."
        return
    fi

    # 选择入口协议
    echo ""
    echo "  入口协议（中转入口）:"
    echo -e "    ${GREEN}[1]${NC} VLESS Reality    (推荐，无需证书)"
    echo -e "    ${GREEN}[2]${NC} Hysteria2        (QUIC，需证书)"
    echo -e "    ${GREEN}[3]${NC} TUIC V5           (UDP，需证书)"
    echo -e "    ${GREEN}[4]${NC} AnyTLS            (需证书)"
    echo ""
    echo -n "  选择（默认 1）: "; read -r in_proto
    in_proto="${in_proto:-1}"

    local in_type=""
    local in_flow=""
    case "$in_proto" in
        2) in_type="hysteria2" ;;
        3) in_type="tuic" ;;
        4) in_type="anytls" ;;
        *) in_type="vless"; in_flow="xtls-rprx-vision" ;;
    esac

    # TLS 证书（非 VLESS 协议需要，无证书则自动生成自签证书）
    if [ "$in_type" != "vless" ]; then
        local cert_path="/etc/sing-box/certs/fullchain.pem"
        local key_path="/etc/sing-box/certs/privkey.pem"
        if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
            _info "未检测到 TLS 证书，自动生成自签证书..."
            mkdir -p /etc/sing-box/certs
            openssl req -x509 -newkey rsa:4096 \
                -keyout "$key_path" -out "$cert_path" \
                -days 3650 -nodes -subj "/CN=singbox-pro" 2>/dev/null
            _ok "自签证书已生成 (${cert_path})"
            _warn "自签证书: sing-box 内核客户端无需跳过证书验证(已内置公钥指纹固定); Shadowrocket 可保留「跳过证书验证」(非 Xray, 8/1 不受影响)"
        fi
    fi

    # 生成入站凭证
    local in_uuid=""
    local in_psk=""
    local in_keys=""
    if [ "$in_type" = "vless" ]; then
        in_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
        in_keys=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || echo "")
    fi
    local in_psk=$(openssl rand -base64 16 2>/dev/null || head -c 24 /dev/urandom | base64 | tr -d '\n')
    local in_sid=$("$SINGBOX_BIN" generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

    local in_tag="${in_type}-in"

    # 构造入站 JSON
    local inbound_json="{\"type\":\"${in_type}\",\"tag\":\"${in_tag}\",\"listen\":\"::\",\"listen_port\":${lport}"
    case "$in_type" in
        vless)
            local in_pk=$(echo "$in_keys" | grep PrivateKey | awk '{print $NF}' | tr -d '\r')
            inbound_json="${inbound_json},\"users\":[{\"uuid\":\"${in_uuid}\",\"flow\":\"xtls-rprx-vision\"}],\"tls\":{\"enabled\":true,\"server_name\":\"addons.mozilla.org\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"addons.mozilla.org\",\"server_port\":443},\"private_key\":\"${in_pk}\",\"short_id\":[\"${in_sid}\"]}}}"
            local in_pub=$(echo "$in_keys" | grep PublicKey | awk '{print $NF}' | tr -d '\r')
            _ok "入口公钥: ${in_pub}  SID: ${in_sid}"
            ;;
        hysteria2)
            inbound_json="${inbound_json},\"users\":[{\"password\":\"${in_psk}\"}],\"tls\":{\"enabled\":true,\"alpn\":[\"h3\"],\"certificate_path\":\"/etc/sing-box/certs/fullchain.pem\",\"key_path\":\"/etc/sing-box/certs/privkey.pem\"}}"
            ;;
        tuic)
            in_uuid="${in_uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || _random_hex 16)}"
            inbound_json="${inbound_json},\"users\":[{\"uuid\":\"${in_uuid}\",\"password\":\"${in_psk}\"}],\"tls\":{\"enabled\":true,\"alpn\":[\"h3\"],\"certificate_path\":\"/etc/sing-box/certs/fullchain.pem\",\"key_path\":\"/etc/sing-box/certs/privkey.pem\"}}"
            ;;
        anytls)
            inbound_json="${inbound_json},\"users\":[{\"password\":\"${in_psk}\"}],\"tls\":{\"enabled\":true,\"alpn\":[\"http/1.1\"],\"certificate_path\":\"/etc/sing-box/certs/fullchain.pem\",\"key_path\":\"/etc/sing-box/certs/privkey.pem\"}}"
            ;;
    esac

    # 写入配置
    _manage_service "stop" 2>/dev/null || true
    sleep 1

    # 备份
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"

    # 合并入站 + 出站 + 路由规则
    local tmp_cfg=$(jq --argjson in "$(echo "$inbound_json" | jq .)" \
        --argjson out "$token_json" \
        '.inbounds += [$in] | .outbounds += [$out + {"tag":"'${rtag}'"}] |
         .route.rules += [{"inbound":"'${in_tag}'","outbound":"'${rtag}'"}]' \
        "$CONFIG_FILE" 2>/dev/null || echo "")

    if [ -z "$tmp_cfg" ] || [ "$tmp_cfg" = "null" ]; then
        _error "配置合并失败"
        _manage_service "start" 2>/dev/null || true
        read -p "按回车键返回..."
        return
    fi

    echo "$tmp_cfg" > "$CONFIG_FILE"

    # 保存中转元数据
    local entry="{\"local_port\":${lport},\"in_type\":\"${in_type}\",\"relay_tag\":\"${rtag}\",\"landing\":\"${rserver}:${rport}\",\"out_type\":\"${rtype}\"}"
    jq ". += [$entry]" "$RELAY_META" > "${RELAY_META}.tmp" && mv "${RELAY_META}.tmp" "$RELAY_META"

    # VLESS Reality 入口的公钥存入 metadata，供节点链接生成
    if [ "$in_type" = "vless" ] && [ -n "${in_pub:-}" ]; then
        [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
        local meta_pbk=$(jq -n --arg tag "${in_tag}" --arg pbk "${in_pub}" \
            '{($tag): {public_key: $pbk}}')
        _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_pbk" 2>/dev/null || true
    fi

    _manage_service "start" 2>/dev/null || true
    sleep 2

    _success "中转配置完成！入口端口: ${lport}"
    echo ""
    _info "中转流程: 用户 → 本机:${lport}(${in_type}) → ${rserver}:${rport}(${rtype})"
    echo ""
    read -p "按回车键返回..."
}

# ============================================================
# 4) 查看中转路由
# ============================================================

_relay_view_routes() {
    clear
    echo -e "${CYAN}=== 中转路由列表 ===${NC}"
    echo ""
    _relay_ensure

    local cnt=$(jq 'length' "$RELAY_META" 2>/dev/null || echo 0)
    [ "$cnt" -eq 0 ] && { _warn "暂无中转路由"; read -p "按回车键返回..."; return; }

    echo "  出口协议  →  落地             入口协议    本机端口"
    echo "  ─────────────────────────────────────────────────────"
    jq -r '.[] | "  \(.out_type)  →  \(.landing)  \(.in_type)  \(.local_port)"' "$RELAY_META"
    echo ""
    read -p "按回车键返回..."
}

# ============================================================
# 5) 删除中转路由
# ============================================================

_relay_delete_route() {
    clear
    echo -e "${CYAN}=== 删除中转路由 ===${NC}"
    echo ""
    _relay_ensure

    local cnt=$(jq 'length' "$RELAY_META" 2>/dev/null || echo 0)
    [ "$cnt" -eq 0 ] && { _warn "暂无中转路由"; read -p "按回车键返回..."; return; }

    local i=1
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        local lt=$(echo "$item" | jq -r '.local_port')
        local lb=$(echo "$item" | jq -r '.landing')
        echo -e "  ${GREEN}[$i]${NC} 端口${lt} → ${lb}"
        i=$((i + 1))
    done <<< "$(jq -c '.[]' "$RELAY_META")"

    echo ""
    echo -n "  选择要删除的（编号，0 返回）: "; read -r di
    [[ ! "$di" =~ ^[0-9]+$ ]] && return
    [ "$di" -eq 0 ] && return

    local idx=$((di-1))
    local entry=$(jq ".[$idx]" "$RELAY_META" 2>/dev/null)
    [ "$entry" = "null" ] && { _error "无效选择"; read -p "按回车键返回..."; return; }

    local del_tag=$(echo "$entry" | jq -r '.relay_tag')
    local del_port=$(echo "$entry" | jq -r '.local_port')
    local del_in_type=$(echo "$entry" | jq -r '.in_type')
    local in_tag="${del_in_type}-in"

    echo -ne "${RED}  确认删除? [y/N]: ${NC}"
    read -r confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return

    _manage_service "stop" 2>/dev/null || true
    sleep 1

    # 从配置中移除
    jq "del(.inbounds[] | select(.listen_port==${del_port} and (.type==\"${del_in_type}\")))" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq "del(.outbounds[] | select(.tag==\"${del_tag}\"))" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    jq "del(.route.rules[] | select(.inbound==\"${in_tag}\"))" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 清理元数据
    jq "del(.[$idx])" "$RELAY_META" > "${RELAY_META}.tmp" && mv "${RELAY_META}.tmp" "$RELAY_META"

    _manage_service "start" 2>/dev/null || true
    _success "中转路由已删除"
    read -p "按回车键返回..."
}

# ============================================================
# 端口转发管理
# ============================================================

_pf_ensure() { mkdir -p "$RELAY_CONFIG_DIR"; [ -f "$PF_META" ] || echo '{}' > "$PF_META"; }
_pf_count() { _pf_ensure; jq 'length' "$PF_META" 2>/dev/null || echo 0; }

# 安装开机自动恢复 iptables 规则的 service
_pf_install_restore_service() {
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if [ ! -f /etc/local.d/iptables-restore.start ]; then
            mkdir -p /etc/local.d
            cat > /etc/local.d/iptables-restore.start <<'ALPINE_RESTORE'
#!/bin/sh
[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
ALPINE_RESTORE
            chmod +x /etc/local.d/iptables-restore.start
            rc-update add local default 2>/dev/null || true
        fi
    else
        if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
            cat > /etc/systemd/system/iptables-restore.service <<'SYSTEMD_RESTORE'
[Unit]
Description=Restore iptables rules (sing-box port forwarding)
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables-restore < /etc/iptables/rules.v4'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD_RESTORE
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable iptables-restore 2>/dev/null || true
        fi
    fi
}

_pf_is_kvm() {
    if command -v systemd-detect-virt &>/dev/null; then
        local v=$(systemd-detect-virt 2>/dev/null)
        [ "$v" = "kvm" ] || [ "$v" = "qemu" ] || [ "$v" = "vmware" ] && return 0
    fi
    return 1
}

_relay_port_forward_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 端口转发管理 (iptables) ===${NC}"
        echo ""
        _pf_ensure
        local count=$(_pf_count)
        echo -e "  转发规则数: ${GREEN}${count}${NC}"
        echo -e "  KVM 检测: $(_pf_is_kvm && echo "是 ✅" || echo "否（将尝试 iptables）")"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 添加转发规则"
        echo -e "    ${GREEN}[2]${NC} 查看转发规则"
        echo -e "    ${GREEN}[3]${NC} 删除转发规则"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-3]: " opt
        case "$opt" in
            1)
                echo ""
                echo -n "  监听端口: "; read -r lport
                [ -z "$lport" ] && { _warn "端口不能为空"; sleep 1; continue; }
                [[ ! "$lport" =~ ^[0-9]+$ ]] && { _warn "无效端口"; sleep 1; continue; }

                echo -n "  目标 IP/域名: "; read -r target
                [ -z "$target" ] && { _warn "目标不能为空"; sleep 1; continue; }

                echo -n "  目标端口: "; read -r tport
                [ -z "$tport" ] && { _warn "端口不能为空"; sleep 1; continue; }
                [[ ! "$tport" =~ ^[0-9]+$ ]] && { _warn "无效端口"; sleep 1; continue; }

                echo "  协议: 1) TCP  2) UDP  3) TCP+UDP"
                echo -n "  选择（默认 3）: "; read -r proto_in
                proto_in="${proto_in:-3}"

                local proto_flag=""
                case "$proto_in" in
                    1) proto_flag="tcp" ;;
                    2) proto_flag="udp" ;;
                    *) proto_flag="tcp+udp" ;;
                esac

                # 检查端口冲突
                local clashing=$(jq --arg p "$lport" '.[$p]' "$PF_META" 2>/dev/null)
                [ "$clashing" != "null" ] && { _warn "端口 $lport 已存在转发规则"; sleep 1; continue; }

                # 应用 iptables 规则
                echo ""
                _info "正在添加 ${lport} → ${target}:${tport} (${proto_flag})..."
                if command -v iptables &>/dev/null; then
                    case "$proto_flag" in
                        tcp|tcp+udp)
                            iptables -t nat -A PREROUTING -p tcp --dport "$lport" -j DNAT --to-destination "${target}:${tport}" 2>/dev/null || true
                            iptables -A FORWARD -p tcp -d "$target" --dport "$tport" -j ACCEPT 2>/dev/null || true
                            ;;
                    esac
                    case "$proto_flag" in
                        udp|tcp+udp)
                            iptables -t nat -A PREROUTING -p udp --dport "$lport" -j DNAT --to-destination "${target}:${tport}" 2>/dev/null || true
                            iptables -A FORWARD -p udp -d "$target" --dport "$tport" -j ACCEPT 2>/dev/null || true
                            ;;
                    esac

                    # 启用 IP 转发
                    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

                    # 持久化规则
                    if command -v iptables-save &>/dev/null; then
                        mkdir -p /etc/iptables
                        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                    fi

                    _success "iptables 转发规则已添加"
                else
                    _warn "iptables 不可用，本机可能不支持端口转发"
                    sleep 1
                    continue
                fi

                # 保存元数据
                local rule="{\"target\":\"${target}\",\"tport\":${tport},\"proto\":\"${proto_flag}\",\"engine\":\"iptables\"}"
                jq --arg p "$lport" --argjson r "$rule" '.[$p]=$r' "$PF_META" > "${PF_META}.tmp" && mv "${PF_META}.tmp" "$PF_META"

                _pf_install_restore_service
                _success "规则已保存（已设置开机自动恢复）"
                echo ""
                read -p "按回车键继续..."
                ;;

            2)
                local cnt=$(_pf_count)
                if [ "$cnt" -eq 0 ]; then
                    _warn "暂无转发规则"
                else
                    echo ""
                    echo "  端口  →  目标                  协议      引擎"
                    echo "  ─────────────────────────────────────────────"
                    jq -r 'to_entries[] | "  \(.key)  →  \(.value.target):\(.value.tport)  \(.value.proto)  \(.value.engine)"' "$PF_META" 2>/dev/null
                fi
                echo ""
                read -p "按回车键返回..."
                ;;

            3)
                local cnt=$(_pf_count)
                [ "$cnt" -eq 0 ] && { _warn "暂无转发规则"; sleep 1; continue; }

                echo -n "  输入要删除的监听端口: "; read -r del_port
                [ -z "$del_port" ] && continue

                local rule=$(jq --arg p "$del_port" '.[$p]' "$PF_META" 2>/dev/null)
                [ "$rule" = "null" ] && { _warn "端口 ${del_port} 不存在"; sleep 1; continue; }

                # 删除 iptables 规则
                local rproto=$(echo "$rule" | jq -r '.proto // "tcp+udp"')
                local rtarget=$(echo "$rule" | jq -r '.target')
                local rtport=$(echo "$rule" | jq -r '.tport')

                case "$rproto" in
                    tcp|tcp+udp)
                        iptables -t nat -D PREROUTING -p tcp --dport "$del_port" -j DNAT --to-destination "${rtarget}:${rtport}" 2>/dev/null || true
                        iptables -D FORWARD -p tcp -d "$rtarget" --dport "$rtport" -j ACCEPT 2>/dev/null || true
                        ;;
                esac
                case "$rproto" in
                    udp|tcp+udp)
                        iptables -t nat -D PREROUTING -p udp --dport "$del_port" -j DNAT --to-destination "${rtarget}:${rtport}" 2>/dev/null || true
                        iptables -D FORWARD -p udp -d "$rtarget" --dport "$rtport" -j ACCEPT 2>/dev/null || true
                        ;;
                esac

                # 持久化
                if command -v iptables-save &>/dev/null; then
                    mkdir -p /etc/iptables
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                fi

                jq "del(.[\"${del_port}\"])" "$PF_META" > "${PF_META}.tmp" && mv "${PF_META}.tmp" "$PF_META"
                _success "规则已删除"
                read -p "按回车键返回..."
                ;;

            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 状态查看 (供 ui.sh 调用)
# ============================================================

_relay_status() {
    _relay_ensure
    local relay_cnt=$(jq 'length' "$RELAY_META" 2>/dev/null || echo 0)
    local pf_cnt=$(_pf_count)
    echo "中转路由: ${relay_cnt} 条"
    echo "端口转发: ${pf_cnt} 条"
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro 中转模块 v${RELAY_MOD_VERSION} ==="
    echo ""
    _relay_status
fi
