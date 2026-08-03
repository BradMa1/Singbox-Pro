#!/bin/bash
# ============================================================
# cert.sh — Singbox-Pro 证书管理模块 (acme.sh 真实证书签发)
# ============================================================
# 背景:
#   - AnyTLS/TUIC/Hy2/VLESS-WS 当前用自签证书 (SAN 含公网 IP) + insecure=1 跳过验证;
#   - Trojan 主打「真证书 HTTPS 外形」, 用自签也能跑但 stealth 意义打折;
#     用 acme.sh 签发的 Let's Encrypt 真实证书, Trojan 才真正像「正常 HTTPS 网站」,
#     且对纯 Xray 客户端也无需 insecure。
# 设计:
#   - 复用 acme.sh (社区标准), 支持 standalone (端口80) 与 DNS (CF 等) 两种签发;
#   - 签发后证书统一落地到 ${SINGBOX_DIR}/acme/<domain>/, 不污染自签证书;
#   - 元数据存 ${SINGBOX_DIR}/cert_metadata.json, 供 Trojan 等按需选取真证书。
# ============================================================
export CERT_MOD_VERSION="${PROJECT_VERSION}"

# --- 函数继承检测 ---
if ! declare -f _info >/dev/null 2>&1; then
    SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
    source "${SCRIPT_DIR}/core.sh" 2>/dev/null || {
        echo "[错误] 无法加载 core.sh"
        exit 1
    }
fi

ACME_BIN="${ACME_BIN:-$HOME/.acme.sh/acme.sh}"
ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
CERT_META_FILE="${CERT_META_FILE:-${SINGBOX_DIR}/cert_metadata.json}"
CERT_ACME_DIR="${CERT_ACME_DIR:-${SINGBOX_DIR}/acme}"

# ============================================================
# acme.sh 安装
# ============================================================
_cert_acme_install() {
    if [ -x "$ACME_BIN" ]; then
        _info "acme.sh 已安装: $($ACME_BIN --version 2>/dev/null | head -1)"
        return 0
    fi

    _info "正在安装 acme.sh (社区标准 Let's Encrypt 客户端)..."
    # 优先官方一键脚本
    if curl -sL https://get.acme.sh -o /tmp/acme_install.sh 2>/dev/null; then
        chmod +x /tmp/acme_install.sh
        if /tmp/acme_install.sh 2>&1 | tail -3; then
            rm -f /tmp/acme_install.sh
        fi
    fi

    if [ ! -x "$ACME_BIN" ]; then
        # 回退: git clone 安装
        _warn "一键脚本失败，尝试 git clone 方式..."
        local tmp=$(mktemp -d)
        if git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/acme.sh" 2>/dev/null; then
            (cd "$tmp/acme.sh" && ./acme.sh --install 2>&1 | tail -3)
            rm -rf "$tmp"
        fi
    fi

    if [ -x "$ACME_BIN" ]; then
        _success "acme.sh 安装完成: $ACME_BIN"
        return 0
    fi

    _error "acme.sh 安装失败，请手动安装: https://github.com/acmesh-official/acme.sh"
    return 1
}

# ============================================================
# 签发证书 (standalone 默认; 支持 DNS 通过环境变量)
# ============================================================
# 参数: $1 域名  $2 邮箱(可选, 用于注册 LET'S ENCRYPT 账号)
# 说明:
#   - standalone 模式需要 80 端口空闲且公网可达 (Let's Encrypt 会访问 http://域名/.well-known);
#     若 80 被占用或不通, 改用 DNS 模式: 设置对应 DNS 服务商的 API 环境变量后重跑,
#     例如 Cloudflare: export CF_Token=xxx CF_Account_ID=yyy
#   - 签发成功后证书复制到 ${CERT_ACME_DIR}/<domain>/ 供 sing-box 使用
_cert_acme_issue() {
    local domain="$1" email="${2:-}"
    [ -z "$domain" ] && { _error "签发证书需要域名"; return 1; }

    _cert_acme_install || return 1

    # 提前确保 80 端口可达 (standalone)
    if _check_port_occupied 80 "tcp" 2>/dev/null; then
        _warn "端口 80 (TCP) 已被占用，standalone 签发可能失败。"
        _warn "若失败请改用 DNS 模式: 设置 CF_Token/CF_Account_ID 等环境变量后重跑, 或临时释放 80 端口。"
    fi

    local issue_args=(--issue -d "$domain" --keylength ec-256)
    if [ -n "$email" ]; then
        issue_args+=(--accountemail "$email")
    fi

    # 检测 DNS API 环境变量 (以 _Token / _Key 结尾的变量) 自动切换 DNS 模式
    local dns_mode=""
    if env | grep -qiE '^(CF_Token|Ali_Key|DP_Id|DNSPOD_|GANDI_|OCI_)' ; then
        dns_mode="detected"
    fi

    if [ -n "$dns_mode" ]; then
        _info "检测到 DNS API 环境变量，使用 DNS-01 挑战 (无需开放 80 端口)..."
        # 让 acme.sh 自己根据环境变量选 DNS 插件 (--dns dns_cf 等需对应插件,
        # 这里采用 acme.sh 的自动识别: 仅传 --dns 由环境变量驱动时不指定具体插件,
        # 实际由 acme.sh 按变量后缀推断; 为稳妥这里交给用户确保变量正确)
        if ! "$ACME_BIN" "${issue_args[@]}" --dns ; then
            _error "DNS 模式签发失败，请检查 DNS API 环境变量是否正确"
            return 1
        fi
    else
        _info "使用 standalone 模式签发 (需 80 端口公网可达)..."
        if ! "$ACME_BIN" "${issue_args[@]}" --standalone ; then
            _error "standalone 签发失败。常见原因: 80 端口被占用/未放行, 或域名未解析到本机。"
            _error "解决: 放行 80 端口后重跑, 或改用 DNS 模式 (设置 CF_Token 等环境变量)。"
            return 1
        fi
    fi

    # 复制证书到统一目录
    mkdir -p "${CERT_ACME_DIR}/${domain}"
    if ! "$ACME_BIN" --install-cert -d "$domain" \
        --fullchain-file "${CERT_ACME_DIR}/${domain}/fullchain.pem" \
        --key-file "${CERT_ACME_DIR}/${domain}/privkey.pem" 2>/dev/null; then
        # 回退: 直接复制 acme.sh 仓库内证书
        local src_dir="${ACME_HOME}/${domain}"
        cp -f "${src_dir}/fullchain.cer" "${CERT_ACME_DIR}/${domain}/fullchain.pem" 2>/dev/null || true
        cp -f "${src_dir}/${domain}.key" "${CERT_ACME_DIR}/${domain}/privkey.pem" 2>/dev/null || true
    fi

    if [ -f "${CERT_ACME_DIR}/${domain}/fullchain.pem" ] && [ -f "${CERT_ACME_DIR}/${domain}/privkey.pem" ]; then
        chmod 644 "${CERT_ACME_DIR}/${domain}/fullchain.pem"
        chmod 600 "${CERT_ACME_DIR}/${domain}/privkey.pem"
        _success "证书已签发并落地: ${CERT_ACME_DIR}/${domain}/"
        _cert_save_meta "$domain"
        # 持久化默认域名: 让 _cert_trojan_paths / _proto_trojan_config 的 sni 兜底能自动取到,
        # 否则 SERVER_DOMAIN 为空 -> Trojan 永远回退自签 (证书白签)。
        # 仅当尚未设置时才覆盖, 尊重用户手动指定的 SERVER_DOMAIN 环境变量。
        if [ -z "${SERVER_DOMAIN:-}" ]; then
            echo "$domain" > "${SINGBOX_DIR}/.server_domain"
            _info "已将 ${domain} 设为默认 Trojan 域名 (写入 ${SINGBOX_DIR}/.server_domain)"
        fi
        return 0
    fi

    _error "证书签发成功但落地失败，请检查 ${CERT_ACME_DIR} 权限"
    return 1
}

# ============================================================
# 续期 (acme.sh 自带 cron, 这里提供手动触发)
# ============================================================
_cert_acme_renew() {
    local domain="${1:-}"
    _cert_acme_install || return 1
    if [ -n "$domain" ]; then
        _info "续期: $domain"
        "$ACME_BIN" --renew -d "$domain" --force 2>&1 | tail -5
    else
        _info "续期全部证书..."
        "$ACME_BIN" --renew-all 2>&1 | tail -10
    fi
    # 重新落地
    [ -n "$domain" ] && _cert_acme_issue "$domain" >/dev/null 2>&1
    _success "续期完成 (已签证书会在 30 天内自动由 acme.sh cron 续期)"
}

# ============================================================
# 读取已签发证书路径 (优先 acme 真证书)
# ============================================================
# 返回: "<cert_path> <key_path>"  (找到 acme 证书时); 否则返回空 (调用方回退自签)
_cert_acme_paths() {
    local domain="$1"
    [ -z "$domain" ] && return 1
    local cert="${CERT_ACME_DIR}/${domain}/fullchain.pem"
    local key="${CERT_ACME_DIR}/${domain}/privkey.pem"
    [ -f "$cert" ] && [ -f "$key" ] && { echo "${cert} ${key}"; return 0; }
    return 1
}

# Trojan 专用: 返回 (cert, key, sni, insecure) 四元组
#   域名解析优先级: SERVER_DOMAIN 变量 > .server_domain 持久化文件 > cert_metadata.json 首个已签发域名
#   - 命中且有 acme 证书 → 用真证书, insecure=0, sni=域名
#   - 否则 → 自签证书, insecure=1, sni=自签占位
_cert_trojan_paths() {
    local domain="${SERVER_DOMAIN:-}"
    if [ -z "$domain" ] && [ -f "${SINGBOX_DIR}/.server_domain" ]; then
        domain="$(cat "${SINGBOX_DIR}/.server_domain" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -z "$domain" ] && [ -f "$CERT_META_FILE" ]; then
        domain="$(jq -r 'keys[0] // empty' "$CERT_META_FILE" 2>/dev/null)"
    fi
    if [ -n "$domain" ]; then
        local paths
        paths=$(_cert_acme_paths "$domain") && {
            local cert=$(echo "$paths" | awk '{print $1}')
            local key=$(echo "$paths" | awk '{print $2}')
            echo "${cert} ${key} ${domain} 0"
            return 0
        }
        _warn "域名 ${domain} 无 acme 证书, Trojan 将使用自签证书 (stealth 降级, 需客户端 insecure=1)"
    fi
    echo "${SINGBOX_DIR}/cert.pem ${SINGBOX_DIR}/key.pem ${domain:-www.example.com} 1"
}

# ============================================================
# 签发成功后重写已有 Trojan 节点 -> 真证书 (无需手动删节点重加)
# ============================================================
# 痛点: 用户常在「自签」阶段就添加了 Trojan 节点, 之后才 sb cert issue 签真证书;
#   旧逻辑需手动删节点重加才能用上真证书。此处自动重写 config.json inbound
#   (cert/key/server_name) 与 metadata (sni/insecure=0), 并重启 sing-box。
# 参数: $1 域名
_cert_rewrite_trojan_nodes() {
    local domain="$1"
    [ -z "$domain" ] && return 0
    # 仅当 sing-box 配置/元数据可用时执行 (经 sb.sh 加载时必可用)
    [ -z "${CONFIG_FILE:-}" ] || [ -z "${METADATA_FILE:-}" ] && {
        _warn "CONFIG_FILE/METADATA_FILE 未设置, 跳过 Trojan 节点重写 (证书已签发, 不受影响)"
        return 0
    }
    [ ! -f "$METADATA_FILE" ] && { _info "暂无节点元数据, 跳过 Trojan 重写"; return 0; }

    local paths cert key
    paths=$(_cert_acme_paths "$domain") || {
        _warn "未找到域名 ${domain} 的 acme 证书, 跳过 Trojan 重写"
        return 0
    }
    cert=$(echo "$paths" | awk '{print $1}')
    key=$(echo "$paths" | awk '{print $2}')

    # 找出所有 type=trojan 的节点 tag (与 inbound tag 一致: trojan-<port>)
    local tags
    tags=$(jq -r '.protocols // {} | to_entries[] | select(.value.type=="trojan") | .key' "$METADATA_FILE" 2>/dev/null)
    [ -z "$tags" ] && { _info "无已有 Trojan 节点需切换真证书"; return 0; }

    local count=0 tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if _atomic_modify_json "$CONFIG_FILE" "
            (.inbounds[] | select(.tag==\"$tag\") | .tls.certificate_path) = \"$cert\" |
            (.inbounds[] | select(.tag==\"$tag\") | .tls.key_path) = \"$key\" |
            (.inbounds[] | select(.tag==\"$tag\") | .tls.server_name) = \"$domain\"
        " 2>/dev/null; then
            _atomic_modify_json "$METADATA_FILE" "
                (.protocols.\"$tag\".sni) = \"$domain\" |
                (.protocols.\"$tag\".insecure) = \"0\"
            " 2>/dev/null
            _info "已重写 Trojan 节点 ${tag} -> 真证书 (${domain}, insecure=0)"
            count=$((count+1))
        else
            _warn "重写 Trojan 节点 ${tag} 失败 (config.json 可能无该 inbound)"
        fi
    done <<< "$tags"

    if [ "$count" -gt 0 ]; then
        _info "正在重启 sing-box 以加载新证书..."
        if _sb_restart_and_verify 2>/dev/null; then
            _success "已自动将 ${count} 个 Trojan 节点切换到真证书, 客户端请改用新分享链接 (sni=${domain}, allowInsecure=0)"
        else
            _warn "证书已写入配置但重启失败, 请手动运行: sb restart"
        fi
    fi
    return 0
}

# ============================================================
# 元数据
# ============================================================
_cert_save_meta() {
    local domain="$1"
    [ ! -f "$CERT_META_FILE" ] && echo '{}' > "$CERT_META_FILE"
    local cert="${CERT_ACME_DIR}/${domain}/fullchain.pem"
    local key="${CERT_ACME_DIR}/${domain}/privkey.pem"
    _atomic_modify_json "$CERT_META_FILE" \
        ". + {\"$domain\": {cert: \"$cert\", key: \"$key\", issued_at: \"$(date '+%Y-%m-%d %H:%M:%S')\"}}" 2>/dev/null || true
}

_cert_list() {
    [ ! -f "$CERT_META_FILE" ] && { echo "暂无 acme 证书"; return 0; }
    _info "已签发 acme 证书:"
    jq -r 'to_entries[] | "  \(.key)  (cert: \(.value.cert))"' "$CERT_META_FILE" 2>/dev/null || echo "  (元数据解析失败)"
}

# ============================================================
# CLI 入口 (供 sb cert 命令调用)
# ============================================================
# 注意: 不用 shift 传递子命令参数 — bash 中 `shift 2>/dev/null` 会把 `2>`
# 解析成 fd2 重定向, 实际只 shift 1 位 (行为碰巧正确但极脆弱易错)。
# 改为显式取 $2/$3 更清晰且不依赖解析陷阱。
_cert_cli() {
    local sub="${1:-status}"
    local arg1="${2:-}" arg2="${3:-}"
    case "$sub" in
        issue)
            local domain="$arg1" email="$arg2"
            [ -z "$domain" ] && { _error "用法: sb cert issue <域名> [邮箱]"; return 1; }
            if _cert_acme_issue "$domain" "$email"; then
                _cert_rewrite_trojan_nodes "$domain"
            fi
            ;;
        renew)
            _cert_acme_renew "$arg1"
            ;;
        list)
            _cert_list
            ;;
        status|*)
            _info "acme.sh: $([ -x "$ACME_BIN" ] && echo "已安装 ($ACME_BIN)" || echo "未安装 (sb cert issue 时自动安装)")"
            _cert_list
            ;;
    esac
}

# ============================================================
# 独立运行
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Singbox-Pro 证书模块 v${CERT_MOD_VERSION} ==="
    echo ""
    echo "命令:"
    echo "  issue <域名> [邮箱]   签发 Let's Encrypt 证书 (standalone/DNS 自动)"
    echo "  renew [域名]          续期 (不指定域名则全部)"
    echo "  list                  列出已签发证书"
    echo "  status                状态"
fi
