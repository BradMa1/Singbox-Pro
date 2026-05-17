#!/bin/bash
# ============================================================
# ui.sh — Singbox-Pro 可视化菜单模块
# 所有菜单、面板、状态显示集中管理
# ============================================================
export UI_MOD_VERSION="2.0.0"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

SCRIPT_VERSION="${SCRIPT_VERSION:-2.0.0}"

# ============================================================
# 顶部横幅
# ============================================================

_ui_banner() {
    clear
    echo -e "${CYAN}"
    echo '  ╔════════════════════════════════════════════════╗'
    echo '  ║     ███████╗ ██████╗                                ║'
    echo '  ║     ██╔════╝ ██╔══██╗      Singbox-Pro            ║'
    echo '  ║     ███████╗ ██████╔╝      v'"${SCRIPT_VERSION}"'                      ║'
    echo '  ║     ╚════██║ ██╔══██╗                              ║'
    echo '  ║     ███████║ ██████╔╝      Multi-Protocol Proxy   ║'
    echo '  ║     ╚══════╝ ╚═════╝                               ║'
    echo '  ╚════════════════════════════════════════════════╝'
    echo -e "${NC}"
    echo ""
}

# ============================================================
# 状态面板
# ============================================================

_ui_status_panel() {
    local os_info=$(_get_os_info)
    local sb_ver=$(_sb_get_version)
    local sb_status=$(_sb_get_status)
    local argo_status=$(_argo_get_status)
    local warp_status=$(_warp_get_status)
    local node_count=$(_sb_get_inbound_count)

    # VPS 硬件信息
    local host=$(hostname 2>/dev/null || echo "unknown")
    local cpu=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/  */ /g' | xargs | cut -c1-25 || echo "?")
    local mem=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}' || echo "?")
    local disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' || echo "?")
    local region=$(_get_region)
    local ip=$(_get_public_ip)
    local ipv6=$(_get_ipv6)

    echo -e "  地区: ${YELLOW}${region}${NC}"
    echo -e "  ${host} | ${os_info} | ${cpu} | 内存 ${mem} | 磁盘 ${disk}"
    echo -e "  IPv4: ${GREEN}${ip}${NC}    IPv6: ${GREEN}${ipv6}${NC}"
    echo ""
    echo -e "  ${CYAN}Sing-box:${NC} v${sb_ver}  ${sb_status}  节点: ${node_count}"
    echo -e "  ${CYAN}Argo:${NC} ${argo_status}  ${CYAN}WARP:${NC} ${warp_status}"
    echo ""
}

# ============================================================
# 主菜单
# ============================================================

_ui_main_menu() {
    while true; do
        _ui_banner
        _ui_status_panel

        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "    ${GREEN}[1]${NC} 添加节点          ${GREEN}[2]${NC} Argo 隧道节点"
        echo -e "    ${GREEN}[3]${NC} 查看节点链接      ${GREEN}[4]${NC} 删除节点"
        echo -e "    ${GREEN}[5]${NC} 修改节点"
        echo ""

        echo -e "  ${CYAN}【服务控制】${NC}"
        echo -e "    ${GREEN}[6]${NC} 重启服务          ${GREEN}[7]${NC} 停止服务"
        echo ""

        echo -e "  ${CYAN}【进阶功能】${NC}"
        echo -e "    ${GREEN}[8]${NC} 中转管理          ${GREEN}[9]${NC} WARP 管理"
        echo ""

        echo -e "  ${CYAN}【系统维护】${NC}"
        echo -e "    ${GREEN}[10]${NC} 安装/更新核心    ${RED}[11]${NC} 卸载脚本"
        echo ""

        echo -e "  ─────────────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 退出脚本"
        echo ""

        read -p "  请输入选项 [0-11]: " choice

        case $choice in
            1) _ui_add_node_menu ;;
            2) _ui_argo_menu ;;
            3) _ui_view_nodes ;;
            4) _ui_delete_node ;;
            5) _ui_modify_node ;;
            6) _ui_restart_service ;;
            7) _ui_stop_service ;;
            8) _ui_relay_menu ;;
            9) _ui_warp_menu ;;
            10) _ui_update_core ;;
            11) _ui_uninstall ;;
            0) echo "再见!"; exit 0 ;;
            *) _warn "无效选项，请重试"; sleep 1 ;;
        esac
    done
}

# ============================================================
# VPS 状态面板
# ============================================================

_ui_vps_panel() {
    clear
    echo -e "${CYAN}=== VPS 系统状态 ===${NC}"
    echo ""

    # CPU / 内存
    echo -e "${CYAN}【系统资源】${NC}"
    echo -e "  主机名: $(hostname)"
    echo -e "  系统: $(_get_os_info)"
    echo -e "  内核: $(uname -r)"
    echo -e "  运行时间: $(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk -F'up' '{print $2}' | cut -d',' -f1)"
    echo -e "  CPU: $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | xargs || echo '未知')"
    echo -e "  内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}' || echo '未知')"
    echo -e "  磁盘: $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}' || echo '未知')"
    echo ""

    # 网络
    echo -e "${CYAN}【网络】${NC}"
    echo -e "  公网 IPv4: $(_get_public_ip)"
    local ipv6=$(timeout 3 curl -s6 ifconfig.me 2>/dev/null || echo '无')
    echo -e "  公网 IPv6: ${ipv6}"
    echo ""

    # 端口监听
    echo -e "${CYAN}【端口监听】${NC}"
    echo -e "  TCP:"
    ss -tlnp 2>/dev/null | grep -v "127.0.0.1" | awk 'NR>1{printf "    :%-8s %s\n", $4, $NF}' | sed 's/.*://' | head -20 || echo "    无"
    echo -e "  UDP:"
    ss -ulnp 2>/dev/null | awk 'NR>1{printf "    :%-8s %s\n", $5, $NF}' | sed 's/.*://' | head -10 || echo "    无"
    echo ""

    # Sing-box 信息
    echo -e "${CYAN}【Sing-box】${NC}"
    echo -e "  版本: v$(_sb_get_version)"
    echo -e "  状态: $(_sb_get_status)"
    echo -e "  节点: $(_sb_get_inbound_count) 个"
    echo ""

    # 防火墙提示
    echo -e "${YELLOW}【防火墙提示】${NC}"
    echo -e "  如果节点不通，请检查 VPS 面板防火墙是否放行对应端口"
    echo -e "  iptables: iptables -L INPUT -n --line-numbers"
    echo ""

    read -p "按回车键返回..."
}

# ============================================================
# 添加节点菜单
# ============================================================

_ui_add_node_menu() {
    _require_singbox || return 1

    # ===== Step 1: 选择协议 =====
    clear
    echo -e "${CYAN}=== 添加节点 ===${NC}"
    echo ""
    echo -e "  ${CYAN}请选择协议类型:${NC}"
    echo ""
    echo -e "    ${GREEN}[1]${NC} VLESS Reality    (TLS + Reality, 抗封锁)"
    echo -e "    ${GREEN}[2]${NC} AnyTLS            (轻量 TLS)"
    echo -e "    ${GREEN}[3]${NC} TUIC V5           (UDP + BBR 加速)"
    echo -e "    ${GREEN}[4]${NC} Hysteria2        (QUIC, 低延迟)"
    echo -e "    ${GREEN}[5]${NC} VMess WebSocket   (兼容性强)"
    echo ""
    echo -e "  ${YELLOW}提示: 支持多选，用空格分隔 (如 1 3 5)，直接回车 = 全选${NC}"
    echo -e "    ${YELLOW}[0]${NC} 返回"
    echo ""

    read -r -p "  请输入选项 [0-5]: " proto_choice
    proto_choice=$(echo "$proto_choice" | xargs 2>/dev/null)
    [ -z "$proto_choice" ] && proto_choice="1 2 3 4 5"

    local selected=()
    for ch in $proto_choice; do
        case $ch in
            1|2|3|4|5) selected+=("$ch") ;;
            0) return ;;
            *) _warn "无效选项: $ch，跳过"; sleep 1 ;;
        esac
    done
    [ ${#selected[@]} -eq 0 ] && return

    # ===== 证书预生成 (AnyTLS/TUIC/Hy2 需要) =====
    local need_cert=false
    for ch in "${selected[@]}"; do
        case $ch in 2|3|4) need_cert=true; break ;; esac
    done
    if $need_cert; then
        _proto_generate_cert || { read -p "按回车键返回..."; return; }
    fi

    # ===== Step 2: 收集各协议端口 =====
    clear
    echo -e "${CYAN}=== 配置端口 ===${NC}"
    echo ""

    declare -A proto_names
    proto_names[1]="VLESS Reality"
    proto_names[2]="AnyTLS"
    proto_names[3]="TUIC V5"
    proto_names[4]="Hysteria2"
    proto_names[5]="VMess WebSocket"

    declare -A ports
    for ch in "${selected[@]}"; do
        local p=$(_random_port)
        echo -ne "  ${proto_names[$ch]} 端口 (默认随机 ${p}): "
        read -r input_port
        p=${input_port:-$p}
        ports[$ch]=$p
    done

    # ===== Step 3: 一次输入名称前缀 =====
    echo ""
    read -p "  节点名称前缀 (如 jp, 回车使用默认名称): " name_prefix
    name_prefix=$(echo "$name_prefix" | xargs 2>/dev/null)

    # 清理名称: 空格→连字符，去掉特殊符号 (括号/引号等)，保留中文/字母/数字/连字符/下划线
    if [ -n "$name_prefix" ]; then
        local original="$name_prefix"
        # 先替换空格为连字符，再删除危险字符
        name_prefix=$(echo "$name_prefix" | sed -E 's/[[:space:]]+/-/g; s/[][(){}<>"'"'"'`$|&;!#\\]//g; s/^-+|-+$//g')
        [ "$name_prefix" != "$original" ] && _warn "名称已自动清理: $original → $name_prefix"
    fi
    echo ""

    # ===== Step 4: 批量生成配置 (不重启) =====

    # 批次内端口去重检查
    declare -A port_seen
    local dup_found=false
    for ch in "${selected[@]}"; do
        local p="${ports[$ch]}"
        if [ -n "${port_seen[$p]:-}" ]; then
            _error "端口 ${p} 在批次内重复! 请重新输入不同端口"
            dup_found=true
        fi
        port_seen[$p]=1
    done
    if $dup_found; then
        echo ""
        read -p "按回车键返回..."
        return
    fi

    _info "正在生成配置..."
    echo ""

    local result_lines=()
    for ch in "${selected[@]}"; do
        local port="${ports[$ch]}"
        local result

        case $ch in
            1) result=$(_ui_add_reality_quick "$port" "$name_prefix") ;;
            2) result=$(_ui_add_anytls_quick   "$port" "$name_prefix") ;;
            3) result=$(_ui_add_tuic_quick     "$port" "$name_prefix") ;;
            4) result=$(_ui_add_hy2_quick      "$port" "$name_prefix") ;;
            5) result=$(_ui_add_vmess_ws_quick "$port" "$name_prefix") ;;
        esac

        [ -n "$result" ] && result_lines+=("$result")
    done

    [ ${#result_lines[@]} -eq 0 ] && { _error "所有协议添加失败"; read -p "按回车键返回..."; return; }

    # ===== Step 5: 一次性重启 =====
    _sb_restart_and_verify || { _warn "服务可能未正常启动，请检查日志"; }

    # ===== Step 6: 统一展示所有链接 =====
    echo ""
    _success "全部节点添加完成!"
    echo ""
    echo -e "${CYAN}=== 节点链接 ===${NC}"
    echo ""

    local server_ip=$(_get_public_ip)

    for line in "${result_lines[@]}"; do
        IFS='|' read -r proto name port uuid sni sid password ws_path <<< "$line"

        case $proto in
            reality)
                local pbk="${ws_path}"
                local uri=$(_proto_reality_uri "$uuid" "$server_ip" "$port" "$sni" "$sid" "$name" "" "$pbk")
                echo -e "  ${GREEN}● ${name}${NC} (VLESS Reality)"
                echo -e "    端口: ${port}  域名: ${sni}  SID: ${sid}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo ""
                ;;
            anytls)
                local uri=$(_proto_anytls_uri "$password" "$server_ip" "$port" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (AnyTLS)"
                echo -e "    端口: ${port}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo ""
                ;;
            tuic)
                local uri=$(_proto_tuic_uri "$uuid" "$password" "$server_ip" "$port" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (TUIC V5)"
                echo -e "    端口: ${port}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo ""
                ;;
            hy2)
                local uri=$(_proto_hy2_uri "$password" "$server_ip" "$port" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (Hysteria2)"
                echo -e "    端口: ${port}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo ""
                ;;
            vmess)
                local uri=$(_proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (VMess WS)"
                echo -e "    端口: ${port}  路径: ${ws_path}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo ""
                ;;
        esac
    done

    read -p "按回车键返回..."
}

# ============================================================
# 批量快速添加 (被 _ui_add_node_menu 调用，不交互不重启)
# 返回: pipe-delimited info 字符串供统一展示
# ============================================================

_ui_add_reality_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 Reality"
        return 1
    fi

    local uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
    local sni="${DEFAULT_SNI}"
    local short_id=$(openssl rand -hex 8 2>/dev/null || _random_hex 8)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-vless-reality" || name="VLESS-Reality-${port}"

    local inbound_json=$(_proto_reality_config "$port" "$uuid" "$sni" "$short_id" "xtls-rprx-vision" "")
    local pbk="$_REALITY_PUBKEY"
    _proto_add_inbound "$inbound_json" || return 1

    local meta_json=$(jq -n \
        --arg tag "vless-reality-${port}" \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg sid "$short_id" \
        --arg pbk "${pbk}" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "reality", uuid: $uuid, sni: $sni, short_id: $sid, public_key: $pbk, port: ($port|tonumber), created_at: $created}}')

    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

    echo "reality|${name}|${port}|${uuid}|${sni}|${short_id}||${pbk}|"
}

_ui_add_anytls_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 AnyTLS"
        return 1
    fi

    local password=$(_random_hex 16)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-anytls" || name="AnyTLS-${port}"

    local inbound_json=$(_proto_anytls_config "$port" "$password")
    _proto_add_inbound "$inbound_json" || return 1

    echo "anytls|${name}|${port}||||${password}||"
}

_ui_add_tuic_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "udp"; then
        _error "端口 ${port} 已被占用，跳过 TUIC"
        return 1
    fi

    local uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
    local password=$(_random_hex 16)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-tuic" || name="TUIC-${port}"

    local inbound_json=$(_proto_tuic_config "$port" "$uuid" "$password")
    _proto_add_inbound "$inbound_json" || return 1

    echo "tuic|${name}|${port}|${uuid}|||${password}|"
}

_ui_add_hy2_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "udp"; then
        _error "端口 ${port} 已被占用，跳过 Hysteria2"
        return 1
    fi

    local password=$(_random_hex 16)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-hy2" || name="Hy2-${port}"

    local inbound_json=$(_proto_hy2_config "$port" "$password")
    _proto_add_inbound "$inbound_json" || return 1

    echo "hy2|${name}|${port}||||${password}||"
}

_ui_add_vmess_ws_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 VMess"
        return 1
    fi

    local uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
    local ws_path="/$(_random_hex 8)"

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-vmess-ws" || name="VMess-WS-${port}"

    local inbound_json=$(_proto_vmess_ws_config "$port" "$uuid" "$ws_path")
    _proto_add_inbound "$inbound_json" || return 1

    echo "vmess|${name}|${port}|${uuid}||||${ws_path}"
}

# ============================================================
# Argo 隧道菜单
# ============================================================

_ui_argo_menu() {
    _require_singbox || return 1

    while true; do
        clear
        echo -e "${CYAN}=== Argo Cloudflare 隧道管理 ===${NC}"
        echo ""
        echo -e "  Argo 隧道通过 Cloudflare 网络中转流量，无需自有域名即可使用"
        echo -e "  临时隧道: 免费、自动分配域名、但重启后域名会变"
        echo -e "  固定隧道: 需 Cloudflare 账号 + Tunnel Token、域名固定不变"
        echo ""

        echo -e "  状态: $(_argo_get_status)"
        echo -e "  节点: $(_argo_count) 个"
        echo ""
        echo -e "  ${GREEN}【临时隧道 — 无需域名，一键使用】${NC}"
        echo -e "    ${GREEN}[1]${NC} 添加临时隧道 (VLESS + WS)"
        echo ""
        echo -e "  ${GREEN}【固定隧道 — 需要 Cloudflare 账号】${NC}"
        echo -e "    ${GREEN}[2]${NC} 添加固定隧道 (需 Token)"
        echo ""
        echo -e "  ${GREEN}【管理】${NC}"
        echo -e "    ${GREEN}[3]${NC} 查看 Argo 节点链接"
        echo -e "    ${GREEN}[4]${NC} 删除 Argo 节点"
        echo -e "    ${GREEN}[5]${NC} 查看隧道日志"
        echo -e "    ${GREEN}[6]${NC} 停止所有隧道"
        echo -e "    ${GREEN}[7]${NC} 安装/更新 cloudflared"
        echo -e "    ${GREEN}[8]${NC} 临时隧道转固定隧道"
        echo ""
        echo -e "  ${YELLOW}【获取固定隧道 Token】${NC}"
        echo -e "    1. 访问 https://one.dash.cloudflare.com/"
        echo -e "    2. Zero Trust → Networks → Tunnels → Create a tunnel"
        echo -e "    3. 选择 Cloudflared → 复制 Tunnel Token"
        echo -e "    4. 配置 Public Hostname → http://localhost:端口"
        echo ""

        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-8]: " argo_choice

        case $argo_choice in
            1) _ui_argo_add_temp ;;
            2) _ui_argo_add_fixed ;;
            3) _ui_argo_view_nodes ;;
            4) _ui_argo_delete ;;
            5) _ui_argo_view_log ;;
            6) _argo_stop_all && read -p "按回车键返回..." ;;
            7) _argo_install && read -p "按回车键返回..." ;;
            8) _ui_argo_temp_to_fixed ;;
            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

_ui_argo_add_temp() {
    clear
    echo -e "${CYAN}=== 添加 Argo 临时隧道 (VLESS + WS) ===${NC}"
    echo ""

    _argo_install || { read -p "按回车键返回..."; return; }

    local port=$(_random_port)
    read -p "本地监听端口 (默认随机: ${port}): " input_port
    port=${input_port:-$port}

    local uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
    local ws_path="/$(_random_hex 8)"

    local default_name="Argo-Temp-VLESS-${port}"
    read -p "节点名称 (默认: ${default_name}): " input_name
    local name=${input_name:-$default_name}

    # 创建 VLESS + WS inbound
    local tag="argo-vless-ws-${port}"
    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg u "$uuid" \
        --arg wsp "$ws_path" \
        '{
            "type": "vless",
            "tag": $t,
            "listen": "127.0.0.1",
            "listen_port": ($p|tonumber),
            "users": [{"uuid": $u, "flow": ""}],
            "transport": {"type": "ws", "path": $wsp}
        }')

    _proto_add_inbound "$inbound_json" || { read -p "按回车键返回..."; return; }
    _sb_restart_and_verify

    _info "正在启动临时隧道..."
    local domain=$(_argo_start_temp "$port" "vless-ws")

    if [ -z "$domain" ]; then
        _error "隧道启动失败，正在回滚..."
        _proto_remove_inbound "$tag"
        _manage_service "restart"
        read -p "按回车键返回..."
        return
    fi

    _argo_save_metadata "$tag" "$name" "$domain" "$port" "uuid" "$uuid" "$ws_path" "vless-ws" "temp"

    echo ""
    _success "Argo 临时隧道节点添加完成!"
    local uri="vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&path=$(_url_encode "$ws_path")&host=${domain}#$(_url_encode "$name")"
    echo -e "  ${CYAN}域名:${NC} ${domain}"
    echo -e "  ${CYAN}分享链接:${NC}"
    echo -e "  ${GREEN}${uri}${NC}"
    echo ""
    echo -e "  ${YELLOW}注意: 临时隧道重启后域名会变化${NC}"
    echo ""

    read -p "按回车键返回..."
}

_ui_argo_add_fixed() {
    clear
    echo -e "${CYAN}=== 添加 Argo 固定隧道 ===${NC}"
    echo ""

    _argo_install || { read -p "按回车键返回..."; return; }

    echo -e "请粘贴 Cloudflare Tunnel Token:"
    read -p "Token: " input_token
    local token=$(_argo_extract_token "$input_token")
    if [ -z "$token" ]; then
        _error "Token 无效"
        read -p "按回车键返回..."
        return
    fi
    _info "Token: ${token:0:20}..."

    read -p "绑定的域名 (如 tunnel.example.com): " tunnel_domain
    [ -z "$tunnel_domain" ] && { _error "域名不能为空"; read -p "按回车键返回..."; return; }

    local port=$(_random_port)
    read -p "本地监听端口 (默认随机: ${port}): " input_port
    port=${input_port:-$port}

    local uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || _random_hex 16)
    local ws_path="/$(_random_hex 8)"

    local default_name="Argo-Fixed-${port}"
    read -p "节点名称 (默认: ${default_name}): " input_name
    local name=${input_name:-$default_name}

    local tag="argo-vless-ws-${port}"
    local inbound_json=$(jq -n \
        --arg t "$tag" \
        --arg p "$port" \
        --arg u "$uuid" \
        --arg wsp "$ws_path" \
        '{
            "type": "vless",
            "tag": $t,
            "listen": "127.0.0.1",
            "listen_port": ($p|tonumber),
            "users": [{"uuid": $u, "flow": ""}],
            "transport": {"type": "ws", "path": $wsp}
        }')

    _proto_add_inbound "$inbound_json" || { read -p "按回车键返回..."; return; }
    _sb_restart_and_verify

    echo ""
    _info "请确认已在 Cloudflare Dashboard 配置:"
    _info "  Public Hostname: ${tunnel_domain}"
    _info "  Service: http://localhost:${port}"
    echo ""
    read -p "确认无误后按回车键继续..."

    _argo_start_fixed "$port" "$token" || {
        _proto_remove_inbound "$tag"
        _manage_service "restart"
        read -p "按回车键返回..."
        return
    }

    _argo_save_metadata "$tag" "$name" "$tunnel_domain" "$port" "uuid" "$uuid" "$ws_path" "vless-ws" "fixed" "$token"

    echo ""
    _success "Argo 固定隧道节点添加完成!"
    local uri="vless://${uuid}@${tunnel_domain}:443?encryption=none&security=tls&sni=${tunnel_domain}&type=ws&path=$(_url_encode "$ws_path")&host=${tunnel_domain}#$(_url_encode "$name")"
    echo -e "  ${CYAN}分享链接:${NC}"
    echo -e "  ${GREEN}${uri}${NC}"
    echo ""

    read -p "按回车键返回..."
}

_ui_argo_view_nodes() {
    clear
    echo -e "${CYAN}=== Argo 节点列表 ===${NC}"
    echo ""

    [ ! -f "$ARGO_METADATA_FILE" ] || [ "$(jq 'length' "$ARGO_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ] && {
        echo "  暂无 Argo 节点"
        echo ""
        read -p "按回车键返回..."
        return
    }

    local count=0
    jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.domain)|\(.value.local_port)|\(.value.protocol)|\(.value.type)"' \
        "$ARGO_METADATA_FILE" 2>/dev/null | while IFS='|' read -r tag name domain port proto atype; do
        count=$((count + 1))

        local cred_val=""
        if jq -e ".\"$tag\".uuid" "$ARGO_METADATA_FILE" >/dev/null 2>&1; then
            cred_val=$(jq -r ".\"$tag\".uuid" "$ARGO_METADATA_FILE")
        else
            cred_val=$(jq -r ".\"$tag\".password" "$ARGO_METADATA_FILE" 2>/dev/null || echo "")
        fi

        local path=$(jq -r ".\"$tag\".path // \"/\"" "$ARGO_METADATA_FILE")
        local uri="vless://${cred_val}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&path=$(_url_encode "$path")&host=${domain}#$(_url_encode "$name")"

        echo -e "  ${GREEN}[${count}]${NC} ${name}"
        echo -e "      域名: ${domain}"
        echo -e "      模式: ${atype}"
        echo -e "      链接: ${GREEN}${uri}${NC}"
        echo ""
    done

    read -p "按回车键返回..."
}

_ui_argo_delete() {
    clear
    echo -e "${CYAN}=== 删除 Argo 节点 ===${NC}"
    echo ""

    local tags=()
    while IFS='|' read -r tag name domain port proto atype; do
        [ -z "$tag" ] && continue
        tags+=("$tag")
        local idx=${#tags[@]}
        echo -e "  ${GREEN}[${idx}]${NC} ${name} (${domain})"
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.domain)|\(.value.local_port)|\(.value.protocol)|\(.value.type)"' "$ARGO_METADATA_FILE" 2>/dev/null)

    [ ${#tags[@]} -eq 0 ] && { echo "无 Argo 节点"; read -p "按回车键返回..."; return; }

    echo ""
    read -p "选择要删除的节点 [1-${#tags[@]}] (0 返回): " del_choice

    [[ ! "$del_choice" =~ ^[0-9]+$ ]] && return
    [ "$del_choice" -eq 0 ] && return
    [ "$del_choice" -lt 1 ] || [ "$del_choice" -gt ${#tags[@]} ] && { _warn "无效选择"; sleep 1; return; }

    local sel_tag="${tags[$((del_choice - 1))]}"
    local sel_port=$(jq -r ".\"$sel_tag\".local_port" "$ARGO_METADATA_FILE")

    # 停止隧道
    _argo_stop "$sel_port"

    # 删除入站
    _proto_remove_inbound "$sel_tag"
    _argo_remove_metadata "$sel_tag"
    _manage_service "restart"

    _success "Argo 节点已删除"
    read -p "按回车键返回..."
}

_ui_argo_view_log() {
    clear
    _argo_view_log
    echo ""
    read -p "按回车键返回..."
}

_ui_argo_temp_to_fixed() {
    clear
    echo -e "${CYAN}=== 临时隧道转固定隧道 ===${NC}"
    echo ""

    # 列出临时隧道
    local temp_nodes=$(jq -r 'to_entries[] | select(.value.type == "temp") | "\(.key)|\(.value.name)|\(.value.local_port)"' "$ARGO_METADATA_FILE" 2>/dev/null)

    if [ -z "$temp_nodes" ]; then
        echo "  无临时隧道节点"
        read -p "按回车键返回..."
        return
    fi

    echo "$temp_nodes" | while IFS='|' read -r tag name port; do
        echo -e "  ${GREEN}●${NC} ${name} (端口 ${port})"
    done
    echo ""

    read -p "输入要转换的节点端口号: " convert_port
    local convert_tag=$(jq -r "to_entries[] | select(.value.local_port == ${convert_port} and .value.type == \"temp\") | .key" "$ARGO_METADATA_FILE" 2>/dev/null)

    [ -z "$convert_tag" ] && { _warn "未找到该端口的临时隧道"; read -p "按回车键返回..."; return; }

    echo -e "请粘贴 Cloudflare Tunnel Token:"
    read -p "Token: " input_token
    local token=$(_argo_extract_token "$input_token")
    [ -z "$token" ] && { _error "Token 无效"; read -p "按回车键返回..."; return; }

    read -p "绑定的域名: " tunnel_domain
    [ -z "$tunnel_domain" ] && { _error "域名不能为空"; read -p "按回车键返回..."; return; }

    # 停止旧临时隧道
    _argo_stop "$convert_port"

    # 启动固定隧道
    _argo_start_fixed "$convert_port" "$token" || { read -p "按回车键返回..."; return; }

    # 更新元数据
    _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$convert_tag\".type = \"fixed\" | .\"$convert_tag\".domain = \"$tunnel_domain\" | .\"$convert_tag\".token = \"$token\""

    _success "临时隧道已转换为固定隧道: ${tunnel_domain}"
    read -p "按回车键返回..."
}

# ============================================================
# WARP 管理菜单
# ============================================================

_ui_warp_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== WARP SOCKS5 管理 ===${NC}"
        echo ""
        echo -e "  WARP 用于解锁 ChatGPT/Claude/Gemini 等 AI 服务的流媒体限制"
        echo -e "  原理: 通过 Cloudflare WARP 的 SOCKS5 代理出口"
        echo -e "  使用: 安装 → 启动 → 添加到出站 → 重启 sing-box"
        echo ""

        echo -e "  状态: $(_warp_get_status)"
        echo ""

        echo -e "    ${GREEN}[1]${NC} 安装 WARP          (下载并安装 warp-plus)"
        echo -e "    ${GREEN}[2]${NC} 启动 WARP          (启动 SOCKS5 代理在 127.0.0.1:${WARP_SOCKS_PORT})"
        echo -e "    ${GREEN}[3]${NC} 停止 WARP"
        echo -e "    ${GREEN}[4]${NC} 添加到 sing-box     (将 WARP 加入 proxy 选择器)"
        echo -e "    ${RED}[5]${NC} 卸载 WARP"
        echo ""
        echo -e "  ${YELLOW}【自定义分流域名】${NC}"
        echo -e "    默认分流: openai, gemini, claude, bard, copilot"
        echo -e "    如需自定义，在安装后会提示输入额外域名"
        echo ""

        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-5]: " warp_choice

        case $warp_choice in
            1)
                _warp_install || { read -p "按回车键返回..."; continue; }
                echo ""
                _info "WARP 安装完成。下一步: [2] 启动 → [4] 添加到出站"
                read -p "按回车键返回..."
                ;;
            2)
                _warp_start || { read -p "按回车键返回..."; continue; }
                echo ""
                _info "WARP 已启动。下一步: [4] 添加到 sing-box 出站"
                read -p "按回车键返回..."
                ;;
            3) _warp_stop 2>/dev/null; read -p "按回车键返回..." ;;
            4)
                _warp_add_outbound 2>/dev/null || { _error "添加失败"; read -p "按回车键返回..."; continue; }
                _manage_service restart 2>/dev/null
                echo ""
                _info "WARP 已添加到 proxy 选择器。"
                _info "使用客户端切换出站到 'warp-socks5' 即可走 WARP 出口"
                read -p "按回车键返回..."
                ;;
            5)
                echo -ne "${RED}确认卸载 WARP? [y/N]: ${NC}"
                read -r confirm
                [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] && _warp_uninstall
                read -p "按回车键返回..."
                ;;
            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 中转管理菜单
# ============================================================

_ui_relay_menu() {
    # 委托给 relay.sh 的中转菜单
    _relay_main_menu
}

# ============================================================
# 节点查看/删除
# ============================================================

_ui_view_nodes() {
    _require_singbox || return 1

    clear
    echo -e "${CYAN}=== 查看节点链接 ===${NC}"
    echo ""

    local server_ip=$(_get_public_ip)
    echo -e "服务器 IP: ${GREEN}${server_ip}${NC}"
    [ -n "${SERVER_DOMAIN:-}" ] && echo -e "服务器域名: ${GREEN}${SERVER_DOMAIN}${NC}"
    echo ""

    local count=0
    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)

        count=$((count + 1))
        local name="${type}-${port}"

        # 尝试从元数据获取名称
        if [ -f "$METADATA_FILE" ]; then
            local meta_name=$(jq -r ".protocols.\"$tag\".name // empty" "$METADATA_FILE" 2>/dev/null)
            [ -n "$meta_name" ] && name="$meta_name"
        fi

        echo -e "  ${GREEN}[${count}]${NC} ${name} (${type})"

        case "$type" in
            vless)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                local sid=$(echo "$line" | jq -r '.tls.reality.short_id[0] // empty')
                local flow=$(echo "$line" | jq -r '.users[0].flow // "xtls-rprx-vision"')
                local pbk=$(jq -r ".protocols.\"$tag\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                local uri=$(_proto_reality_uri "$uuid" "$server_ip" "$port" "${sni:-$DEFAULT_SNI}" "$sid" "$name" "$flow" "$pbk")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
            anytls)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local uri=$(_proto_anytls_uri "$pw" "$server_ip" "$port" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
            tuic)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local uri=$(_proto_tuic_uri "$uuid" "$pw" "$server_ip" "$port" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
            hysteria2)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local uri=$(_proto_hy2_uri "$pw" "$server_ip" "$port" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
            vmess)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                local uri=$(_proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
        esac
        echo ""
    done < <(_proto_list_inbounds 2>/dev/null)

    [ "$count" -eq 0 ] && echo "  暂无节点"
    echo ""
    read -p "按回车键返回..."
}

_ui_delete_node() {
    _require_singbox || return 1

    clear
    echo -e "${CYAN}=== 删除节点 ===${NC}"
    echo ""

    local tags=()
    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)
        tags+=("$tag")
        local idx=${#tags[@]}
        echo -e "  ${GREEN}[${idx}]${NC} ${type}:${port}  (${tag})"
    done < <(_proto_list_inbounds 2>/dev/null)

    [ ${#tags[@]} -eq 0 ] && { echo "  暂无节点"; read -p "按回车键返回..."; return; }

    echo ""
    echo -e "  ${YELLOW}支持多选 (如 1 3) 或直接回车删除全部${NC}"
    read -p "选择要删除的节点 [1-${#tags[@]}] (0 返回): " del_input

    # 去除首尾空格
    del_input=$(echo "$del_input" | xargs 2>/dev/null || echo "$del_input")

    # 0 返回
    [ "$del_input" = "0" ] && return

    # 直接回车 = 全选
    local selected=()
    if [ -z "$del_input" ]; then
        for ((i=0; i<${#tags[@]}; i++)); do
            selected+=("$i")
        done
    else
        for num in $del_input; do
            [[ "$num" =~ ^[0-9]+$ ]] || continue
            [ "$num" -ge 1 ] && [ "$num" -le ${#tags[@]} ] && selected+=("$((num - 1))")
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { _warn "未选择有效节点"; sleep 1; return; }

    # 确认
    local sel_names=""
    for idx in "${selected[@]}"; do
        sel_names="${sel_names} ${tags[$idx]}"
    done
    echo -ne "${RED}确认删除以下节点? ${sel_names} [y/N]: ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi

    for idx in "${selected[@]}"; do
        local sel_tag="${tags[$idx]}"
        local sel_port=$(echo "$sel_tag" | grep -oE '[0-9]+$')

        _proto_remove_inbound "$sel_tag"

        [ -f "$METADATA_FILE" ] && _atomic_modify_json "$METADATA_FILE" "del(.protocols.\"$sel_tag\")" 2>/dev/null || true

        _argo_stop "$sel_port" 2>/dev/null || true
        [ -f "$ARGO_METADATA_FILE" ] && _argo_remove_metadata "$sel_tag" 2>/dev/null || true
    done

    _manage_service "restart"
    _success "已删除 ${#selected[@]} 个节点"
    read -p "按回车键返回..."
}

# ============================================================
# 修改节点端口
# ============================================================

_ui_modify_node() {
    _require_singbox || return 1

    clear
    echo -e "${CYAN}=== 修改节点 ===${NC}"
    echo ""

    local tags=()
    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)
        tags+=("$tag")
        local idx=${#tags[@]}

        # 获取名称
        local name="${type}-${port}"
        [ -f "$METADATA_FILE" ] && {
            local meta_name=$(jq -r ".protocols.\"$tag\".name // empty" "$METADATA_FILE" 2>/dev/null)
            [ -n "$meta_name" ] && name="$meta_name"
        }

        echo -e "  ${GREEN}[${idx}]${NC} ${name}  (${type}:${port})"
    done < <(_proto_list_inbounds 2>/dev/null)

    [ ${#tags[@]} -eq 0 ] && { echo "  暂无节点"; read -p "按回车键返回..."; return; }

    echo ""
    read -p "选择要修改的节点 [1-${#tags[@]}] (0 返回): " mod_choice

    [[ ! "$mod_choice" =~ ^[0-9]+$ ]] && return
    [ "$mod_choice" -eq 0 ] && return
    [ "$mod_choice" -lt 1 ] || [ "$mod_choice" -gt ${#tags[@]} ] && { _warn "无效选择"; sleep 1; return; }

    local sel_tag="${tags[$((mod_choice - 1))]}"
    local sel_type=$(jq -r ".inbounds[] | select(.tag==\"$sel_tag\") | .type" "$CONFIG_FILE" 2>/dev/null)
    local sel_port=$(jq -r ".inbounds[] | select(.tag==\"$sel_tag\") | .listen_port" "$CONFIG_FILE" 2>/dev/null)

    # 获取名称
    local sel_name="${sel_type}-${sel_port}"
    [ -f "$METADATA_FILE" ] && {
        local meta_name=$(jq -r ".protocols.\"$sel_tag\".name // empty" "$METADATA_FILE" 2>/dev/null)
        [ -n "$meta_name" ] && sel_name="$meta_name"
    }

    echo ""
    echo -e "  ${CYAN}当前配置:${NC}"
    echo -e "  标签: ${sel_tag}"
    echo -e "  类型: ${sel_type}"
    echo -e "  名称: ${sel_name}"
    echo -e "  端口: ${sel_port}"
    echo ""

    read -p "新端口号 (回车保持 ${sel_port}): " new_port
    [ -z "$new_port" ] && { _info "未修改，返回"; read -p "按回车键返回..."; return; }

    # 验证端口号
    [[ ! "$new_port" =~ ^[0-9]+$ ]] && { _error "无效端口号"; read -p "按回车键返回..."; return; }
    [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ] && { _error "端口号范围 1-65535"; read -p "按回车键返回..."; return; }

    # 检查新端口是否被占用 (排除自己)
    if [ "$new_port" != "$sel_port" ]; then
        local proto="tcp"
        case "$sel_type" in tuic|hysteria2) proto="udp" ;; esac
        if _check_port_occupied "$new_port" "$proto"; then
            _error "端口 ${new_port} 已被占用"
            read -p "按回车键返回..."
            return
        fi
    fi

    read -p "新名称 (回车保持 ${sel_name}): " new_name
    [ -n "$new_name" ] && sel_name="$new_name"

    # 备份配置
    _sb_backup_config 2>/dev/null || true

    # 修改 config.json 中的端口
    _atomic_modify_json "$CONFIG_FILE" "(.inbounds[] | select(.tag==\"$sel_tag\") | .listen_port) = $new_port" || {
        _error "配置修改失败"
        read -p "按回车键返回..."
        return
    }

    # 更新元数据
    if [ -f "$METADATA_FILE" ]; then
        _atomic_modify_json "$METADATA_FILE" ".protocols.\"$sel_tag\".port = $new_port" 2>/dev/null || true
        _atomic_modify_json "$METADATA_FILE" ".protocols.\"$sel_tag\".name = \"$sel_name\"" 2>/dev/null || true
    fi

    _success "节点已更新: ${sel_name} → 端口 ${new_port}"
    _info "正在重启服务..."
    _sb_restart_and_verify

    read -p "按回车键返回..."
}

# ============================================================
# 服务控制
# ============================================================

_ui_restart_service() {
    _require_singbox || return 1
    _sb_restart_and_verify
    read -p "按回车键返回..."
}

_ui_stop_service() {
    _require_singbox || return 1
    echo -ne "${RED}确认停止 sing-box 服务? [y/N]: ${NC}"
    read -r confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return
    _manage_service "stop"
    read -p "按回车键返回..."
}

_ui_view_status() {
    _require_singbox || return 1
    clear
    _manage_service "status"
    echo ""
    read -p "按回车键返回..."
}

_ui_view_logs() {
    clear
    echo -e "${CYAN}=== 实时日志 (Ctrl+C 退出) ===${NC}"
    echo ""
    if [ -f /var/log/sing-box.log ]; then
        tail -f /var/log/sing-box.log
    else
        journalctl -u sing-box -f --no-pager 2>/dev/null || _warn "未找到日志文件"
    fi
}

# ============================================================
# 核心更新
# ============================================================

_ui_update_core() {
    clear
    echo -e "${CYAN}=== 安装/更新 Sing-box 核心 ===${NC}"
    echo ""
    echo -e "  当前版本: v$(_sb_get_version)"
    echo ""
    read -p "输入目标版本 (默认: ${SB_VERSION}): " target_ver
    target_ver=${target_ver:-$SB_VERSION}

    _sb_backup_config 2>/dev/null || true

    _sb_install_core "$target_ver" || { read -p "按回车键返回..."; return; }

    _sb_restart_and_verify

    read -p "按回车键返回..."
}

# ============================================================
# 证书管理
# ============================================================

_ui_cert_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== TLS 证书管理 ===${NC}"
        echo ""

        if [ -f "${SINGBOX_DIR}/cert.pem" ]; then
            echo -e "  证书: ${GREEN}已安装${NC}"
            local cert_expiry=$(openssl x509 -enddate -noout -in "${SINGBOX_DIR}/cert.pem" 2>/dev/null | cut -d'=' -f2)
            [ -n "$cert_expiry" ] && echo -e "  过期: ${GREEN}${cert_expiry}${NC}"
        else
            echo -e "  证书: ${RED}未安装${NC}"
        fi
        echo ""

        echo -e "    ${GREEN}[1]${NC} 生成自签名证书"
        echo -e "    ${GREEN}[2]${NC} 查看证书详情"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-2]: " cert_choice

        case $cert_choice in
            1) _proto_generate_cert; read -p "按回车键返回..." ;;
            2)
                clear
                if [ -f "${SINGBOX_DIR}/cert.pem" ]; then
                    openssl x509 -in "${SINGBOX_DIR}/cert.pem" -text -noout 2>/dev/null | head -20
                else
                    _warn "证书不存在"
                fi
                echo ""
                read -p "按回车键返回..."
                ;;
            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 卸载
# ============================================================

_ui_uninstall() {
    clear
    echo -e "${RED}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║    警告: 此操作将删除所有配置和数据!     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}将清理以下内容:${NC}"
    echo "    - sing-box 核心 & 配置 (inbounds/outbounds/路由)"
    echo "    - 所有节点链接 & 元数据"
    echo "    - Argo 隧道 (cloudflared)"
    echo "    - WARP (warp-plus / wgcf)"
    echo "    - 中转 & 端口转发配置"
    echo "    - 防火墙规则 (iptables)"
    echo "    - systemd 服务 & 定时任务"
    echo ""

    echo -ne "${RED}确认卸载 Singbox-Pro? 输入 DELETE 确认: ${NC}"
    read -r confirm

    if [ "$confirm" != "DELETE" ]; then
        _info "已取消 (需要输入大写 DELETE)"
        read -p "按回车键返回..."
        return
    fi

    _info "正在卸载..."

    # --- 1. 停止所有服务 ---
    _manage_service "stop" 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/init.d/sing-box

    # --- 2. 停止 Argo 隧道 ---
    _argo_stop_all 2>/dev/null || true
    pkill -f "cloudflared" 2>/dev/null || true

    # --- 3. 停止 WARP (warp-plus) ---
    _warp_stop 2>/dev/null || true

    # --- 4. 清理 wgcf WireGuard (旧版 WARP，会劫持路由) ---
    if command -v wg-quick &>/dev/null; then
        wg-quick down wgcf 2>/dev/null || true
    fi
    ip link delete wgcf 2>/dev/null || true
    rm -f /etc/wireguard/wgcf.conf 2>/dev/null || true
    rm -f /usr/local/bin/wgcf 2>/dev/null || true

    # --- 5. 清理 iptables 规则 (避免残留规则导致异常) ---
    # 读取所有已配置端口并清理 ACCEPT 规则
    local ports=()
    if [ -f "${SINGBOX_DIR}/config.json" ]; then
        while IFS= read -r port; do
            [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]] && ports+=("$port")
        done < <(jq -r '.inbounds[]?.listen_port' "${SINGBOX_DIR}/config.json" 2>/dev/null || true)
    fi
    for port in "${ports[@]}"; do
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    done

    # --- 6. 删除文件 ---
    rm -f "$SINGBOX_BIN"
    rm -f "$CLOUDFLARED_BIN"
    rm -f "$WARP_BIN"
    rm -rf "$SINGBOX_DIR"
    rm -rf "$WARP_DIR"
    rm -rf "$RELAY_CONFIG_DIR"

    # 清理临时文件
    rm -f /tmp/singbox_argo_*.pid /tmp/singbox_argo_*.log /tmp/singbox_argo_fixed_*.pid /tmp/singbox_argo_fixed_*.log

    # --- 7. 清理 crontab 定时任务 ---
    if command -v crontab &>/dev/null; then
        crontab -l 2>/dev/null | grep -v 'sing-box\|singbox\|warp' | crontab - 2>/dev/null || true
    fi

    # --- 8. 重载 systemd ---
    systemctl daemon-reload 2>/dev/null || true

    # --- 9. 验证 ---
    _success "Singbox-Pro 卸载完成"
    echo ""
    echo "已删除:"
    [ ! -f "$SINGBOX_BIN" ] && echo "  ✓ sing-box 核心" || echo "  ✗ sing-box 核心 (手动删除)"
    [ ! -d "$SINGBOX_DIR" ] && echo "  ✓ 配置目录" || echo "  ✗ 配置目录 (手动删除)"
    [ ! -f "$CLOUDFLARED_BIN" ] && echo "  ✓ cloudflared" || echo "  ✗ cloudflared (手动删除)"
    [ ! -f "$WARP_BIN" ] && echo "  ✓ warp-plus" || echo "  ✗ warp-plus (手动删除)"
    echo ""

    read -p "按回车键退出..."
    exit 0
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _ui_main_menu
fi
