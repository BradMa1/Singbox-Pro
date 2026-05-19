#!/bin/bash
# ============================================================
# core.sh — Singbox-Pro 核心工具模块
# 被 sb.sh source 加载，也可独立运行进行环境检测
# ============================================================
export CORE_VERSION="2.0.0"

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
if ! declare -f _info >/dev/null 2>&1; then
    _info()    { echo -e "${CYAN}[信息] $1${NC}" >&2; }
    _success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
    _warn()    { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
    _warning() { _warn "$1"; }  # 别名兼容
    _ok()      { _success "$1"; }  # 别名兼容
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
        if [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
            export INIT_SYSTEM="openrc"
            export SERVICE_FILE="/etc/init.d/sing-box"
        elif command -v systemctl &>/dev/null; then
            export INIT_SYSTEM="systemd"
            export SERVICE_FILE="/etc/systemd/system/sing-box.service"
        else
            export INIT_SYSTEM="unknown"
            export SERVICE_FILE=""
        fi
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
server_ip=""
if ! declare -f _get_public_ip >/dev/null 2>&1; then
    _get_public_ip() {
        [ -n "$server_ip" ] && [ "$server_ip" != "null" ] && { echo "$server_ip"; return; }
        local ip

        # 优先从网卡读取真实 IP (避免 wgcf/WARP 劫持公网 API)
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
    [ -z "$cc" ] && { echo "${RED}?${NC}"; return; }
    if echo "$cc" | grep -qi "bbr"; then
        echo "${GREEN}${cc}${NC}"
    else
        echo "${YELLOW}${cc}${NC}"
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
                else
                    _info "正在使用 systemd 执行: $action..."
                    systemctl "$action" sing-box
                fi
                ;;
            openrc)
                if [ "$action" == "status" ]; then
                    rc-service sing-box status
                else
                    _info "正在使用 OpenRC 执行: $action..."
                    rc-service sing-box "$action"
                fi
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

# --- 文件下载 (多重试) ---
if ! declare -f _download >/dev/null 2>&1; then
    _download() {
        local url="$1" target="$2"
        curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$target" 2>/dev/null || \
        curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$target" 2>/dev/null || \
        wget -qO "$target" "$url" 2>/dev/null
    }
fi

# --- 核心路径定义 ---
export SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
export SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
export CONFIG_FILE="${CONFIG_FILE:-${SINGBOX_DIR}/config.json}"
export METADATA_FILE="${METADATA_FILE:-${SINGBOX_DIR}/metadata.json}"
export ARGO_METADATA_FILE="${ARGO_METADATA_FILE:-${SINGBOX_DIR}/argo_metadata.json}"
export CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"

# --- 导出所有函数供子模块使用 ---
export -f _info _success _warn _warning _error 2>/dev/null || true
export -f _check_root _url_encode _url_decode _ss_base64_encode 2>/dev/null || true
export -f _detect_init_system _get_os_info _get_public_ip _get_ip 2>/dev/null || true
export -f _check_port_occupied _atomic_modify_json _pkg_install 2>/dev/null || true
export -f _manage_service _save_iptables_rules _random_port _random_hex 2>/dev/null || true
export -f _verify_port_listen _download 2>/dev/null || true

# --- 独立运行时的环境检测 ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro Core v${CORE_VERSION} ==="
    echo ""
    echo "系统: $(_get_os_info)"
    echo "Init:  ${INIT_SYSTEM:-未检测}"
    echo "IP:    $(_get_public_ip)"
    echo ""
    echo "核心模块加载成功。此模块被 sb.sh 自动 source，无需独立运行。"
fi
