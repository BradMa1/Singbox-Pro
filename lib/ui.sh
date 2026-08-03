#!/bin/bash
# ============================================================
# ui.sh — Singbox-Pro 可视化菜单模块
# 所有菜单、面板、状态显示集中管理
# ============================================================
export UI_MOD_VERSION="${PROJECT_VERSION}"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

SCRIPT_VERSION="${SCRIPT_VERSION:-${PROJECT_VERSION}}"

# ============================================================
# 字符串工具 (CJK-aware 显示宽度 + 右补空格)
# ============================================================

# 计算 UTF-8 字符串的终端显示宽度 (CJK/全角=2, ASCII=1)
# 注意: bash 3.2 (macOS 默认) 的 printf '%d' "'$ch" 返回的是字节值不是码点,
# 改用 [[ =~ ]] 字节级判断, 跨 bash 3.2/4+/5+ 均准确
_str_display_width() {
    local s="$1" w=0 i=0 ch
    while [ "$i" -lt "${#s}" ]; do
        ch="${s:$i:1}"
        if [[ "$ch" == *[^[:ascii:]]* ]]; then
            # 任一字节 >= 0x80 (CJK/日韩/全角符号) → 2 宽
            w=$((w + 2))
        else
            w=$((w + 1))
        fi
        i=$((i + 1))
    done
    printf '%d' "$w"
}

# 把字符串用空格右补足到目标显示宽度 (用于菜单中英文混排对齐)
_str_pad_cjk() {
    local s="$1" target="$2"
    local cur
    cur=$(_str_display_width "$s")
    local pad=$((target - cur))
    [ "$pad" -lt 1 ] && pad=0
    printf '%s%*s' "$s" "$pad" ""
}

# ============================================================
# 顶部横幅
# ============================================================

_ui_banner() {
    clear
    # 每次渲染从磁盘 lib/core.sh 重读 PROJECT_VERSION,
    # 升级脚本后回到主菜单即可看到新版本, 无需退出 sb 重启
    # 不依赖外部 SCRIPT_DIR 变量, 直接用 BASH_SOURCE[0] 推项目根
    local real_version="${SCRIPT_VERSION}"
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/core.sh" ]; then
        real_version=$(grep -oE 'PROJECT_VERSION="[^"]+"' "$_lib_dir/core.sh" 2>/dev/null \
            | head -1 | sed -E 's/PROJECT_VERSION="([^"]+)"/\1/')
    fi
    [ -z "$real_version" ] && real_version="${PROJECT_VERSION:-2.2.x}"

    local w=48  # 内部宽度
    local l1="Singbox-Pro   v${real_version}"
    local l2="Multi-Protocol Proxy"

    # 动态计算居中 padding
    local p1=$(( (w - ${#l1}) / 2 ))
    local p2=$(( (w - ${#l2}) / 2 ))

    echo -e "${CYAN}"
    printf "  ╔%s╗\n" "$(printf '═%.0s' $(seq 1 $w))"
    printf "  ║%*s%s%*s║\n" $p1 "" "$l1" $((w - p1 - ${#l1})) ""
    printf "  ║%*s%s%*s║\n" $p2 "" "$l2" $((w - p2 - ${#l2})) ""
    printf "  ╚%s╝\n" "$(printf '═%.0s' $(seq 1 $w))"
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
    local cpu=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/(R)//g; s/  */ /g' | xargs | cut -c1-22 || echo "?")
    local mem_raw=$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}' || echo "?")
    local mem=$(echo "$mem_raw" | sed 's/i//g')  # Mi→M, Gi→G
    local disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' || echo "?")
    local region=$(_get_region)
    local ip=$(_get_public_ip)
    local ipv6=$(_get_ipv6)
    local bbr=$(_get_bbr)

    echo -e "  地区: ${YELLOW}${region}${NC} | ${host}"
    echo -e "  系统: ${os_info} | BBR: ${bbr} | CPU: ${cpu} | 内存: ${mem} | 磁盘: ${disk}"
    echo -e "  IPv4: ${GREEN}${ip}${NC}  IPV6: ${GREEN}${ipv6}${NC}"
    echo ""
    echo -e "  ${CYAN}Sing-box${NC} v${sb_ver} ${sb_status} | ${CYAN}Argo${NC} ${argo_status} | ${CYAN}WARP${NC} ${warp_status} | 节点: ${node_count}"
    echo ""
}

# ============================================================
# 主菜单
# ============================================================

_ui_main_menu() {
    while true; do
        _ui_banner
        _ui_status_panel

        echo -e "  ─────────────────────────────────────────────────"
        echo -e "  ${CYAN}【节点管理】${NC}"
        # 左列目标显示宽度=24 (含 [N] 标签 4 宽 + 标签后 1 空格 + 菜单名)
        local W=24
        echo -e "    ${GREEN}[1]${NC} $(_str_pad_cjk "添加节点" $W)${GREEN}[2]${NC} Argo 隧道节点"
        echo -e "    ${GREEN}[3]${NC} $(_str_pad_cjk "修改节点" $W)${GREEN}[4]${NC} 删除节点"
        echo -e "    ${GREEN}[5]${NC} $(_str_pad_cjk "查看节点链接" $W)${GREEN}[6]${NC} 节点分享(订阅+二维码)"
        echo ""

        echo -e "  ${CYAN}【服务控制】${NC}"
        echo -e "    ${GREEN}[7]${NC} 重启服务          ${GREEN}[8]${NC} 停止服务"
        echo ""

        echo -e "  ${CYAN}【进阶功能】${NC}"
        echo -e "    ${GREEN}[9]${NC} 中转管理          ${GREEN}[10]${NC} WARP 管理"
        echo -e "    ${GREEN}[11]${NC} IPv6 优化        ${GREEN}[12]${NC} 流媒体 DNS"
        echo ""

        echo -e "  ${CYAN}【系统维护】${NC}"
        # 左列目标显示宽度=34 (含 [N] 标签 4 宽 + 标签后 1 空格 + 菜单名 + 提示括号)
        local M=34
        echo -e "    ${GREEN}[13]${NC} $(_str_pad_cjk "安装/更新核心(sing-box 内核)" $M)${RED}[14]${NC} 卸载脚本(清理所有配置)"
        echo -e "    ${GREEN}[15]${NC} $(_str_pad_cjk "健康检查(端口/配置/服务诊断)" $M)${GREEN}[16]${NC} 升级脚本(lib 模块+sb.sh)"
        echo ""

        echo -e "  ─────────────────────────────────────────────────"
        echo -e "    ${YELLOW}[0]${NC} 退出脚本"
        echo ""

        read -p "  请输入选项 [0-16]: " choice

        case $choice in
            1) _ui_add_node_menu ;;
            2) _ui_argo_menu ;;
            3) _ui_modify_node ;;
            4) _ui_delete_node ;;
            5) _ui_view_nodes ;;
            6) _ui_subscription ;;
            7) _ui_restart_service ;;
            8) _ui_stop_service ;;
            9) _ui_relay_menu ;;
            10) _ui_warp_menu ;;
            11) _ui_ipv6_menu ;;
            12) _ui_streaming_dns_menu ;;
            13) _ui_update_core ;;
            14) _ui_uninstall ;;
            15) _ui_health_check ;;
            16) _ui_upgrade_scripts ;;
            0) echo "再见!"; exit 0 ;;
            *) _warn "无效选项，请重试"; sleep 1 ;;
        esac
    done
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
    echo -e "    ${GREEN}[5]${NC} Trojan            (TLS, 真证书 HTTPS 外形, 路径放行)"
    echo -e "    ${GREEN}[6]${NC} Shadowsocks 2022 (AEAD, 轻量兜底/老设备)"
    echo -e "    ${GREEN}[7]${NC} SOCKS5           (明文, 带认证, 作跳板/本地代理)"
    echo ""
    echo -e "  ${YELLOW}提示: 支持多选，用空格分隔 (如 1 3 5)，直接回车 = 默认 4 协议 (Reality/AnyTLS/TUIC/Hy2)${NC}"
    echo -e "    ${YELLOW}[0]${NC} 返回"
    echo ""

    read -r -p "  请输入选项 [1-7] (0 返回): " proto_choice
    proto_choice=$(echo "$proto_choice" | xargs 2>/dev/null)
    [ -z "$proto_choice" ] && proto_choice="1 2 3 4"

    local selected=()
    for ch in $proto_choice; do
        case $ch in
            1|2|3|4|5|6|7) selected+=("$ch") ;;
            0) return ;;
            *) _warn "无效选项: $ch，跳过"; sleep 1 ;;
        esac
    done
    [ ${#selected[@]} -eq 0 ] && return

    # ===== 证书预生成 (AnyTLS/TUIC/Hy2/Trojan 需要) =====
    local need_cert=false
    for ch in "${selected[@]}"; do
        case $ch in 2|3|4|5) need_cert=true; break ;; esac
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
    proto_names[5]="Trojan"
    proto_names[6]="Shadowsocks 2022"
    proto_names[7]="SOCKS5"

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
            5) result=$(_ui_add_trojan_quick   "$port" "$name_prefix") ;;
            6) result=$(_ui_add_ss2022_quick   "$port" "$name_prefix") ;;
            7) result=$(_ui_add_socks5_quick   "$port" "$name_prefix") ;;
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
                local std=$(_proto_vmess_ws_standard_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                local full=$(_proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (VMess WS)"
                echo -e "    端口: ${port}  路径: ${ws_path}"
                echo -e "    ${GREEN}${std}${NC}"
                echo -e "    ${CYAN}↑ 标准 vmess:// — 导入小火箭 / 通用客户端 (自签需在客户端勾选「允许不安全」)${NC}"
                echo -e "    ${GREEN}${full}${NC}"
                echo -e "    ${YELLOW}↑ 完整 Xray 配置 — 复制整段粘贴到 v2rayN「设置 → 从剪贴板导入」(已固定证书, 8.1 安全)${NC}"
                echo ""
                ;;
            vless-ws)
                local uri=$(_proto_vless_ws_uri "$uuid" "$server_ip" "$port" "$server_ip" "$ws_path" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (VLESS WS)"
                echo -e "    端口: ${port}  路径: ${ws_path}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo -e "    ${YELLOW}↑ VLESS over WebSocket + TLS (sing-box 1.11+ 原生, 替代已移除的 VMess)${NC}"
                echo ""
                ;;
            trojan)
                # 槽位复用: $4=password $5=sni $6=insecure
                local password="$uuid" sni="$sni" insecure="$sid"
                local uri=$(_proto_trojan_uri "$password" "$server_ip" "$port" "$name" "$sni" "$insecure")
                echo -e "  ${GREEN}● ${name}${NC} (Trojan)"
                echo -e "    端口: ${port}  SNI: ${sni}  insecure=${insecure}"
                echo -e "    ${GREEN}${uri}${NC}"
                if [ "${insecure:-1}" = "0" ]; then
                    echo -e "    ${GREEN}↑ Trojan over TLS, 真证书 HTTPS 外形已激活 (路径放行, 客户端无需 insecure)${NC}"
                else
                    echo -e "    ${YELLOW}↑ 当前为自签证书: stealth 未激活, 与 vless-ws 同样会被 L7 拦截!${NC}"
                    echo -e "    ${YELLOW}  运行 ${CYAN}sb cert issue <你的域名>${NC}${YELLOW} 升级真证书 (会自动重写本节点, insecure->0)${NC}"
                fi
                echo ""
                ;;
            ss2022)
                # 槽位复用: $4=psk $5=method
                local psk="$uuid" method="$sni"
                local uri=$(_proto_ss2022_uri "$method" "$psk" "$server_ip" "$port" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (Shadowsocks 2022)"
                echo -e "    端口: ${port}  方法: ${method}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo -e "    ${YELLOW}↑ AEAD 轻量协议, 作兜底/老设备节点${NC}"
                echo ""
                ;;
            socks5)
                # 槽位复用: $4=user $5=pass
                local user="$uuid" pass="$sni"
                local uri=$(_proto_socks5_uri "$user" "$pass" "$server_ip" "$port" "$name")
                echo -e "  ${GREEN}● ${name}${NC} (SOCKS5)"
                echo -e "    端口: ${port}  用户: ${user}"
                echo -e "    ${GREEN}${uri}${NC}"
                echo -e "    ${YELLOW}↑ 明文 SOCKS5(带认证), 仅建议本地/可信网络/中转跳板使用${NC}"
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

    local output=$(_proto_reality_config "$port" "$uuid" "$sni" "$short_id" "xtls-rprx-vision" "")
    local inbound_json=$(echo "$output" | sed '$d')
    local pbk=$(echo "$output" | tail -1 | sed 's/^REALITY_PBK=//')
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

    local meta_json=$(jq -n \
        --arg tag "anytls-${port}" \
        --arg name "$name" \
        --arg password "$password" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "anytls", password: $password, port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

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

    local meta_json=$(jq -n \
        --arg tag "tuic-${port}" \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg password "$password" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "tuic", uuid: $uuid, password: $password, port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

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

    local meta_json=$(jq -n \
        --arg tag "hysteria2-${port}" \
        --arg name "$name" \
        --arg password "$password" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "hysteria2", password: $password, port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

    echo "hy2|${name}|${port}||||${password}||"
}

_ui_add_trojan_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 Trojan"
        return 1
    fi

    local password=$(_random_hex 16)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-trojan" || name="Trojan-${port}"

    # 证书: 优先 acme 真证书 (cert.sh), 回退自签 (SAN 已含公网 IP)
    local certinfo cert key sni insecure
    certinfo=$(_cert_trojan_paths)
    cert=$(echo "$certinfo" | awk '{print $1}')
    key=$(echo "$certinfo" | awk '{print $2}')
    sni=$(echo "$certinfo" | awk '{print $3}')
    insecure=$(echo "$certinfo" | awk '{print $4}')

    local inbound_json=$(_proto_trojan_config "$port" "$password" "$cert" "$key" "$sni")
    _proto_add_inbound "$inbound_json" || return 1

    local meta_json=$(jq -n \
        --arg tag "trojan-${port}" \
        --arg name "$name" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg insecure "$insecure" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "trojan", password: $password, sni: $sni, insecure: ($insecure|tostring), port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

    # 槽位: proto|name|port|password|sni|insecure|||  (显示分支按此解析)
    echo "trojan|${name}|${port}|${password}|${sni}|${insecure}|||"
}

_ui_add_ss2022_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 Shadowsocks 2022"
        return 1
    fi

    # SS2022 PSK: 32 字节 base64 (对应 2022-blake3-aes-256-gcm)
    local psk=$(openssl rand -base64 32 2>/dev/null | tr -d '\n=')
    [ -z "$psk" ] && psk=$(_random_hex 32)
    local method="2022-blake3-aes-256-gcm"

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-ss2022" || name="SS2022-${port}"

    local inbound_json=$(_proto_ss2022_config "$port" "$psk" "$method")
    _proto_add_inbound "$inbound_json" || return 1

    local meta_json=$(jq -n \
        --arg tag "ss2022-${port}" \
        --arg name "$name" \
        --arg psk "$psk" \
        --arg method "$method" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "shadowsocks", psk: $psk, method: $method, port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

    # 槽位: proto|name|port|psk|method||||  (显示分支按此解析)
    echo "ss2022|${name}|${port}|${psk}|${method}||||"
}

_ui_add_socks5_quick() {
    local port=$1
    local name_prefix=$2

    if _check_port_occupied "$port" "tcp"; then
        _error "端口 ${port} 已被占用，跳过 SOCKS5"
        return 1
    fi

    local user="u$(_random_hex 4)"
    local pass=$(_random_hex 12)

    local name
    [ -n "$name_prefix" ] && name="${name_prefix}-socks5" || name="SOCKS5-${port}"

    local inbound_json=$(_proto_socks5_config "$port" "$user" "$pass")
    _proto_add_inbound "$inbound_json" || return 1

    local meta_json=$(jq -n \
        --arg tag "socks5-${port}" \
        --arg name "$name" \
        --arg user "$user" \
        --arg pass "$pass" \
        --arg port "$port" \
        --arg created "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{($tag): {name: $name, type: "socks", user: $user, password: $pass, port: ($port|tonumber), created_at: $created}}')
    [ ! -f "$METADATA_FILE" ] && echo '{}' > "$METADATA_FILE"
    _atomic_modify_json "$METADATA_FILE" ".protocols += $meta_json"

    # 槽位: proto|name|port|user|pass||||  (显示分支按此解析)
    echo "socks5|${name}|${port}|${user}|${pass}||||"
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
        echo -e "  ${YELLOW}【获取固定隧道 Token + Dashboard 配置步骤】${NC}"
        echo -e "    ${CYAN}①${NC} 访问 ${GREEN}https://one.dash.cloudflare.com/${NC}"
        echo -e "    ${CYAN}②${NC} 左侧 ${GREEN}Networks → Tunnels → Create a tunnel${NC}"
        echo -e "    ${CYAN}③${NC} 类型选 ${GREEN}Cloudflared${NC} → 复制 ${GREEN}Tunnel Token${NC}（粘贴到选项 [2]）"
        echo -e "    ${CYAN}④${NC} 配置 ${GREEN}Public Hostname${NC}（这一步必做，否则小火箭永远超时）:"
        echo -e "        Subdomain: 你的子域名"
        echo -e "        Domain:    你的根域名"
        echo -e "        Type:      ${RED}HTTP${NC} （不要选 HTTPS！）"
        echo -e "        URL:       ${RED}http://127.0.0.1:端口${NC} （不要写 https、不要写 localhost！）"
        echo -e "        Path:      ${RED}留空${NC} （不要填任何东西）"
        echo -e "    ${CYAN}⑤${NC} 保存。脚本部署完后再回 Dashboard 确认 Service 仍是 ${RED}http://127.0.0.1:端口${NC}"
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
            6) _ui_argo_stop_all_confirm ;;
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
    _argo_dashboard_hint "$port" "$tunnel_domain"

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
    local sel_name=$(jq -r ".\"$sel_tag\".name" "$ARGO_METADATA_FILE")

    # 二次确认
    echo ""
    _warn "将删除节点: ${sel_name} (端口 ${sel_port})"
    _info "  → 停止 cloudflared 隧道进程"
    _info "  → 删除 sing-box 入站（${sel_tag}）"
    _info "  → 从节点列表移除"
    echo ""
    local yn=""
    read -p "确认删除？[y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { _info "已取消"; read -p "按回车键返回..."; return; }

    # 停止隧道
    _argo_stop "$sel_port"

    # 删除入站
    _proto_remove_inbound "$sel_tag"
    _argo_remove_metadata "$sel_tag"
    _manage_service "restart"

    _success "Argo 节点已删除"
    read -p "按回车键返回..."
}

_ui_argo_stop_all_confirm() {
    echo ""
    _warn "将停止所有 Argo 隧道进程（包括 cloudflared）"
    _info "  → sing-box 入站不会被删除，只停隧道进程"
    _info "  → 重新启动后可继续使用现有节点"
    echo ""
    local yn=""
    read -p "确认停止所有 Argo 隧道？[y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { _info "已取消"; read -p "按回车键返回..."; return; }
    _argo_stop_all
    read -p "按回车键返回..."
}

_ui_argo_view_log() {
    clear
    echo -e "${CYAN}=== Argo 隧道日志 ===${NC}"
    echo ""

    # 列出所有 Argo 节点（含端口）供选择
    local log_tags=()
    local log_ports=()
    local log_types=()
    while IFS='|' read -r tag name domain port proto atype; do
        [ -z "$tag" ] && continue
        log_tags+=("$tag")
        log_ports+=("$port")
        log_types+=("$atype")
        local idx=${#log_tags[@]}
        local type_label=$([ "$atype" = "fixed" ] && echo "固定" || echo "临时")
        echo -e "  ${GREEN}[${idx}]${NC} ${name} (${type_label} · 端口 ${port} · ${domain})"
    done < <(jq -r 'to_entries[] | "\(.key)|\(.value.name)|\(.value.domain)|\(.value.local_port)|\(.value.protocol)|\(.value.type)"' "$ARGO_METADATA_FILE" 2>/dev/null)

    if [ ${#log_tags[@]} -eq 0 ]; then
        echo "  无 Argo 节点"
        read -p "按回车键返回..."
        return
    fi

    echo ""
    read -p "选择节点查看日志 [1-${#log_tags[@]}] (0 返回): " log_choice

    [[ ! "$log_choice" =~ ^[0-9]+$ ]] && return
    [ "$log_choice" -eq 0 ] && return
    [ "$log_choice" -lt 1 ] || [ "$log_choice" -gt ${#log_tags[@]} ] && { _warn "无效选择"; sleep 1; return; }

    local sel_port="${log_ports[$((log_choice - 1))]}"
    local sel_type="${log_types[$((log_choice - 1))]}"

    echo ""
    _argo_view_log "$sel_port"
    echo ""
    _info "提示: 实时跟踪日志用 ${YELLOW}journalctl -u argo-tunnel@${sel_port} -f${NC}（${sel_type}隧道 unit 名可能不同）"
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

    # 更新元数据（token 仅存掩码，真实 token 在 ${SINGBOX_DIR}/argo/${convert_port}.token，600 权限）
    local token_disp=""
    [ -n "$token" ] && token_disp="${token:0:20}***"
    _atomic_modify_json "$ARGO_METADATA_FILE" ".\"$convert_tag\".type = \"fixed\" | .\"$convert_tag\".domain = \"$tunnel_domain\" | .\"$convert_tag\".token = \"$token_disp\""

    _success "临时隧道已转换为固定隧道: ${tunnel_domain}"
    echo ""
    _argo_dashboard_hint "$convert_port" "$tunnel_domain"
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
        echo -e "    ${GREEN}[4]${NC} 添加到 sing-box     (将 WARP 加入 proxy 选择器 + 配置域名分流)"
        echo -e "    ${RED}[5]${NC} 卸载 WARP"
        echo ""
        echo -e "  ${YELLOW}【域名分流管理】${NC}"
        echo -e "    ${GREEN}[6]${NC} 查看分流域名列表"
        echo -e "    ${GREEN}[7]${NC} 添加自定义域名      (如 netflix.com, disney.com)"
        echo -e "    ${GREEN}[8]${NC} 删除自定义域名"
        echo -e "    ${GREEN}[9]${NC} 重置到默认域名列表"
        echo ""

        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""

        read -p "  请输入选项 [0-9]: " warp_choice

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
                _info "WARP 已添加到 proxy 选择器并配置域名分流规则。"
                _info "OpenAI/Claude/Gemini 等域名流量将自动走 WARP 出口"
                read -p "按回车键返回..."
                ;;
            5)
                echo -ne "${RED}确认卸载 WARP? [y/N]: ${NC}"
                read -r confirm
                [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] && _warp_uninstall
                read -p "按回车键返回..."
                ;;
            6)
                _ui_warp_list_domains
                ;;
            7)
                _ui_warp_add_domain
                ;;
            8)
                _ui_warp_remove_domain
                ;;
            9)
                echo -ne "确认重置 WARP 分流域名到默认列表? [y/N]: "
                read -r confirm
                [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] && {
                    _warp_reset_domains
                    _manage_service restart 2>/dev/null
                }
                read -p "按回车键返回..."
                ;;
            0) return ;;
            *) _warn "无效选项"; sleep 1 ;;
        esac
    done
}

# --- WARP 查看域名列表 ---
_ui_warp_list_domains() {
    clear
    echo -e "${CYAN}=== WARP 分流域名列表 ===${NC}"
    echo ""

    echo -e "  ${GREEN}【默认域名 (不可删除)】${NC}"
    for d in $_WARP_DEFAULT_DOMAINS; do
        echo -e "    $d"
    done

    echo ""
    echo -e "  ${YELLOW}【自定义域名】${NC}"
    _warp_init_metadata 2>/dev/null || true
    local custom=$(jq -r '.custom_domains | join("\n")' "$WARP_METADATA_FILE" 2>/dev/null || echo "")
    if [ -n "$custom" ]; then
        echo "$custom" | while read -r d; do
            [ -n "$d" ] && echo -e "    $d"
        done
    else
        echo "    (无)"
    fi

    echo ""
    echo -e "  ${CYAN}说明: 分流规则已自动添加，OpenAI/Claude/Gemini 等域名走 WARP${NC}"
    read -p "按回车键返回..."
}

# --- WARP 添加自定义域名 ---
_ui_warp_add_domain() {
    clear
    echo -e "${CYAN}=== 添加自定义 WARP 分流域名 ===${NC}"
    echo ""
    echo -e "  当前默认域名: ${_WARP_DEFAULT_DOMAINS}"
    echo ""
    echo -e "  ${YELLOW}提示: 输入完整域名，如 netflix.com、disney.com${NC}"
    echo -e "  支持子域名，如 *.google.com 表示所有 .google.com 子域名"
    echo ""
    read -p "请输入域名 (多个用空格分隔): " input_domains

    [ -z "$input_domains" ] && { _warn "未输入域名"; return; }

    local added=0
    for domain in $input_domains; do
        # 简单校验
        if echo "$domain" | grep -qE '^[a-zA-Z0-9*.-]+$'; then
            _warp_add_domain "$domain" && added=$((added + 1))
        else
            _warn "域名格式无效: $domain，跳过"
        fi
    done

    if [ "$added" -gt 0 ]; then
        _manage_service restart 2>/dev/null
        _success "已添加 $added 个域名到 WARP 分流，服务已重启"
    fi
    read -p "按回车键返回..."
}

# --- WARP 删除自定义域名 ---
_ui_warp_remove_domain() {
    clear
    echo -e "${CYAN}=== 删除自定义 WARP 分流域名 ===${NC}"
    echo ""

    local custom_domains=()
    while IFS= read -r d; do
        [ -n "$d" ] && custom_domains+=("$d")
    done < <(jq -r '.custom_domains[]' "$WARP_METADATA_FILE" 2>/dev/null || true)

    if [ ${#custom_domains[@]} -eq 0 ]; then
        echo "  暂无自定义域名"
        read -p "按回车键返回..."
        return
    fi

    echo -e "  ${CYAN}当前自定义域名:${NC}"
    for i in "${!custom_domains[@]}"; do
        echo -e "    ${GREEN}[$((i+1))]${NC} ${custom_domains[$i]}"
    done
    echo ""
    echo -e "  ${YELLOW}支持多选 (如 1 3) 或直接回车删除全部${NC}"
    read -p "选择要删除的域名 [1-${#custom_domains[@]}] (0 返回): " del_input

    del_input=$(echo "$del_input" | xargs 2>/dev/null || echo "$del_input")
    [ "$del_input" = "0" ] && return

    local selected=()
    if [ -z "$del_input" ]; then
        for ((i=0; i<${#custom_domains[@]}; i++)); do
            selected+=("$i")
        done
    else
        for num in $del_input; do
            [[ "$num" =~ ^[0-9]+$ ]] || continue
            [ "$num" -ge 1 ] && [ "$num" -le ${#custom_domains[@]} ] && selected+=("$((num - 1))")
        done
    fi

    [ ${#selected[@]} -eq 0 ] && { _warn "未选择"; return; }

    for idx in "${selected[@]}"; do
        _warp_remove_domain "${custom_domains[$idx]}"
    done

    _manage_service restart 2>/dev/null
    _success "已删除 ${#selected[@]} 个域名，服务已重启"
    read -p "按回车键返回..."
}

# ============================================================
# 中转管理菜单
# ============================================================

_ui_relay_menu() {
    # 委托给 relay.sh 的中转菜单
    _relay_main_menu
}

# ============================================================
# IPv6 优化菜单
# ============================================================

_ui_ipv6_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== IPv6 优化 ===${NC}"
        echo ""
        echo -e "  当前状态: $(_dns_ipv6_status)"
        echo ""
        echo -e "  让 sing-box 出站连接优先使用 IPv6，有助于解锁流媒体。"
        echo -e "  前提: VPS 必须有公网 IPv6 地址。"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 启用 IPv6 优先"
        echo -e "    ${GREEN}[2]${NC} 恢复 IPv4 优先（默认）"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""
        read -p "  请输入选项 [0-2]: " choice

        case $choice in
            1) _dns_ipv6_enable; read -p "按回车继续..."; ;;
            2) _dns_ipv6_disable; read -p "按回车继续..."; ;;
            0) return ;;
            *) _warn "无效选项" ; sleep 1 ;;
        esac
    done
}

# ============================================================
# 流媒体 DNS 菜单
# ============================================================

_ui_streaming_dns_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 流媒体 DNS 解锁 ===${NC}"
        echo ""
        echo -e "  当前 DNS: $(_streaming_dns_status)"
        echo ""
        echo -e "  设置后，Netflix / Disney+ / HBO 等流媒体域名"
        echo -e "  将走指定 DNS 解析，绕开机房 IP 封杀。"
        echo -e "  不影响其他域名的正常解析。"
        echo ""
        echo -e "    ${GREEN}[1]${NC} 设置流媒体 DNS"
        echo -e "    ${GREEN}[2]${NC} 移除流媒体 DNS"
        echo ""
        echo -e "    ${YELLOW}[0]${NC} 返回"
        echo ""
        read -p "  请输入选项 [0-2]: " choice

        case $choice in
            1)
                echo ""
                read -p "  请输入流媒体 DNS 地址（如 151.243.229.229）: " dns_addr
                [ -n "$dns_addr" ] && _streaming_dns_set "$dns_addr"
                read -p "按回车继续..."
                ;;
            2)
                _streaming_dns_remove
                read -p "按回车继续..."
                ;;
            0) return ;;
            *) _warn "无效选项" ; sleep 1 ;;
        esac
    done
}

# ============================================================
# 节点查看/删除
# ============================================================

_ensure_node_metadata_names() {
    # 自动补全旧节点（升级前添加、未写名字）的显示名，避免查看链接显示成 类型-端口
    [ -f "$METADATA_FILE" ] || return 0
    local prefix
    prefix=$(jq -r '[(.protocols//{})[] | select((.name//"") | test("-vless-reality$")) | .name | sub("-vless-reality$";"")][0] // empty' "$METADATA_FILE" 2>/dev/null)
    [ -n "$prefix" ] || return 0
    local raw
    raw=$(_proto_list_inbounds 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    local ins
    ins=$(printf '%s\n' "$raw" | grep -v '^[[:space:]]*$' | jq -s '.' 2>/dev/null)
    [ -n "$ins" ] || return 0
    local tmp
    tmp=$(mktemp)
    jq --arg p "$prefix" --argjson inbounds "$ins" '
        ($inbounds) as $list | ($p) as $prefix |
        reduce $list[] as $in (.;
            ($in.tag) as $tag |
            ($in.type) as $type |
            (if (.protocols[$tag].name // "") != "" then . else
                (.protocols[$tag].name = ($prefix + "-" + (
                    if $type == "vless" then (if ($in.tls.reality != null and $in.tls.reality != {}) then "vless-reality" else "vless-ws" end)
                    elif $type == "anytls" then "anytls"
                    elif $type == "tuic" then "tuic"
                    elif $type == "hysteria2" then "hy2"
                    elif $type == "vmess" then "vmess-ws"
                    else $type end)))
            end)
        )
    ' "$METADATA_FILE" > "$tmp" 2>/dev/null
    if [ -s "$tmp" ] && jq empty "$tmp" 2>/dev/null; then
        mv "$tmp" "$METADATA_FILE"
    else
        rm -f "$tmp"
    fi
}

_ui_view_nodes() {
    _require_singbox || return 1
    _ensure_node_metadata_names

    clear
    echo -e "${CYAN}=== 查看节点链接 ===${NC}"
    echo ""
    # 客户端使用提示: AnyTLS/TUIC/H2 链接用 insecure 跳过验证(sing-box 内核合法, 不受 8/1 影响);
    # 纯 Xray 客户端请改用 VLESS-Reality / VMess(pinned); v2rayN 必须选 sing_box
    echo -e "${YELLOW}客户端导入提醒:${NC}"
    echo -e "  ${YELLOW}1.${NC} AnyTLS / TUIC / Hysteria2 链接已用 ${GREEN}insecure${NC} 跳过自签证书验证 —— 这是 sing-box 内核(tls.insecure)的合法行为, ${GREEN}不受 Xray 8/1 禁用 allowInsecure 的影响${NC}"
    echo -e "  ${YELLOW}2.${NC} v2rayN: 节点「${YELLOW}配置项${NC}」必须选 ${YELLOW}sing_box${NC} (选 xray/留空, AnyTLS 等节点连不通 — Xray 不支持 AnyTLS 出站)"
    echo -e "  ${YELLOW}3.${NC} VLESS-Reality 用 pbk 公钥体系, 免证书验证, 任何内核/8/1 后都通"
    echo -e "  ${YELLOW}4.${NC} 纯 Xray 客户端(v2rayNG 等): 请用 VLESS-Reality / VMess(已带证书哈希固定), 不要依赖 insecure(8/1 后 Xray 会拒)"
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
                # 区分 VLESS-Reality (tls.reality 存在) 与 VLESS-WS (普通 TLS + transport.ws)
                local is_reality=$(echo "$line" | jq -r '(.tls.reality != null) and (.tls.reality != {})' 2>/dev/null)
                if [ "$is_reality" = "true" ]; then
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local sid=$(echo "$line" | jq -r '.tls.reality.short_id[0] // empty')
                    local flow=$(echo "$line" | jq -r '.users[0].flow // "xtls-rprx-vision"')
                    local pbk=$(jq -r ".protocols.\"$tag\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                    # fallback: metadata key 与 config tag 不一致 (如外部改端口) 时,
                    # 直接从 config 的 reality 私钥推导公钥, 避免 pbk 为空导致链接失效
                    if [ -z "$pbk" ]; then
                        local priv=$(echo "$line" | jq -r '.tls.reality.private_key // empty')
                        [ -n "$priv" ] && pbk=$(_reality_pubkey_from_config "$priv")
                        [ -z "$pbk" ] && _warn "节点 $tag 无法获取 Reality 公钥 (metadata 缺失且私钥推导失败), 该 VLESS 链接将缺 pbk"
                    fi
                    uri=$(_proto_reality_uri "$uuid" "$server_ip" "$port" "${sni:-$DEFAULT_SNI}" "$sid" "$name" "$flow" "$pbk")
                else
                    # VLESS-WS: 普通 TLS + WebSocket, 不需要 pbk/sid
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                    uri=$(_proto_vless_ws_uri "$uuid" "$server_ip" "$port" "${sni:-$server_ip}" "$ws_path" "$name")
                fi
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
                local std=$(_proto_vmess_ws_standard_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                local full=$(_proto_vmess_ws_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                echo -e "      标准 vmess:// (小火箭): ${GREEN}${std}${NC}"
                echo -e "      完整 Xray 配置 (v2rayN): ${GREEN}${full}${NC}"
                echo -e "      ${YELLOW}已用 pinnedPeerCertificateChainSha256 证书固定, 无需勾选「跳过证书验证」(Xray 8/1 后仍可连)${NC}"
                ;;
            trojan)
                # 修复 (v2.2.5): 查看节点链接漏掉 Trojan/SS2022/SOCKS5 三协议 → 链接不显示
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                local insecure=$(jq -r ".protocols.\"$tag\".insecure // \"1\"" "$METADATA_FILE" 2>/dev/null || echo "1")
                local uri=$(_proto_trojan_uri "$pw" "$server_ip" "$port" "$name" "${sni:-$server_ip}" "$insecure")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                if [ "${insecure:-1}" = "0" ]; then
                    echo -e "      ${GREEN}↑ Trojan over TLS, 真证书 HTTPS 外形已激活 (客户端无需 insecure)${NC}"
                else
                    echo -e "      ${YELLOW}↑ 当前为自签证书: stealth 未激活, 运行 sb cert issue <域名> 升级真证书${NC}"
                fi
                ;;
            shadowsocks)
                local psk=$(echo "$line" | jq -r '.password // empty')
                local method=$(echo "$line" | jq -r '.method // "2022-blake3-aes-256-gcm"')
                local uri=$(_proto_ss2022_uri "$method" "$psk" "$server_ip" "$port" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                ;;
            socks)
                local u=$(echo "$line" | jq -r '.users[0].username // empty')
                local p=$(echo "$line" | jq -r '.users[0].password // empty')
                local uri=$(_proto_socks5_uri "$u" "$p" "$server_ip" "$port" "$name")
                echo -e "      链接: ${GREEN}${uri}${NC}"
                echo -e "      ${YELLOW}↑ 明文 SOCKS5(带认证), 仅建议本地/可信网络/中转跳板使用${NC}"
                ;;
        esac
        echo ""
    done < <(_proto_list_inbounds 2>/dev/null)

    [ "$count" -eq 0 ] && echo "  暂无节点"
    echo ""
    read -p "按回车键返回..."
}

# ============================================================
# 节点分享：订阅链接 + 二维码
# ============================================================

# ============================================================
# 订阅导出 — Clash Meta YAML / Sing-box 原生 JSON
# 借鉴 yonggekkk/sing-box-yg 的思路: 在一键脚本里本地生成完整客户端配置,
# base64 成 data-URI 订阅, 无需第三方订阅器/外链 (契合我们「本地化生成」理念)。
# 与对方一致: Clash Meta 含 proxy-groups(手动选择 + url-test 自动选择) + 基础规则;
#              Sing-box JSON 为官方客户端(SFA/SFI/SFW)可直接订阅的完整配置。
# ============================================================

_build_clash_yaml() {
    local server_ip="${1:-$(_get_public_ip)}"
    local -a names=()
    local proxies=""

    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)
        local name="${type}-${port}"
        [ -f "$METADATA_FILE" ] && name=$(jq -r ".protocols.\"$tag\".name // empty" "$METADATA_FILE" 2>/dev/null || echo "$name")
        [ -z "$name" ] && name="${type}-${port}"
        names+=("$name")

        local block=""
        case "$type" in
            vless)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local is_reality=$(echo "$line" | jq -r '(.tls.reality != null) and (.tls.reality != {})' 2>/dev/null)
                if [ "$is_reality" = "true" ]; then
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local sid=$(echo "$line" | jq -r '.tls.reality.short_id[0] // empty')
                    local flow=$(echo "$line" | jq -r '.users[0].flow // "xtls-rprx-vision"')
                    local pbk=$(jq -r ".protocols.\"$tag\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                    block=$(cat <<EOF
  - name: "$name"
    type: vless
    server: $server_ip
    port: $port
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: $flow
    client-fingerprint: chrome
    servername: ${sni:-$DEFAULT_SNI}
    reality-opts:
      public-key: $pbk
      short-id: $sid
EOF
)
                else
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                    block=$(cat <<EOF
  - name: "$name"
    type: vless
    server: $server_ip
    port: $port
    uuid: $uuid
    network: ws
    tls: true
    udp: true
    client-fingerprint: chrome
    servername: ${sni:-$server_ip}
    ws-opts:
      path: $ws_path
    skip-cert-verify: true
EOF
)
                fi
                ;;
            anytls)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                block=$(cat <<EOF
  - name: "$name"
    type: anytls
    server: $server_ip
    port: $port
    password: $pw
    client-fingerprint: chrome
    tls: true
    udp: true
    skip-cert-verify: true
EOF
)
                ;;
            tuic)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                block=$(cat <<EOF
  - name: "$name"
    type: tuic
    server: $server_ip
    port: $port
    uuid: $uuid
    password: $pw
    ip: $server_ip
    sni: $server_ip
    alpn:
      - h3
    disable-sni: false
    reduce-rtt: true
    udp: true
    skip-cert-verify: true
EOF
)
                ;;
            hysteria2)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                block=$(cat <<EOF
  - name: "$name"
    type: hysteria2
    server: $server_ip
    port: $port
    password: $pw
    sni: $server_ip
    alpn:
      - h3
    udp: true
    skip-cert-verify: true
EOF
)
                ;;
            trojan)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                local insecure=$(jq -r ".protocols.\"$tag\".insecure // \"1\"" "$METADATA_FILE" 2>/dev/null || echo "1")
                block=$(cat <<EOF
  - name: "$name"
    type: trojan
    server: $server_ip
    port: $port
    password: $pw
    sni: ${sni:-$server_ip}
    alpn:
      - h2
      - http/1.1
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: $insecure
EOF
)
                ;;
            shadowsocks)
                local psk=$(echo "$line" | jq -r '.password // empty')
                local method=$(echo "$line" | jq -r '.method // "2022-blake3-aes-256-gcm"')
                block=$(cat <<EOF
  - name: "$name"
    type: ss
    server: $server_ip
    port: $port
    cipher: $method
    password: $psk
    udp: true
EOF
)
                ;;
            socks)
                local u=$(echo "$line" | jq -r '.users[0].username // empty')
                local p=$(echo "$line" | jq -r '.users[0].password // empty')
                block=$(cat <<EOF
  - name: "$name"
    type: socks5
    server: $server_ip
    port: $port
    username: $u
    password: $p
    udp: true
EOF
)
                ;;
            vmess)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                block=$(cat <<EOF
  - name: "$name"
    type: vmess
    server: $server_ip
    port: $port
    uuid: $uuid
    alterId: 0
    cipher: auto
    network: ws
    tls: true
    udp: true
    ws-opts:
      path: $ws_path
      headers: {}
    skip-cert-verify: true
EOF
)
                ;;
        esac
        [ -n "$block" ] && proxies="${proxies}${block}"$'\n'
    done < <(_proto_list_inbounds 2>/dev/null)

    [ -z "$proxies" ] && return 0

    local group_items=""
    for n in "${names[@]}"; do
        group_items="${group_items}      - \"${n}\""$'\n'
    done

    cat <<EOF
proxies:
${proxies}proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "♻️ 自动选择"
${group_items}  - name: "♻️ 自动选择"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
${group_items}rules:
  - GEOIP,CN,DIRECT
  - GEOSITE,CN,DIRECT
  - MATCH,"🚀 节点选择"
EOF
}

_build_singbox_json() {
    local server_ip="${1:-$(_get_public_ip)}"
    local outbounds="[]"
    local -a tags=()

    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)
        local name="${type}-${port}"
        [ -f "$METADATA_FILE" ] && name=$(jq -r ".protocols.\"$tag\".name // empty" "$METADATA_FILE" 2>/dev/null || echo "$name")
        [ -z "$name" ] && name="${type}-${port}"
        tags+=("$name")

        local obj=""
        case "$type" in
            vless)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local is_reality=$(echo "$line" | jq -r '(.tls.reality != null) and (.tls.reality != {})' 2>/dev/null)
                if [ "$is_reality" = "true" ]; then
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local sid=$(echo "$line" | jq -r '.tls.reality.short_id[0] // empty')
                    local flow=$(echo "$line" | jq -r '.users[0].flow // "xtls-rprx-vision"')
                    local pbk=$(jq -r ".protocols.\"$tag\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                    obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg uuid "$uuid" --arg flow "$flow" --arg sni "${sni:-$DEFAULT_SNI}" --arg pbk "$pbk" --arg sid "$sid" '{type:"vless",tag:$name,server:$ip,server_port:$port,uuid:$uuid,flow:$flow,tls:{enabled:true,server_name:$sni,reality:{enabled:true,public_key:$pbk,short_id:$sid}},transport:{type:"tcp"}}')
                else
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                    obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg uuid "$uuid" --arg sni "${sni:-$server_ip}" --arg path "$ws_path" '{type:"vless",tag:$name,server:$ip,server_port:$port,uuid:$uuid,tls:{enabled:true,insecure:true},transport:{type:"ws",path:$path}}')
                fi
                ;;
            anytls)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg pw "$pw" '{type:"anytls",tag:$name,server:$ip,server_port:$port,password:$pw,tls:{enabled:true,insecure:true}}')
                ;;
            tuic)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg uuid "$uuid" --arg pw "$pw" '{type:"tuic",tag:$name,server:$ip,server_port:$port,uuid:$uuid,password:$pw,tls:{enabled:true,alpn:["h3"],insecure:true},congestion_control:"bbr"}')
                ;;
            hysteria2)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg pw "$pw" '{type:"hysteria2",tag:$name,server:$ip,server_port:$port,password:$pw,tls:{enabled:true,insecure:true}}')
                ;;
            trojan)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                local insecure=$(jq -r ".protocols.\"$tag\".insecure // 1" "$METADATA_FILE" 2>/dev/null || echo 1)
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg pw "$pw" --arg sni "${sni:-$server_ip}" --argjson insecure "$insecure" '{type:"trojan",tag:$name,server:$ip,server_port:$port,password:$pw,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
                ;;
            shadowsocks)
                local psk=$(echo "$line" | jq -r '.password // empty')
                local method=$(echo "$line" | jq -r '.method // "2022-blake3-aes-256-gcm"')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg method "$method" --arg psk "$psk" '{type:"shadowsocks",tag:$name,server:$ip,server_port:$port,method:$method,password:$psk}')
                ;;
            socks)
                local u=$(echo "$line" | jq -r '.users[0].username // empty')
                local p=$(echo "$line" | jq -r '.users[0].password // empty')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg u "$u" --arg p "$p" '{type:"socks",tag:$name,server:$ip,server_port:$port,users:[{username:$u,password:$p}]}')
                ;;
            vmess)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                obj=$(jq -n --arg name "$name" --arg ip "$server_ip" --argjson port "$port" --arg uuid "$uuid" --arg path "$ws_path" '{type:"vmess",tag:$name,server:$ip,server_port:$port,uuid:$uuid,tls:{enabled:true,insecure:true},transport:{type:"ws",path:$path}}')
                ;;
        esac
        [ -n "$obj" ] && outbounds=$(echo "$outbounds" | jq --argjson o "$obj" '. + [$o]')
    done < <(_proto_list_inbounds 2>/dev/null)

    [ "$outbounds" = "[]" ] && { echo '{}'; return 0; }

    local taglist=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)
    local full=$(echo "$outbounds" | jq --argjson tags "$taglist" '
        . + [{type:"selector",tag:"proxy",outbounds:$tags},
              {type:"direct",tag:"direct"},
              {type:"dns",tag:"dns-out"}]')
    jq -n --argjson outs "$full" '
    {
      inbounds: [{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:7890}],
      outbounds: $outs,
      route: {
        rules: [
          {geoip:["cn"],outbound:"direct"},
          {geosite:["cn"],outbound:"direct"}
        ],
        final:"proxy",
        auto_detect_interface:true
      },
      dns: {
        servers:[{address:"1.1.1.1"},{address:"223.5.5.5",geoip:["cn"]}],
        final:"dns-out"
      }
    }'
}

_ui_subscription() {
    _require_singbox || return 1
    _ensure_node_metadata_names

    clear
    echo -e "${CYAN}=== 节点分享（订阅 + 二维码）===${NC}"
    echo ""

    local server_ip=$(_get_public_ip)
    echo -e "服务器 IP: ${GREEN}${server_ip}${NC}"
    [ -n "${SERVER_DOMAIN:-}" ] && echo -e "服务器域名: ${GREEN}${SERVER_DOMAIN}${NC}"
    echo ""

    # 收集所有节点 URI
    local -a node_names=()
    local -a node_uris=()
    local count=0
    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)

        count=$((count + 1))
        local name="${type}-${port}"
        if [ -f "$METADATA_FILE" ]; then
            local meta_name=$(jq -r ".protocols.\"$tag\".name // empty" "$METADATA_FILE" 2>/dev/null)
            [ -n "$meta_name" ] && name="$meta_name"
        fi
        node_names+=("$name")

        local uri=""
        case "$type" in
            vless)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local is_reality=$(echo "$line" | jq -r '(.tls.reality != null) and (.tls.reality != {})' 2>/dev/null)
                if [ "$is_reality" = "true" ]; then
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local sid=$(echo "$line" | jq -r '.tls.reality.short_id[0] // empty')
                    local flow=$(echo "$line" | jq -r '.users[0].flow // "xtls-rprx-vision"')
                    local pbk=$(jq -r ".protocols.\"$tag\".public_key // empty" "$METADATA_FILE" 2>/dev/null)
                    if [ -z "$pbk" ]; then
                        local priv=$(echo "$line" | jq -r '.tls.reality.private_key // empty')
                        [ -n "$priv" ] && pbk=$(_reality_pubkey_from_config "$priv")
                        [ -z "$pbk" ] && _warn "节点 $tag 无法获取 Reality 公钥 (metadata 缺失且私钥推导失败), 该 VLESS 链接将缺 pbk"
                    fi
                    uri=$(_proto_reality_uri "$uuid" "$server_ip" "$port" "${sni:-$DEFAULT_SNI}" "$sid" "$name" "$flow" "$pbk")
                else
                    local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                    local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                    uri=$(_proto_vless_ws_uri "$uuid" "$server_ip" "$port" "${sni:-$server_ip}" "$ws_path" "$name")
                fi
                ;;
            anytls)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                uri=$(_proto_anytls_uri "$pw" "$server_ip" "$port" "$name")
                ;;
            tuic)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                uri=$(_proto_tuic_uri "$uuid" "$pw" "$server_ip" "$port" "$name")
                ;;
            hysteria2)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                uri=$(_proto_hy2_uri "$pw" "$server_ip" "$port" "$name")
                ;;
            vmess)
                local uuid=$(echo "$line" | jq -r '.users[0].uuid // empty')
                local ws_path=$(echo "$line" | jq -r '.transport.path // "/ws"')
                uri=$(_proto_vmess_ws_standard_uri "$uuid" "$server_ip" "$port" "$ws_path" "$name")
                ;;
            trojan)
                local pw=$(echo "$line" | jq -r '.users[0].password // empty')
                local sni=$(echo "$line" | jq -r '.tls.server_name // empty')
                local insecure=$(jq -r ".protocols.\"$tag\".insecure // \"1\"" "$METADATA_FILE" 2>/dev/null || echo "1")
                uri=$(_proto_trojan_uri "$pw" "$server_ip" "$port" "$name" "${sni:-$server_ip}" "$insecure")
                ;;
            shadowsocks)
                local psk=$(echo "$line" | jq -r '.password // empty')
                local method=$(echo "$line" | jq -r '.method // "2022-blake3-aes-256-gcm"')
                uri=$(_proto_ss2022_uri "$method" "$psk" "$server_ip" "$port" "$name")
                ;;
            socks)
                local u=$(echo "$line" | jq -r '.users[0].username // empty')
                local p=$(echo "$line" | jq -r '.users[0].password // empty')
                uri=$(_proto_socks5_uri "$u" "$p" "$server_ip" "$port" "$name")
                ;;
        esac
        [ -n "$uri" ] && node_uris+=("$uri")
    done < <(_proto_list_inbounds 2>/dev/null)

    if [ "$count" -eq 0 ]; then
        echo "  暂无节点，请先添加节点（菜单 [1]）"
        echo ""
        read -p "按回车键返回..."
        return
    fi

    # 生成订阅内容（base64 编码，标准订阅格式：每行一个 URI）
    local sub_content=""
    local i
    for i in "${!node_uris[@]}"; do
        [ -n "$sub_content" ] && sub_content="${sub_content}"$'\n'
        sub_content="${sub_content}${node_uris[$i]}"
    done
    local sub_b64=$(printf '%s' "$sub_content" | base64 -w0 2>/dev/null || printf '%s' "$sub_content" | base64 | tr -d '\n')

    echo -e "${CYAN}【订阅链接】（复制整段，导入 v2rayN / 小火箭 / Clash 等客户端的「订阅」）${NC}"
    echo -e "${GREEN}${sub_b64}${NC}"
    echo ""
    echo -e "${YELLOW}提示: 订阅链接一次性包含所有节点，客户端更新订阅即可同步增删。${NC}"
    echo ""

    # --- Clash Meta YAML 订阅 (data-URI, 本地零托管) ---
    local clash_yaml=$(_build_clash_yaml "$server_ip")
    if [ -n "$clash_yaml" ]; then
        local clash_b64=$(printf '%s' "$clash_yaml" | base64 -w0 2>/dev/null | tr -d '\n')
        echo -e "${CYAN}【Clash Meta 订阅】(Clash Verge / Mihomo / OpenClash / 小火箭)${NC}"
        echo -e "${GREEN}data:text/yaml;base64,${clash_b64}${NC}"
        echo ""
    fi

    # --- Sing-box 原生 JSON 订阅 (data-URI) ---
    local sb_json=$(_build_singbox_json "$server_ip")
    if [ -n "$sb_json" ] && [ "$sb_json" != "{}" ]; then
        local sb_b64=$(printf '%s' "$sb_json" | base64 -w0 2>/dev/null | tr -d '\n')
        echo -e "${CYAN}【Sing-box 订阅】(SFA / SFI / SFW 官方客户端)${NC}"
        echo -e "${GREEN}data:application/json;base64,${sb_b64}${NC}"
        echo ""
    fi

    echo -e "${YELLOW}注: data-URI 可直接粘贴到支持「订阅链接」的客户端; 若客户端仅接受 http(s) 订阅,${NC}"
    echo -e "${YELLOW}   可将上面的 YAML / JSON 内容保存为 .yaml / .json 文件后本地导入。${NC}"
    echo ""

    # 二维码：移动端扫码导入单节点
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${CYAN}【二维码】输入节点编号可在终端显示该节点的扫码二维码${NC}"
        echo -e "  ${YELLOW}支持单个 (如 2) 或多个空格分隔 (如 1 3 4)；输入 0 返回${NC}"
        local j
        for j in "${!node_names[@]}"; do
            echo -e "    ${GREEN}[$((j+1))]${NC} ${node_names[$j]}"
        done
        echo ""
        # 最多重试 3 次, 避免无效输入直接静默返回
        local tries=0 valid=0
        while [ "$tries" -lt 3 ]; do
            read -p "  显示二维码 (0 返回): " qr_choice
            qr_choice=$(echo "$qr_choice" | tr -s ' ' | xargs)  # 去首尾/多余空格
            [ -z "$qr_choice" ] && { tries=$((tries+1)); continue; }
            if [ "$qr_choice" = "0" ]; then
                break
            fi
            valid=1
            local bad=0
            for n in $qr_choice; do
                if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#node_uris[@]}" ]; then
                    _warn "无效编号: $n (有效范围 1-${#node_uris[@]})"
                    bad=1
                    continue
                fi
                local qidx=$((n - 1))
                echo ""
                echo -e "${CYAN}扫码导入: ${node_names[$qidx]}${NC}"
                qrencode -t ANSIUTF8 "${node_uris[$qidx]}" || _warn "二维码生成失败 (qrencode 返回非零)"
                echo ""
            done
            [ "$bad" -eq 0 ] && break
            tries=$((tries+1))
        done
        [ "$valid" -eq 0 ] && echo -e "${YELLOW}(未选择节点)${NC}"
    else
        echo -e "${YELLOW}【二维码】未安装 qrencode，无法显示终端二维码。${NC}"
        echo -e "  安装: ${GREEN}apt-get install -y qrencode${NC} (Debian/Ubuntu) 或 ${GREEN}pkg install qrencode${NC} (FreeBSD)"
        echo ""
    fi

    read -p "按回车键返回..."
}

_ui_delete_node() {
    _require_singbox || return 1

    clear
    echo -e "${CYAN}=== 删除节点 ===${NC}"
    echo ""

    local tags=()
    local ports=()
    while IFS= read -r line; do
        local tag=$(echo "$line" | jq -r .tag)
        local type=$(echo "$line" | jq -r .type)
        local port=$(echo "$line" | jq -r .listen_port)
        tags+=("$tag")
        ports+=("$port")
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
        local sel_port="${ports[$idx]}"

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
    read -p "  新端口 (回车保持不变): " new_port

    # 新端口为空时保持不变
    [ -z "$new_port" ] && { _info "未修改，返回"; read -p "按回车键返回..."; return; }

    # 验证端口号
    [[ ! "$new_port" =~ ^[0-9]+$ ]] && { _error "无效端口号"; read -p "按回车键返回..."; return; }
    [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ] && { _error "端口号范围 1-65535"; read -p "按回车键返回..."; return; }

    # 端口有变化才检查占用
    if [ "$new_port" != "$sel_port" ]; then
        local proto="tcp"
        case "$sel_type" in tuic|hysteria2) proto="udp" ;; esac
        if _check_port_occupied "$new_port" "$proto"; then
            _error "端口 ${new_port} 已被占用"
            read -p "按回车键返回..."
            return
        fi

        # 端口变化 → 自动更新名称（只替换【末尾】的旧端口号后缀，避免误伤中间带数字的名称段）
        # 例如 VLESS-Reality-13190 → VLESS-Reality-13191
        # 或 RackNerd-美国黑五-vless-reality → RackNerd-美国黑五-vless-reality-13191
        # 用 % 后缀删除（锚定结尾），而非 ${var/pattern/repl} 的「首个出现」替换（会从第一个 -数字 一路删到末尾）
        sel_name="${sel_name%-[0-9]*}-${new_port}"
        # 若名称本不以 -数字 结尾（纯自定义名），上面不会删到任何东西，这里兜底追加 -新端口
        if ! echo "$sel_name" | grep -qE "[0-9]+$" && ! echo "$sel_name" | grep -qE "${new_port}$"; then
            sel_name="${sel_name}-${new_port}"
        fi
    fi

    # 计算新 tag（tag 里嵌了端口，同样只替换末尾端口段）
    local new_tag="${sel_tag%-[0-9]*}-${new_port}"
    if ! echo "$new_tag" | grep -qE "[0-9]+$" && ! echo "$new_tag" | grep -qE "${new_port}$"; then
        new_tag="${sel_tag}-${new_port}"
    fi

    # 备份配置
    _sb_backup_config 2>/dev/null || true

    # 修改 config.json: 更新 tag 和端口
    _atomic_modify_json "$CONFIG_FILE" \
        "(.inbounds[] | select(.tag==\"$sel_tag\") | .tag) = \"$new_tag\"" || {
        _error "配置修改失败"
        read -p "按回车键返回..."
        return
    }
    _atomic_modify_json "$CONFIG_FILE" \
        "(.inbounds[] | select(.tag==\"$new_tag\") | .listen_port) = $new_port" || {
        _error "配置修改失败"
        read -p "按回车键返回..."
        return
    }

    # 更新元数据: 删除旧 key，插入新 key
    if [ -f "$METADATA_FILE" ]; then
        local meta_exists=$(jq -r ".protocols.\"$sel_tag\" // empty" "$METADATA_FILE" 2>/dev/null)
        if [ -n "$meta_exists" ]; then
            local meta_entry=$(jq -r ".protocols.\"$sel_tag\"" "$METADATA_FILE" 2>/dev/null)
            _atomic_modify_json "$METADATA_FILE" "del(.protocols.\"$sel_tag\")" 2>/dev/null
            local meta_json=$(echo "$meta_entry" | jq --arg port "$new_port" --arg name "$sel_name" \
                '. + {port: ($port|tonumber), name: $name}')
            _atomic_modify_json "$METADATA_FILE" ".protocols += {\"$new_tag\": $meta_json}" 2>/dev/null
        fi
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
    # 强制杀掉残留的手动后台进程（非 systemd/openrc 管理的情况下）
    pkill -f "sing-box run" 2>/dev/null || true
    sleep 1
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
# 健康检查（菜单 14）
# ============================================================

_ui_health_check() {
    clear
    _sb_health_check
    read -p "按回车键返回..."
}

# ============================================================
# 升级脚本（菜单 15）
# ============================================================

_ui_upgrade_scripts() {
    clear
    _sb_upgrade_scripts
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _ui_main_menu
fi
