#!/bin/bash
# ============================================================
# core.sh — Singbox-Pro 核心工具模块
# 被 sb.sh source 加载，也可独立运行进行环境检测
# ============================================================
# 管理脚本版本号 SSOT（唯一字面量来源）:
#   所有模块 *_MOD_VERSION / SCRIPT_VERSION 都引用它，改版本号只需改这一处。
export PROJECT_VERSION="2.0.9"
export SCRIPT_VERSION="${PROJECT_VERSION}"

# --- 颜色定义 ---
if [ -z "${RED:-}" ]; then
    export RED='\033[0;31m'
    export GREEN='\033[0;32m'
    export YELLOW='\033[0;33m'
    export CYAN='\033[0;36m'
    export BLUE='\033[0;34m'
    export ORANGE='\033[0;33m'
    export NC='\033[0m'
fi

# --- 打印函数 (强制输出到 stderr，防止干扰变量捕获) ---
# 注意：每个函数独立判断是否已定义。
# 此前把全部函数绑在 `if ! declare -f _info` 下，若调用方（如 install.sh）已定义
# _info，则 _success/_error 等会被整体跳过导致「command not found」。
# 改为逐个守卫后，无论调用方定义了哪些，缺的函数都会被补全。
if ! declare -f _info >/dev/null 2>&1; then
    _info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
fi
if ! declare -f _success >/dev/null 2>&1; then
    _success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
fi
if ! declare -f _warn >/dev/null 2>&1; then
    _warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
fi
if ! declare -f _warning >/dev/null 2>&1; then
    _warning() { _warn "$1"; }  # 别名兼容
fi
if ! declare -f _ok >/dev/null 2>&1; then
    _ok()      { _success "$1"; }  # 别名兼容
fi
if ! declare -f _error >/dev/null 2>&1; then
    _error()   { echo -e "${RED}[错误] $1${NC}" >&2; }
fi

# --- 根权限检测 ---
if ! declare -f _check_root >/dev/null 2>&1; then
    _check_root() {
        if [[ $EUID -ne 0 ]]; then
            _error "此脚本必须以 root 权限运行。"
            exit 1
        fi
    }
fi

# --- URL 编解码 ---
if ! declare -f _url_decode >/dev/null 2>&1; then
    _url_decode() {
        local data="${1//+/ }"
        printf '%b' "${data//%/\\x}"
    }
fi

if ! declare -f _url_encode >/dev/null 2>&1; then
    _url_encode() {
        printf '%s' "$1" | jq -sRr @uri
    }
fi

# --- SS Base64 编码 (无 Padding) ---
if ! declare -f _ss_base64_encode >/dev/null 2>&1; then
    _ss_base64_encode() {
        printf '%s' "$1" | base64 | tr -d '\n\r ' | sed 's/=//g'
    }
fi

# --- 系统环境检测 ---
if ! declare -f _detect_init_system >/dev/null 2>&1; then
    _detect_init_system() {
        # systemd 真正可用需 PID1 为 systemd（/run/systemd/system 目录存在）。
        # 部分容器/虚拟化环境带有 systemctl 二进制但并未运行 systemd，
        # 此时若误判为 systemd，会导致 unit 文件写了却启动不了（Unit not found）。
        if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
            export INIT_SYSTEM="systemd"
            export SERVICE_FILE="/etc/systemd/system/sing-box.service"
        elif command -v rc-service &>/dev/null || [ -f /sbin/openrc-run ]; then
            export INIT_SYSTEM="openrc"
            export SERVICE_FILE="/etc/init.d/sing-box"
        else
            # 无可用 init 系统（常见于面板/虚拟化容器），用 nohup 直接拉起
            export INIT_SYSTEM="nohup"
            export SERVICE_FILE=""
        fi
    }
fi
# --- 架构检测 (SSOT，被 install.sh/singbox.sh/argo.sh/warp.sh 共用) ---
if ! declare -f _get_arch >/dev/null 2>&1; then
    _get_arch() {
        local arch=$(uname -m)
        case $arch in
            x86_64|amd64) echo "amd64" ;;
            aarch64|arm64) echo "arm64" ;;
            armv7l)        echo "armv7" ;;
            *)             echo "amd64" ;;
        esac
    }
fi

[ -z "${INIT_SYSTEM:-}" ] && _detect_init_system

# --- 系统信息获取 ---
if ! declare -f _get_os_info >/dev/null 2>&1; then
    _get_os_info() {
        local os_info="未知"
        if [ -f /etc/os-release ]; then
            os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
            [ -z "$os_info" ] && os_info=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
        fi
        [ -z "$os_info" ] && os_info=$(uname -s)
        echo "$os_info"
    }
fi

# --- 公网 IP (带全局缓存) ---
# NAT VPS 环境下 API 返回的出口 IP 可能不等于面板分配的端口映射 IP
# 设置 SERVER_IP_OVERRIDE 强制使用指定 IP，例如:
#   export SERVER_IP_OVERRIDE=108.62.161.75 && bash sb.sh
server_ip=""
if ! declare -f _get_public_ip >/dev/null 2>&1; then
    _get_public_ip() {
        [ -n "$server_ip" ] && [ "$server_ip" != "null" ] && { echo "$server_ip"; return; }
        local ip

        # 最高优先级：手动覆盖 (NAT VPS 场景)
        if [ -n "${SERVER_IP_OVERRIDE:-}" ]; then
            server_ip="$SERVER_IP_OVERRIDE"
            echo "$server_ip"
            return
        fi

        # 从网卡读取真实 IP (避免 wgcf/WARP 劫持公网 API)
        ip=$(ip -4 addr show scope global 2>/dev/null | grep -v 'docker\|br-\|veth\|wgcf\|lo' | grep -oP 'inet \K[\d.]+' | head -1)
        if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.)'; then
            server_ip="$ip"
            echo "$ip"
            return
        fi

        # 网卡无公网 IP → API 查询
        ip=$(timeout 5 curl -s4 --max-time 2 icanhazip.com 2>/dev/null || \
             timeout 5 curl -s4 --max-time 2 ipinfo.io/ip 2>/dev/null || \
             timeout 5 curl -s4 --max-time 2 ifconfig.me 2>/dev/null || \
             timeout 5 curl -s4 --max-time 2 ip.sb 2>/dev/null)
        [ -z "$ip" ] && ip=$(timeout 5 curl -s6 --max-time 2 icanhazip.com 2>/dev/null || \
                              timeout 5 curl -s6 --max-time 2 ipinfo.io/ip 2>/dev/null)
        server_ip="$ip"
        echo "$ip"
    }
fi
_get_ip() { _get_public_ip; }

# --- IPv6 (带缓存) ---
ipv6_cache=""
_get_ipv6() {
    [ -n "$ipv6_cache" ] && [ "$ipv6_cache" != "null" ] && { echo "$ipv6_cache"; return; }
    local ip6
    ip6=$(timeout 3 curl -s6 --max-time 2 icanhazip.com 2>/dev/null || \
          timeout 3 curl -s6 --max-time 2 ifconfig.me 2>/dev/null || \
          timeout 3 curl -s6 --max-time 2 ipv6.icanhazip.com 2>/dev/null)
    [ -z "$ip6" ] && ipv6_cache="无" || ipv6_cache="$ip6"
    echo "$ipv6_cache"
}

# --- BBR 状态 ---
_get_bbr() {
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    [ -z "$cc" ] && { echo -e "${RED}?${NC}"; return; }
    if echo "$cc" | grep -qi "bbr"; then
        echo -e "${GREEN}${cc}${NC}"
    else
        echo -e "${YELLOW}${cc}${NC}"
    fi
}

# --- 国家代码 → 中文名称 ---
_country_cn() {
    case "$1" in
        US) echo "美国" ;;
        JP) echo "日本" ;;
        HK) echo "香港" ;;
        SG) echo "新加坡" ;;
        DE) echo "德国" ;;
        GB) echo "英国" ;;
        NL) echo "荷兰" ;;
        FR) echo "法国" ;;
        KR) echo "韩国" ;;
        CA) echo "加拿大" ;;
        AU) echo "澳大利亚" ;;
        IN) echo "印度" ;;
        BR) echo "巴西" ;;
        RU) echo "俄罗斯" ;;
        TW) echo "台湾" ;;
        CN) echo "中国" ;;
        VN) echo "越南" ;;
        TH) echo "泰国" ;;
        MY) echo "马来西亚" ;;
        ID) echo "印度尼西亚" ;;
        PH) echo "菲律宾" ;;
        SE) echo "瑞典" ;;
        CH) echo "瑞士" ;;
        IT) echo "意大利" ;;
        ES) echo "西班牙" ;;
        *) echo "$1" ;;
    esac
}

# --- VPS 地区 (带缓存，多 API 回退) ---
region_cache=""
_get_region() {
    [ -n "$region_cache" ] && { echo "$region_cache"; return; }
    local data country city country_cn

    # 尝试主 API: ipinfo.io
    data=$(timeout 3 curl -s --max-time 2 'https://ipinfo.io/json' 2>/dev/null)
    if [ -z "$data" ] || ! echo "$data" | jq -e '.country' >/dev/null 2>&1; then
        # 备用 API: ip-api.com
        data=$(timeout 3 curl -s --max-time 2 'http://ip-api.com/json/?fields=country,city' 2>/dev/null)
    fi
    if [ -z "$data" ] || ! echo "$data" | jq -e '.country' >/dev/null 2>&1; then
        # 备用 API: freeipapi.com
        data=$(timeout 3 curl -s --max-time 2 'https://freeipapi.com/api/json' 2>/dev/null)
    fi

    if [ -n "$data" ]; then
        country=$(echo "$data" | jq -r '.country // .countryCode // .country_code // ""' 2>/dev/null)
        city=$(echo "$data" | jq -r '.city // .cityName // ""' 2>/dev/null)
        if [ -n "$country" ] && [ "$country" != "null" ]; then
            country_cn=$(_country_cn "$country")
            [ -n "$city" ] && [ "$city" != "null" ] && region_cache="${country_cn} ${city}" || region_cache="${country_cn}"
        fi
    fi

    [ -z "$region_cache" ] && region_cache="未知"
    echo "$region_cache"
}

# --- 端口占用检查 ---
if ! declare -f _check_port_occupied >/dev/null 2>&1; then
    _check_port_occupied() {
        local port=$1 proto=${2:-tcp}
        if [[ "$proto" == "tcp" ]]; then
            command -v ss &>/dev/null && ss -lnpt 2>/dev/null | grep -q ":${port} " && return 0
            netstat -lnpt 2>/dev/null | grep -q ":${port} " && return 0
        else
            command -v ss &>/dev/null && ss -lnpu 2>/dev/null | grep -q ":${port} " && return 0
            netstat -lnpu 2>/dev/null | grep -q ":${port} " && return 0
        fi
        return 1
    }
fi

# --- JSON 原子修改 ---
if ! declare -f _atomic_modify_json >/dev/null 2>&1; then
    _atomic_modify_json() {
        local file="$1" filter="$2"
        [ ! -f "$file" ] && return 1
        local tmp="${file}.tmp"
        if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$file"
        else
            _error "JSON 修改失败: $file"
            rm -f "$tmp"
            return 1
        fi
    }
fi

# --- 包管理器抽象 ---
if ! declare -f _pkg_install >/dev/null 2>&1; then
    _pkg_install() {
        local pkgs="$*"
        [ -z "$pkgs" ] && return 0
        if command -v apk &>/dev/null; then
            apk add --no-cache $pkgs >/dev/null 2>&1
        elif command -v apt-get &>/dev/null; then
            if [ ! -d "/var/lib/apt/lists" ] || [ "$(ls -A /var/lib/apt/lists/ 2>/dev/null | wc -l)" -le 1 ]; then
                apt-get update -qq >/dev/null 2>&1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 || {
                apt-get update -qq >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1
            }
        elif command -v yum &>/dev/null; then yum install -y $pkgs >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then dnf install -y $pkgs >/dev/null 2>&1
        fi
    }
fi

# --- 统一服务管理 ---
if ! declare -f _manage_service >/dev/null 2>&1; then
    _manage_service() {
        local action="$1"
        [ -z "$INIT_SYSTEM" ] && _detect_init_system

        case "$INIT_SYSTEM" in
            systemd)
                if [ "$action" == "status" ]; then
                    systemctl status sing-box --no-pager -l
                    return
                fi
                _info "正在使用 systemd 执行: $action..."
                # unit 文件缺失则先自愈创建（install 阶段可能未写入）
                if [ ! -f "$SERVICE_FILE" ] && command -v _sb_setup_service &>/dev/null; then
                    _sb_setup_service 2>/dev/null || true
                fi
                if systemctl "$action" sing-box 2>/dev/null; then
                    return 0
                fi
                _warn "systemctl ${action} 失败，回退 nohup 直接拉起..."
                _sb_manage_nohup "$action"
                ;;
            openrc)
                if [ "$action" == "status" ]; then
                    rc-service sing-box status
                else
                    _info "正在使用 OpenRC 执行: $action..."
                    rc-service sing-box "$action"
                fi
                ;;
            nohup)
                _sb_manage_nohup "$action"
                ;;
            *)
                _error "不支持的服务管理系统: $INIT_SYSTEM"
                ;;
        esac
    }
fi

# --- IPTables 规则持久化 ---
if ! declare -f _save_iptables_rules >/dev/null 2>&1; then
    _save_iptables_rules() {
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        else
            if command -v iptables-save &>/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
            fi
            if command -v ip6tables-save &>/dev/null; then
                mkdir -p /etc/iptables
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            fi
        fi
        if command -v rc-service &>/dev/null; then
            rc-service iptables save 2>/dev/null || true
            rc-service ip6tables save 2>/dev/null || true
        fi
    }
fi

# --- 随机端口生成 ---
if ! declare -f _random_port >/dev/null 2>&1; then
    _random_port() {
        local range_min=${1:-10000} range_max=${2:-60000}
        echo $(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % (range_max - range_min + 1) + range_min ))
    }
fi

# --- 随机密码/ID 生成 ---
if ! declare -f _random_hex >/dev/null 2>&1; then
    _random_hex() {
        local len=${1:-16}
        openssl rand -hex "$len" 2>/dev/null || \
            cat /dev/urandom | tr -dc 'a-f0-9' | head -c "$len"
    }
fi

# --- 端口监听验证 (用于部署后检查) ---
if ! declare -f _verify_port_listen >/dev/null 2>&1; then
    _verify_port_listen() {
        local port=$1 proto=${2:-tcp}
        if [[ "$proto" == "tcp" ]]; then
            ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
        else
            ss -ulnp 2>/dev/null | grep -q ":${port} " && return 0
        fi
        return 1
    }
fi

# --- DNS 解析检测 (统一工具，避免混用 nslookup/dig/host 的返回值) ---
# 用法: _dns_resolve <domain>
# 成功(退出码0) 输出解析到的首个 IP；失败(退出码1) 输出为空
if ! declare -f _dns_resolve >/dev/null 2>&1; then
    _dns_resolve() {
        local domain="$1" ip=""
        if command -v dig &>/dev/null; then
            ip=$(dig +short +time=3 +tries=1 "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$' | head -1)
        elif command -v nslookup &>/dev/null; then
            ip=$(nslookup "$domain" 2>/dev/null | awk -F': ' '/^Address: / {print $2}' | grep -E '^[0-9a-fA-F:.]+$' | head -1)
        elif command -v host &>/dev/null; then
            ip=$(host "$domain" 2>/dev/null | awk '/has (address|IPv6 address)/ {print $NF; exit}')
        fi
        [ -n "$ip" ] && { echo "$ip"; return 0; }
        return 1
    }
fi

# --- 文件下载 (多重试) ---
if ! declare -f _download >/dev/null 2>&1; then
    _download() {
        local url="$1" target="$2"
        curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$target" 2>/dev/null || \
        wget -qO "$target" "$url" 2>/dev/null
    }
fi

# --- Sing-box 版本号 (SSOT - 唯一来源) ---
export SB_VERSION="1.13.14"

# --- GitHub 镜像源 (可被 GH_MIRROR 环境变量覆盖，默认 ghproxy.net) ---
export GH_PROXY="${GH_MIRROR:-https://ghproxy.net/}"

# --- 核心路径定义 ---
export SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
export SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
export CONFIG_FILE="${CONFIG_FILE:-${SINGBOX_DIR}/config.json}"
export METADATA_FILE="${METADATA_FILE:-${SINGBOX_DIR}/metadata.json}"
export ARGO_METADATA_FILE="${ARGO_METADATA_FILE:-${SINGBOX_DIR}/argo_metadata.json}"
export CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"

# --- 独立运行时的环境检测 ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro Core v${PROJECT_VERSION} ==="
    echo ""
    echo "系统: $(_get_os_info)"
    echo "Init:  ${INIT_SYSTEM:-未检测}"
    echo "IP:    $(_get_public_ip)"
    echo ""
    echo "核心模块加载成功。此模块被 sb.sh 自动 source，无需独立运行。"
fi
