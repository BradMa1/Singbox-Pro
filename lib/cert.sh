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

ACME_BIN="${ACME_BIN:-${HOME:-/root}/.acme.sh/acme.sh}"
ACME_HOME="${ACME_HOME:-${HOME:-/root}/.acme.sh}"
CERT_META_FILE="${CERT_META_FILE:-${SINGBOX_DIR}/cert_metadata.json}"
CERT_ACME_DIR="${CERT_ACME_DIR:-${SINGBOX_DIR}/acme}"
# acme.sh 注册账户（ZeroSSL 默认 CA 需要邮箱做 EAB）所用的邮箱；可用环境变量覆盖
CERT_EMAIL="${CERT_EMAIL:-admin@example.com}"

# ============================================================
# acme.sh 安装
# ============================================================
# 安装器可能把 acme.sh 放到与 $ACME_BIN 不同的位置：
#   - `sudo` 未带 -H 时 HOME 仍是被 sudo 的用户 → 装到 /home/xxx/.acme.sh
#   - 某些镜像的包自带 /usr/local/bin/acme.sh
# 只看 $HOME/.acme.sh 会误判成"安装失败"（界面表现为：信息→错误，中间没有任何注意）。
_cert_find_acme() {
    local c
    for c in "$ACME_BIN" "${ACME_HOME}/acme.sh" "${HOME:-/root}/.acme.sh/acme.sh" \
             /root/.acme.sh/acme.sh /usr/local/bin/acme.sh /usr/bin/acme.sh; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    c="$(command -v acme.sh 2>/dev/null || true)"
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    return 1
}

_cert_acme_install() {
    local found
    found="$(_cert_find_acme || true)"
    if [ -n "$found" ]; then
        ACME_BIN="$found"
        export ACME_BIN
        _info "acme.sh 已安装: $($ACME_BIN --version 2>/dev/null | tail -1)  ($ACME_BIN)"
        return 0
    fi

    # 前置依赖: acme.sh 安装需要 curl/wget 之一
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _error "未找到 curl 或 wget, 无法安装 acme.sh。请先: apt-get install -y curl"
        return 1
    fi

    _info "正在安装 acme.sh (社区标准 Let's Encrypt 客户端)..."
    local log="/tmp/acme_install.log" diag="/tmp/acme_install.diag" tmp="" st="" sz=0
    local u
    # 每一档的结论追加到这里，全部失败时一次性打出来，不用再靠猜。
    : >"$diag" 2>/dev/null || true

    # ★ 判定"装好了"只认一件事：磁盘上有没有可执行的 acme.sh。
    #   绝不能信安装器的退出码 —— get.acme.sh 失败时只 echo "Install error"，
    #   没有 exit 1，退出码仍是 0。旧代码据此置 ok=1，后面 4 档回退全被跳过，
    #   界面表现就是「正在安装」下一行直接「安装失败」，中间一条提示都没有。
    _acme_present() { [ -n "$(_cert_find_acme 2>/dev/null || true)" ]; }

    # ---------- 1) 单文件直取（最可靠，放第一位） ----------
    # acme.sh 本身就是独立脚本，不需要安装器，也不必拉 github 归档包。
    # NAT / 纯 v6 / 出口绕路的机器上，安装器去下 master.tar.gz 最容易超时，
    # 这一档只要一个 ~300KB 的文本文件。
    if ! _acme_present; then
        _info "  [1/4] 直取 acme.sh 单文件（镜像）..."
        for u in \
            "https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh" \
            "https://fastly.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh" \
            "https://gcore.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh" \
            "https://testingcf.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh" \
            "https://raw.gitmirror.com/acmesh-official/acme.sh/master/acme.sh" \
            "https://ghfast.top/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
            "https://gh-proxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
            "${GH_PROXY:-https://ghproxy.net/}https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh" \
            "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
        do
            rm -f /tmp/acme_single.sh
            if ! curl -fsSL --connect-timeout 8 --max-time 40 "$u" -o /tmp/acme_single.sh 2>"$log"; then
                st="$(tail -1 "$log" 2>/dev/null | tr -d '\r')"
                printf '  %-46s 下载失败: %s\n' "$(printf '%s' "$u" | cut -c1-46)" "${st:-超时/无响应}" >>"$diag"
                continue
            fi
            sz=$(wc -c < /tmp/acme_single.sh 2>/dev/null || echo 0)
            # 只校验"是不是个像样的脚本"，不再用 head|grep（pipefail 下 grep -q 提前退出
            # 会让 head 收到 SIGPIPE，整条管道返回非零，把好文件也判成坏文件）
            if [ "${sz:-0}" -lt 50000 ]; then
                printf '  %-46s 内容异常(%sB)\n' "$(printf '%s' "$u" | cut -c1-46)" "${sz:-0}" >>"$diag"
                continue
            fi
            mkdir -p "$ACME_HOME" 2>/dev/null || true
            if ! cp -f /tmp/acme_single.sh "$ACME_HOME/acme.sh" 2>/dev/null; then
                printf '  %-46s 写入失败: %s\n' "$(printf '%s' "$u" | cut -c1-46)" "$ACME_HOME" >>"$diag"
                continue
            fi
            chmod +x "$ACME_HOME/acme.sh" 2>/dev/null || true
            if "$ACME_HOME/acme.sh" --version >/dev/null 2>&1; then
                printf '  %-46s 成功 (%sB)\n' "$(printf '%s' "$u" | cut -c1-46)" "$sz" >>"$diag"
                _info "单文件下载成功: $u (${sz}B)"
                break
            fi
            printf '  %-46s 下载完成但跑不起来\n' "$(printf '%s' "$u" | cut -c1-46)" >>"$diag"
        done
        rm -f /tmp/acme_single.sh
    fi

    # ---------- 2) 官方一键脚本 ----------
    if ! _acme_present; then
        _info "  [2/4] get.acme.sh 官方安装器..."
        if curl -fsSL --connect-timeout 10 --max-time 90 https://get.acme.sh -o /tmp/acme_install.sh 2>"$log"; then
            chmod +x /tmp/acme_install.sh 2>/dev/null || true
            /tmp/acme_install.sh >"$log.1" 2>&1 || true
            rm -f /tmp/acme_install.sh
            if ! _acme_present; then
                st="$(grep -m1 -i 'install error' "$log.1" 2>/dev/null || true)"
                printf '  %-46s %s\n' "get.acme.sh" "${st:-未生成 acme.sh（详见 /tmp/acme_install.log.1）}" >>"$diag"
            fi
        else
            printf '  %-46s 下载失败: %s\n' "get.acme.sh" "$(tail -1 "$log" 2>/dev/null | tr -d '\r')" >>"$diag"
        fi
    fi

    # ---------- 3) get.acme.sh 经 GH_PROXY 镜像 ----------
    if ! _acme_present; then
        _info "  [3/4] get.acme.sh 经镜像..."
        if curl -fsSL --connect-timeout 10 --max-time 90 "${GH_PROXY:-https://ghproxy.net/}https://get.acme.sh" -o /tmp/acme_install.sh 2>"$log"; then
            chmod +x /tmp/acme_install.sh 2>/dev/null || true
            /tmp/acme_install.sh >"$log.1" 2>&1 || true
            rm -f /tmp/acme_install.sh
            if ! _acme_present; then
                st="$(grep -m1 -i 'install error' "$log.1" 2>/dev/null || true)"
                printf '  %-46s %s\n' "get.acme.sh(ghproxy)" "${st:-未生成 acme.sh}" >>"$diag"
            fi
        else
            printf '  %-46s 下载失败: %s\n' "get.acme.sh(ghproxy)" "$(tail -1 "$log" 2>/dev/null | tr -d '\r')" >>"$diag"
        fi
    fi

    # ---------- 4) git clone（需 git；有 git 说明这台能连 github） ----------
    if ! _acme_present && command -v git >/dev/null 2>&1; then
        _info "  [4/4] git clone 仓库..."
        for u in \
            "https://github.com/acmesh-official/acme.sh.git" \
            "${GH_PROXY:-https://ghproxy.net/}https://github.com/acmesh-official/acme.sh.git"
        do
            tmp="$(mktemp -d)"
            if git clone --depth 1 "$u" "$tmp/acme.sh" >"$log.1" 2>&1; then
                (cd "$tmp/acme.sh" && ./acme.sh --install >/dev/null 2>&1) || true
                _acme_present && break
            fi
            printf '  %-46s 失败: %s\n' "$(printf '%s' "$u" | cut -c1-46)" "$(tail -1 "$log.1" 2>/dev/null | tr -d '\r')" >>"$diag"
            rm -rf "$tmp"
        done
        if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
    fi

    # ---------- 收尾：按实际落地位置回填，并补装自动续期 cron ----------
    found="$(_cert_find_acme || true)"
    if [ -n "$found" ]; then
        ACME_BIN="$found"
        export ACME_BIN
        # 单文件/直取方式绕过了官方安装器，补跑一次 --install 注册 90 天续期 cron。
        # 失败不影响当前使用，菜单 [3] 随时能手动续期。
        if [ ! -f "${ACME_HOME}/account.conf" ] && [ ! -d "${ACME_HOME}/ca" ]; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 60 "$ACME_BIN" --install </dev/null >/dev/null 2>&1 || true
            else
                "$ACME_BIN" --install </dev/null >/dev/null 2>&1 || true
            fi
        fi
        _success "acme.sh 安装完成: $($ACME_BIN --version 2>/dev/null | tail -1)"
        _info "安装位置: $ACME_BIN"
        return 0
    fi

    _error "acme.sh 安装失败：单文件镜像 / 官方安装器 / 镜像安装器 / git clone 都没成功"
    if [ -s "$diag" ]; then
        _info "各档结果（哪一步断的看这里）:"
        sed -n '1,12p' "$diag" >&2
    fi
    _warn "这台机器连不上 jsDelivr / github，通常是 DNS 或出站被拦。可先验证："
    echo "    curl -sI https://cdn.jsdelivr.net | head -1     # 通 → 有响应；不通 → 看下面手动装" >&2
    _warn "手动装（把 <可用镜像> 换成上面 curl 能通的那个域名）："
    echo "    mkdir -p ~/.acme.sh && curl -fsSL https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/acme.sh -o ~/.acme.sh/acme.sh && chmod +x ~/.acme.sh/acme.sh" >&2
    return 1
}

# 把已签发的 acme 证书同步到 sing-box 实际使用的 cert.pem/key.pem,
# 让 AnyTLS/TUIC/Hy2/VLESS-WS 等所有硬编码引用 ${SINGBOX_DIR}/cert.pem 的 inbound 生效。
# (注: argo-vless-ws 是回环明文 ws, listen 127.0.0.1 且无 tls 段, 不引用 cert.pem, 不受影响)
# 返回 0 表示同步成功
_cert_sync_cert() {
    local domain="$1"
    [ -n "$domain" ] || return 1
    [ -f "${CERT_ACME_DIR}/${domain}/fullchain.pem" ] || return 1
    if cp -f "${CERT_ACME_DIR}/${domain}/fullchain.pem" "${SINGBOX_DIR}/cert.pem" 2>/dev/null && \
       cp -f "${CERT_ACME_DIR}/${domain}/privkey.pem" "${SINGBOX_DIR}/key.pem" 2>/dev/null; then
        chmod 644 "${SINGBOX_DIR}/cert.pem"
        chmod 600 "${SINGBOX_DIR}/key.pem"
        return 0
    fi
    return 1
}

# 让 sing-box 加载新证书 (幂等: 可用 sb 的校验重启, 否则直接 systemctl restart)
_cert_reload_singbox() {
    if declare -f _sb_restart_and_verify >/dev/null 2>&1; then
        _sb_restart_and_verify 2>/dev/null || _warn "重启 sing-box 失败, 请手动执行: sb restart"
    else
        systemctl restart sing-box 2>/dev/null || _warn "重启 sing-box 失败, 请手动执行: systemctl restart sing-box"
    fi
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
    local domain="$1" email="${2:-$CERT_EMAIL}"
    [ -z "$domain" ] && { _error "签发证书需要域名"; return 1; }

    _cert_acme_install || return 1

    # acme.sh 默认 CA 为 ZeroSSL，签发前必须先用邮箱注册账户（获取 EAB 凭证），
    # 否则 --issue 会报 "Please update your account with an email address first" 而直接失败。
    # 已注册则 acme.sh 自动跳过，此步幂等安全。
    "$ACME_BIN" --register-account -m "$email" >/dev/null 2>&1 || true

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

    # 未检测到 DNS 凭证且处于交互终端时, 主动询问 Cloudflare 凭证
    if [ -z "$dns_mode" ] && [ -t 1 ]; then
        _warn "未检测到 DNS API 凭证。"
        _info "DNS-01 模式无需开放 80 端口，是否输入 Cloudflare 凭证? [y/N]"
        read -r -t 30 _ans 2>/dev/null
        if [[ "$_ans" =~ ^[Yy]$ ]]; then
            local CF_Token="" CF_Account_ID=""
            _info "Token 以 cfut_ 开头；Account ID 为 32 位十六进制。"
            while [ -z "$CF_Token" ]; do
                read -r -p "Cloudflare API Token: " CF_Token
                CF_Token="$(echo "$CF_Token" | tr -d '[:space:]')"
                if [ -z "$CF_Token" ]; then
                    _warn "API Token 不能为空，请重新输入"
                elif echo "$CF_Token" | grep -qiE '^[0-9a-f]{32}$'; then
                    _warn "你输入的是 32 位十六进制字符串（很像 Account ID），不是 API Token！请重新输入以 cfut_ 开头的 Token"
                    CF_Token=""
                fi
            done
            while [ -z "$CF_Account_ID" ]; do
                read -r -p "Cloudflare Account ID: " CF_Account_ID
                CF_Account_ID="$(echo "$CF_Account_ID" | tr -d '[:space:]')"
                if [ -z "$CF_Account_ID" ]; then
                    _warn "Account ID 不能为空，请重新输入"
                elif ! echo "$CF_Account_ID" | grep -qiE '^[0-9a-f]{32}$'; then
                    _warn "Account ID 应为 32 位十六进制字符串，请检查后重新输入"
                    CF_Account_ID=""
                fi
            done
            export CF_Token CF_Account_ID
            if env | grep -qiE '^(CF_Token|Ali_Key|DP_Id|DNSPOD_|GANDI_|OCI_)' ; then
                dns_mode="detected"
            fi
            _cf_from_interactive=1
        fi
    fi

    if [ -n "$dns_mode" ]; then
        if [ -n "${_cf_from_interactive:-}" ]; then
            _info "已采用你输入的 Cloudflare 凭证，使用 DNS-01 挑战 (无需开放 80 端口)..."
        else
            _info "检测到 DNS API 环境变量，使用 DNS-01 挑战 (无需开放 80 端口)..."
        fi
        # 根据环境变量自动选择 acme.sh DNS 插件 (不能只传 --dns, 必须指定具体插件)
        local dns_plugin=""
        if env | grep -qiE '^CF_Token|^CF_Key' ; then
            dns_plugin="dns_cf"
        elif env | grep -qiE '^Ali_Key' ; then
            dns_plugin="dns_ali"
        elif env | grep -qiE '^DP_Id|^DNSPOD_' ; then
            dns_plugin="dns_dp"
        elif env | grep -qiE '^GANDI_' ; then
            dns_plugin="dns_gandi"
        elif env | grep -qiE '^OCI_' ; then
            dns_plugin="dns_oci"
        fi
        if [ -z "$dns_plugin" ]; then
            _error "检测到 DNS API 变量但无法确定插件, 请手动设置 (如 CF 需 CF_Token+CF_Account_ID)"
            return 1
        fi
        _info "使用 DNS 插件: ${dns_plugin}"
        local acme_out
        acme_out=$("$ACME_BIN" "${issue_args[@]}" --dns "$dns_plugin" 2>&1)
        local rc=$?
        # acme.sh 证书已存在时会输出 "Skipping" 并返回非 0, 视为成功继续落地证书 (幂等)
        if [ $rc -ne 0 ] && ! echo "$acme_out" | grep -qiE 'Skipping|Domains not changed|is still valid|Cert success'; then
            _error "DNS 模式签发失败，请重点看 acme.sh 错误关键字：invalid / permission / not found"
            echo "$acme_out" | tail -15
            _info "常见原因：Token 无 DNS 编辑权限 / 域名未解析 / 子域名与 Zone 不匹配。详见：sb cert guide"
            return 1
        fi
        echo "$acme_out" | tail -3
    else
        _warn "未检测到 DNS API 变量。"
        _info "建议：export CF_Token/CF_Account_ID 后用 DNS-01（无需 80 端口），或尝试 standalone（需 80 可达）。"
        local acme_out
        acme_out=$("$ACME_BIN" "${issue_args[@]}" --standalone 2>&1)
        local rc=$?
        # acme.sh 证书已存在时会输出 "Skipping" 并返回非 0, 视为成功继续落地证书 (幂等)
        if [ $rc -ne 0 ] && ! echo "$acme_out" | grep -qiE 'Skipping|Domains not changed|is still valid|Cert success'; then
            _error "standalone 签发失败：80 端口不可达或域名未解析。建议改用 DNS-01，详见：sb cert guide"
            return 1
        fi
        echo "$acme_out" | tail -3
    fi

    # 复制证书到统一目录
    mkdir -p "${CERT_ACME_DIR}/${domain}"
    # renew-hook: acme.sh 自动 cron 续期成功后, 同步新证书到 sing-box 并重启加载。
    # 路径在注册时即展开为绝对路径 (cron 环境无我们的变量), 否则 90 天后续期成功
    # 但 cert.pem 还是旧证书 → 全部 TLS inbound 在旧证书过期后崩。
    local renew_hook="cp -f '${CERT_ACME_DIR}/${domain}/fullchain.pem' '${SINGBOX_DIR}/cert.pem' && cp -f '${CERT_ACME_DIR}/${domain}/privkey.pem' '${SINGBOX_DIR}/key.pem' && chmod 644 '${SINGBOX_DIR}/cert.pem' && chmod 600 '${SINGBOX_DIR}/key.pem' && (systemctl restart sing-box || true)"
    if ! "$ACME_BIN" --install-cert -d "$domain" \
        --fullchain-file "${CERT_ACME_DIR}/${domain}/fullchain.pem" \
        --key-file "${CERT_ACME_DIR}/${domain}/privkey.pem" \
        --renew-hook "$renew_hook" 2>/dev/null; then
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
        # 关键: 把真实证书覆盖到 sing-box 实际使用的 cert.pem/key.pem,
        # 这样 AnyTLS/TUIC/Hy2/VLESS-WS 的 inbound (硬编码指向 ${SINGBOX_DIR}/cert.pem)
        # 也一并切换到真证书, 无需逐个改 inbound。
        # (argo-vless-ws 为回环明文 ws, 不引用证书, 不受影响)
        if _cert_sync_cert "$domain"; then
            _info "已用真实证书覆盖 ${SINGBOX_DIR}/cert.pem / key.pem (全部 TLS inbound 生效)"
        else
            _warn "覆盖 ${SINGBOX_DIR}/cert.pem 失败, 请手动复制 acme 证书"
        fi
        return 0
    fi

    _error "证书签发成功但落地失败，请检查 ${CERT_ACME_DIR} 权限"
    return 1
}

# ============================================================
# Cloudflare DNS-01 设置指引 (交互提示, 用户跑命令时可见)
# ============================================================
# 用法: _cert_cf_guide  —  打印在 Cloudflare 后台完成 DNS 记录 / API Token / Account ID
#        三步设置的完整步骤, 让用户无需查文档也会配。
_cert_cf_guide() {
    cat <<'EOF'

=== Cloudflare DNS-01 设置指引（无需开放 80 端口）===
1) A 记录：CF 后台 → 你的域名 → DNS → Add record
     类型 A，名称 <子域前缀，如 us>，IPv4 = 你的 VPS IP，代理选「DNS only / 灰云 ☁️」（橙云会握手失败）

2) API Token：右上头像 → My Profile → API Tokens → Create Token
     用模板 "Edit zone DNS"；Permissions = Zone→DNS→Edit；
     Zone Resources = 选你的 **根 Zone**（us.brad.dpdns.org 选 brad.dpdns.org）；
     复制 Token（cfut_ 开头，只显示一次）。⚠️ 此 Token 不要删，acme.sh 续期还要用。

3) Account ID：任意域名 → Overview 页右侧 "Account ID"

4) VPS 上导出并签发：
     export CF_Token="第2步的 Token"
     export CF_Account_ID="第3步的 Account ID"
     sb cert issue us.brad.dpdns.org      # 换成你的子域名即可
     （acme.sh 自动加 _acme-challenge 记录，成功后证书落到 sing-box）

EOF
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
    # 同步到 sing-box 并重启加载。
    # 注意: acme.sh 的自动 cron 只跑 --renew, 不会碰我们的 cert.pem, 因此手动续期
    # 必须在这里显式同步 + 重启; 自动续期场景则靠签发时注册的 --renew-hook 完成。
    local synced=0
    if [ -n "$domain" ]; then
        _cert_sync_cert "$domain" && synced=1
    else
        for d in "${CERT_ACME_DIR}"/*/; do
            [ -d "$d" ] || continue
            _cert_sync_cert "$(basename "$d")" && synced=1
        done
    fi
    if [ "$synced" -eq 1 ]; then
        _info "证书已同步到 sing-box (${SINGBOX_DIR}/cert.pem), 重启加载..."
        _cert_reload_singbox
    fi
    _success "续期完成 (已签证书会在到期前由 acme.sh cron 自动续期, 续期后自动同步到 sing-box)"
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
    local domains cert_path expiry
    domains=$(jq -r 'keys[]' "$CERT_META_FILE" 2>/dev/null)
    if [ -z "$domains" ]; then
        echo "  (暂无)"
        return 0
    fi
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        cert_path=$(jq -r --arg d "$domain" '.[$d].cert // empty' "$CERT_META_FILE" 2>/dev/null)
        if [ -f "$cert_path" ] && command -v openssl >/dev/null 2>&1; then
            expiry=$( { openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2; } || true)
            expiry=$(date -d "$expiry" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$expiry")
        else
            expiry="未知"
        fi
        echo "  ${domain}  过期: ${expiry}  cert: ${cert_path}"
    done <<< "$domains"
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
        guide)
            _cert_cf_guide
            ;;
        renew)
            _cert_acme_renew "$arg1"
            ;;
        list)
            _cert_list
            ;;
        status|*)
            local _ab
            _ab="$(_cert_find_acme || true)"
            if [ -n "$_ab" ]; then
                ACME_BIN="$_ab"
                export ACME_BIN
                _info "acme.sh: 已安装 ($ACME_BIN)"
            else
                _info "acme.sh: 未安装 (sb cert issue 时自动安装)"
            fi
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
    echo "  guide                 查看 Cloudflare DNS-01 设置指引 (如何在 CF 建记录/Token)"
    echo "  renew [域名]          续期 (不指定域名则全部)"
    echo "  list                  列出已签发证书"
    echo "  status                状态"
fi
