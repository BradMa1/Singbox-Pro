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
# ACME 账号邮箱。留空 = 用 acme@<签发域名>（推导见 _cert_default_email）。
# 千万不要再用 admin@example.com：example.com 是 RFC 2606 保留域名，
# Let's Encrypt 注册账号时会直接 400 invalidContact（详见 _cert_email_ok 注释）。
CERT_EMAIL="${CERT_EMAIL:-}"

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
# 续期可靠性: 调度 (cron/timer) + renew hook + cert.pem 一致性
# ============================================================
# 为什么要有这一段 (v2.2.17 事故复盘):
#   1) cert.pem 是三个 TLS inbound (AnyTLS/Hy2/TUIC) 硬编码引用的文件，
#      而 acme.sh 续期只写 ${CERT_ACME_DIR}/<域名>/。两者靠 renew hook 同步。
#      老版本签发的证书没有 hook → 续期成功但 cert.pem 停在旧证书 →
#      旧证书一到期，三个协议同时挂，且客户端只报握手失败，极难定位。
#   2) 最小化镜像常常没有 cron 守护进程，acme.sh 的 --install-cronjob 会
#      静默失败 → "自动续期"从来不存在，证书 90 天后静默失效。
#   所以这里做三件事: 保证调度存在 (无 cron 就装 systemd timer)、
#   保证 hook 存在 (幂等重注册)、保证 cert.pem 与 acme 证书一致 (可检测可修复)。

# renew hook 命令串: 路径在注册时展开成绝对路径 (cron/timer 环境没有我们的变量)
_cert_renew_hook_cmd() {
    local domain="$1"
    printf "cp -f '%s' '%s' && cp -f '%s' '%s' && chmod 644 '%s' && chmod 600 '%s' && (systemctl restart sing-box || true)" \
        "${CERT_ACME_DIR}/${domain}/fullchain.pem" "${SINGBOX_DIR}/cert.pem" \
        "${CERT_ACME_DIR}/${domain}/privkey.pem" "${SINGBOX_DIR}/key.pem" \
        "${SINGBOX_DIR}/cert.pem" "${SINGBOX_DIR}/key.pem"
}

# 幂等注册 install-cert + renew hook (老证书没 hook 时靠它补齐)
_cert_ensure_hook() {
    local domain="$1" hook
    [ -n "$domain" ] || return 1
    if [ ! -x "${ACME_BIN:-}" ]; then
        local f
        f="$(_cert_find_acme 2>/dev/null || true)"
        [ -n "$f" ] || return 1
        ACME_BIN="$f"; export ACME_BIN
    fi
    hook="$(_cert_renew_hook_cmd "$domain")"
    if "$ACME_BIN" --install-cert -d "$domain" \
        --fullchain-file "${CERT_ACME_DIR}/${domain}/fullchain.pem" \
        --key-file "${CERT_ACME_DIR}/${domain}/privkey.pem" \
        --renew-hook "$hook" >/dev/null 2>&1; then
        return 0
    fi
    # ECC 证书目录是 <域名>_ecc/，部分 acme.sh 版本需要显式 --ecc
    "$ACME_BIN" --install-cert -d "$domain" --ecc \
        --fullchain-file "${CERT_ACME_DIR}/${domain}/fullchain.pem" \
        --key-file "${CERT_ACME_DIR}/${domain}/privkey.pem" \
        --renew-hook "$hook" >/dev/null 2>&1
}

# 找到某个域名的 acme 配置 (兼容 <域名>/ 与 <域名>_ecc/ 两种布局)
_cert_conf_file() {
    local domain="$1" c home
    home="${ACME_HOME:-${HOME:-/root}/.acme.sh}"
    for c in "${home}/${domain}_ecc/${domain}.conf" "${home}/${domain}/${domain}.conf"; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

_cert_serial() {
    [ -f "$1" ] || return 1
    openssl x509 -in "$1" -noout -serial 2>/dev/null | cut -d= -f2
}

# 证书剩余天数 (负数=已过期; 解析失败返回 1)
_cert_days_left() {
    local f="$1" end epoch now
    [ -f "$f" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] || return 1
    # GNU date 优先，BSD/macOS date 兜底 (自测脚本在 macOS 上跑)
    epoch=$(date -d "$end" +%s 2>/dev/null) || \
    epoch=$(date -j -u -f "%b %d %H:%M:%S %Y" "${end% GMT}" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    echo $(( (epoch - now) / 86400 ))
}

# 自动续期调度现状: cron / timer / none
_cert_renew_schedule() {
    local cl="" tl="" bin
    cl=$(crontab -l 2>/dev/null || true)
    case "$cl" in
        *acme.sh*--cron*) printf 'cron'; return 0 ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        tl=$(systemctl list-timers --all --no-pager 2>/dev/null || true)
        case "$tl" in
            *acme-renew*) printf 'timer'; return 0 ;;
        esac
    fi
    printf 'none'
    return 1
}

# 没有调度就装一个。优先 systemd timer —— 不依赖 cron 包，最小化镜像也能用
_cert_ensure_renew_schedule() {
    local mode bin home
    mode=$(_cert_renew_schedule 2>/dev/null || true)
    [ "$mode" != "none" ] && [ -n "$mode" ] && return 0

    bin="${ACME_BIN:-$ACME_HOME/acme.sh}"
    home="${ACME_HOME:-$(dirname "$bin")}"

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ] && [ -w /etc/systemd/system ]; then
        cat > /etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=acme.sh renewal check (Singbox-Pro)
After=network-online.target

[Service]
Type=oneshot
ExecStart=${bin} --cron --home ${home}
EOF
        cat > /etc/systemd/system/acme-renew.timer <<'EOF'
[Unit]
Description=Daily acme.sh renewal check (Singbox-Pro)

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
        if systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now acme-renew.timer >/dev/null 2>&1; then
            _success "已注册自动续期: systemd timer acme-renew.timer (每天 03:17 检查)"
            return 0
        fi
        _warn "systemd timer 注册失败, 回退 acme.sh 自带 cron..."
    fi

    "$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
    mode=$(_cert_renew_schedule 2>/dev/null || true)
    if [ "$mode" != "none" ] && [ -n "$mode" ]; then
        _success "已注册自动续期: $mode"
        return 0
    fi
    _warn "未能自动注册续期任务。请手动加: 17 3 * * * ${bin} --cron --home ${home}"
    return 1
}

# 把 acme 目录下的证书全部同步到 cert.pem/key.pem 并重启 (修复"续了但没生效")
# 已一致时不重启 —— 重启要断 1~2 秒连接，没必要为"什么都没变"付这个代价
_cert_sync_all() {
    local n=0 d dom before after
    before="$(_cert_serial "${SINGBOX_DIR}/cert.pem" 2>/dev/null || true)"
    for d in "${CERT_ACME_DIR}"/*/; do
        [ -d "$d" ] || continue
        dom=$(basename "$d")
        if _cert_sync_cert "$dom"; then
            _info "已同步 ${dom} -> cert.pem / key.pem"
            n=$((n+1))
        fi
    done
    if [ "$n" -eq 0 ]; then
        _warn "没有可同步的 acme 证书 (${CERT_ACME_DIR} 为空)"
        return 1
    fi
    after="$(_cert_serial "${SINGBOX_DIR}/cert.pem" 2>/dev/null || true)"
    if [ -n "$after" ] && [ "$before" = "$after" ]; then
        _info "cert.pem 已是最新 (serial ${after})，无需重启 sing-box"
        return 0
    fi
    _cert_reload_singbox
    return 0
}

# 一键修复: 补调度 + 补 hook + 对齐 cert.pem
_cert_fix() {
    local rc=0 dom
    _cert_ensure_renew_schedule || rc=1
    if [ -f "$CERT_META_FILE" ]; then
        while IFS= read -r dom; do
            [ -z "$dom" ] && continue
            [ -f "${CERT_ACME_DIR}/${dom}/fullchain.pem" ] || continue
            if _cert_ensure_hook "$dom"; then
                _info "已确认续期 hook: ${dom}"
            else
                _warn "补续期 hook 失败: ${dom}"
                rc=1
            fi
        done < <(jq -r 'keys[]' "$CERT_META_FILE" 2>/dev/null || true)
    fi
    _cert_sync_all || rc=1
    return $rc
}

# 自检: 每行输出 "<ok|warn|fail>\t<文案>"，供健康检查(菜单16)直接渲染
_cert_selfcheck() {
    local mode dom cert days conf s1 s2
    mode=$(_cert_renew_schedule 2>/dev/null || true)
    case "$mode" in
        cron)  printf 'ok\t自动续期已注册 (cron)\n' ;;
        timer) printf 'ok\t自动续期已注册 (systemd timer)\n' ;;
        *)     printf 'fail\t自动续期未注册 —— 到期后会静默失效 (修复: sb cert fix)\n' ;;
    esac

    if [ ! -f "$CERT_META_FILE" ]; then
        printf 'warn\t未签发真实证书 (TLS 节点用自签证书)\n'
        return 0
    fi

    local domains=""
    domains=$(jq -r 'keys[]' "$CERT_META_FILE" 2>/dev/null || true)
    if [ -z "$domains" ]; then
        printf 'warn\t未签发真实证书 (TLS 节点用自签证书)\n'
        return 0
    fi

    while IFS= read -r dom; do
        [ -z "$dom" ] && continue
        cert="${CERT_ACME_DIR}/${dom}/fullchain.pem"
        if [ ! -f "$cert" ]; then
            printf 'fail\t%s 证书文件缺失: %s\n' "$dom" "$cert"
            continue
        fi
        days=$(_cert_days_left "$cert" 2>/dev/null || true)
        if [ -z "$days" ]; then
            printf 'warn\t%s 到期时间无法解析\n' "$dom"
        elif [ "$days" -le 0 ]; then
            printf 'fail\t%s 已过期 %s 天\n' "$dom" "$((-days))"
        elif [ "$days" -lt 15 ]; then
            printf 'warn\t%s 剩 %s 天到期 (尽快续期: sb cert renew)\n' "$dom" "$days"
        else
            printf 'ok\t%s 剩 %s 天\n' "$dom" "$days"
        fi

        # cert.pem / key.pem 是否就是这个域名的证书
        if [ -f "${SINGBOX_DIR}/cert.pem" ]; then
            s1=$(_cert_serial "${SINGBOX_DIR}/cert.pem" || true)
            s2=$(_cert_serial "$cert" || true)
            if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ]; then
                printf 'fail\tcert.pem 与 acme 证书不一致 (TLS 节点仍在用旧证书) —— 修复: sb cert sync\n'
            else
                printf 'ok\tcert.pem 已与 %s 同步\n' "$dom"
            fi
        fi

        conf=$(_cert_conf_file "$dom" 2>/dev/null || true)
        if [ -n "$conf" ]; then
            if grep -qE "^Le_(RenewHook|ReloadCmd)='[^']" "$conf" 2>/dev/null; then
                printf 'ok\t%s 续期后会自动同步 cert.pem 并重启\n' "$dom"
            else
                printf 'warn\t%s 未注册续期 hook (续期后 cert.pem 不会更新) —— 修复: sb cert fix\n' "$dom"
            fi
        fi
    done <<< "$domains"
}

# ============================================================
# DNS 提供商识别 + dnsapi 插件补装
# ============================================================
# 直接读 shell 变量，不用 `env | grep -q`：
#   `env | grep -q` 在 pipefail 下会被 SIGPIPE 判成失败 —— grep -q 一命中就退出，
#   env 还在往管道写 → env 收到 SIGPIPE、退出码 141 → pipefail 让整条管道返回非 0。
#   表现就是「明明刚刚 export 了 CF_Token，脚本却说无法确定插件」。直接展开变量
#   没有子进程也没有管道，顺带还不受 set -u 影响（用 ${VAR:-}）。
_cert_dns_plugin() {
    if [ -n "${CF_Token:-}" ] || [ -n "${CF_Key:-}" ]; then
        printf 'dns_cf'
        return 0
    fi
    if [ -n "${Ali_Key:-}" ] || [ -n "${Ali_Secret:-}" ]; then
        printf 'dns_ali'
        return 0
    fi
    if [ -n "${DP_Id:-}" ] || [ -n "${DP_Key:-}" ] || [ -n "${DNSPOD_ID:-}" ] || [ -n "${DNSPOD_Key:-}" ]; then
        printf 'dns_dp'
        return 0
    fi
    if [ -n "${GANDI_API_KEY:-}" ]; then
        printf 'dns_gandi_livedns'
        return 0
    fi
    if [ -n "${OCI_CLI_TENANCY:-}" ]; then
        printf 'dns_oci'
        return 0
    fi
    return 1
}

# 单文件方式装的 acme.sh **不含 dnsapi/ 目录**，`--dns dns_cf` 会报
# "Cannot find DNS API hook for: dns_cf"，然后退化成打印 TXT 记录让你手动加。
# 这里按需只补那一个插件文件（几 KB），比拉整个归档包稳。
_cert_ensure_dns_plugin() {
    local p="$1" dst="" u sz
    [ -n "$p" ] || return 1
    dst="${ACME_HOME}/dnsapi/${p}.sh"
    [ -f "$dst" ] && return 0
    mkdir -p "${ACME_HOME}/dnsapi" 2>/dev/null || true
    for u in \
        "https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi/${p}.sh" \
        "https://fastly.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi/${p}.sh" \
        "https://gcore.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi/${p}.sh" \
        "https://testingcf.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi/${p}.sh" \
        "https://raw.gitmirror.com/acmesh-official/acme.sh/master/dnsapi/${p}.sh" \
        "https://ghfast.top/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/${p}.sh" \
        "https://gh-proxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/${p}.sh" \
        "${GH_PROXY:-https://ghproxy.net/}https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/${p}.sh" \
        "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/${p}.sh"
    do
        rm -f "${dst}.tmp"
        if curl -fsSL --connect-timeout 8 --max-time 40 "$u" -o "${dst}.tmp" 2>/dev/null; then
            sz=$(wc -c < "${dst}.tmp" 2>/dev/null || echo 0)
            if [ "${sz:-0}" -gt 500 ]; then
                if mv -f "${dst}.tmp" "$dst" 2>/dev/null; then
                    chmod +x "$dst" 2>/dev/null || true
                    _info "已补装 DNS 插件: ${p} (${sz}B)"
                    return 0
                fi
            fi
        fi
    done
    rm -f "${dst}.tmp"
    return 1
}

# Cloudflare 预检：先确认 Token 有效、且这个 Token 能看到域名所属 Zone。
# 不做这一步的话，插件失败时只会甩一句 `invalid domain` —— 但这句话同时可能是
#   a) Token 无效/过期  b) Token 没勾 Zone:DNS:Edit  c) Token 限制在别的 Zone
# 三种完全不同的原因。预检能把它们分开说清楚。
# 返回 0 = 可以继续；1 = 明确有问题（网络不通时返回 0，不阻断）
_cert_cf_preflight() {
    local tok="$1" d="$2" resp cand zone=""
    command -v curl >/dev/null 2>&1 || return 0

    resp="$(curl -s --connect-timeout 8 --max-time 20 \
        -H "Authorization: Bearer $tok" \
        https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null || true)"
    if [ -z "$resp" ]; then
        _warn "连不上 api.cloudflare.com，跳过 Token 预检（不影响后面的签发尝试）"
        return 0
    fi
    case "$resp" in
        *'"status":"active"'*) : ;;
        *)
            _error "Token 校验未通过，Cloudflare 的回应："
            printf '    %s\n' "$(printf '%s' "$resp" | tr -d '\n' | cut -c1-200)" >&2
            _warn "去 CF 后台 → 头像 → My Profile → API Tokens 重新复制，权限至少要有 Zone → DNS → Edit"
            return 1
            ;;
    esac
    _info "Token 有效"

    # 从最长后缀往上找 Zone（zouter.hk.brad.dpdns.org → hk.brad.dpdns.org → brad.dpdns.org）
    cand="$d"
    while [ "$(printf '%s' "$cand" | awk -F. '{print NF}')" -ge 2 ]; do
        resp="$(curl -s --connect-timeout 6 --max-time 15 \
            -H "Authorization: Bearer $tok" \
            "https://api.cloudflare.com/client/v4/zones?name=${cand}&per_page=1" 2>/dev/null || true)"
        case "$resp" in
            *'"name":"'"$cand"'"'*) zone="$cand"; break ;;
        esac
        cand="${cand#*.}"
    done
    if [ -n "$zone" ]; then
        _info "Token 可管理 Zone: ${zone}"
        return 0
    fi
    _error "这个 Token 查不到 ${d} 所属的 Zone（可能不属于当前 Account，或 Token 被限制到别的域名）"
    _warn "核对两件事：① 该域名确实在这个 CF 账号下 ② 创建 Token 时 Zone Resources 选了 All zones 或包含该域名"
    return 1
}

# ============================================================
# ACME 账号邮箱 + 账号注册
# ============================================================
# Let's Encrypt 在「注册账号」这一步会校验联系邮箱的域名：
#   contact email has forbidden domain "example.com"
#   { "type": "urn:ietf:params:acme:error:invalidContact", "status": 400 }
# example.com / example.net / example.org 是 RFC 2606 的保留域名，一律被拒；
# 而 acme.sh 出厂的默认账号邮箱恰好是 admin@example.com —— 旧代码把它透传给
# --accountemail，于是 Token 验过了、插件也装上了，签发却永远失败在这句话上。
# 现在默认改成 acme@<签发域名>（域名是用户自己的，能过校验），
# 也支持 CERT_EMAIL 环境变量或交互输入换成真实邮箱（用来收到期提醒）。
_cert_email_ok() {
    case "$1" in
        "") return 1 ;;
        *[[:space:]]*) return 1 ;;              # 含空白
        *@example.com|*@example.net|*@example.org) return 1 ;;
        *@*.*) return 0 ;;
    esac
    return 1
}

_cert_default_email() {
    printf 'acme@%s' "$1"
}

# acme.sh 已签发过同一域名时会打 "Skipping" 并返回非 0 → 视为成功（幂等续签路径）。
# 用 case 而不是 `echo | grep -q`：pipefail 下 grep -q 命中即退出会让 echo 收
# SIGPIPE(141)，整条管道非 0，于是「跳过」被判成失败（本会话已踩过同类坑）。
_cert_out_reuse() {
    case "$1" in
        *Skipping*|*"Domains not changed"*|*"is still valid"*|*"Cert success"*) return 0 ;;
    esac
    return 1
}

# 输出里出现账号邮箱被拒的特征 → 这条是「换邮箱能救」的失败，不是域名/Token 问题
_cert_out_bad_contact() {
    case "$1" in
        *invalidContact*|*"forbidden domain"*) return 0 ;;
    esac
    return 1
}

# 把 LE 账号对齐到 $email。register 对已存在的账号在部分版本只回显不更新，
# 所以补一次 update-account（账号不存在时它失败，忽略）。
_cert_acme_register() {
    local email="$1"
    "$ACME_BIN" --register-account --server letsencrypt -m "$email" </dev/null >/dev/null 2>&1 || true
    "$ACME_BIN" --update-account --server letsencrypt -m "$email" </dev/null >/dev/null 2>&1 || true
    return 0
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
    local domain="$1" email="${2:-${CERT_EMAIL:-}}"
    [ -z "$domain" ] && { _error "签发证书需要域名"; return 1; }

    # --- 账号邮箱：参数 > CERT_EMAIL > 交互输入 > acme@<域名> ---
    # 为什么必须换掉 example.com：见 _cert_email_ok 上方注释（LE 400 invalidContact）。
    if [ -n "$email" ] && ! _cert_email_ok "$email"; then
        _warn "邮箱 ${email} 不能用（Let's Encrypt 拒收 example.com 这类保留域名），将改用默认值"
        email=""
    fi
    if [ -z "$email" ] && [ -t 0 ]; then
        _info "Let's Encrypt 账号要一个联系邮箱（用于证书到期提醒）"
        _info "  直接回车 = $(_cert_default_email "$domain")（不影响签发）"
        read -r -t 60 -p "  到期提醒邮箱 (可留空): " _cert_in_email 2>/dev/null || true
        _cert_in_email="$(printf '%s' "${_cert_in_email:-}" | tr -d '[:space:]')"
        if _cert_email_ok "$_cert_in_email"; then
            email="$_cert_in_email"
        elif [ -n "$_cert_in_email" ]; then
            _warn "这个邮箱格式不对或属保留域名，改用 $(_cert_default_email "$domain")"
        fi
        unset _cert_in_email
    fi
    [ -z "$email" ] && email="$(_cert_default_email "$domain")"

    _cert_acme_install || return 1

    # 二进制的实际位置就是 acme.sh 的 LE_WORKING_DIR —— dnsapi/ 插件和 <域名>/ 证书
    # 都在它旁边。安装位置可能不是 $HOME/.acme.sh（见 _cert_find_acme），这里对齐一次，
    # 否则插件会补到错目录、--install-cert 也会读不到证书。
    ACME_HOME="$(dirname "$ACME_BIN")"
    export ACME_HOME

    # 先把 LE 账号注册到这个邮箱（幂等）。--issue 本身不接受 --accountemail，
    # 旧写法把它塞进 issue 参数里，等于把 admin@example.com 直接发给 LE 注册接口。
    _cert_acme_register "$email"
    _info "ACME 账号邮箱: ${email}"

    # 提前确保 80 端口可达 (standalone)
    if _check_port_occupied 80 "tcp" 2>/dev/null; then
        _warn "端口 80 (TCP) 已被占用，standalone 签发可能失败。"
        _warn "若失败请改用 DNS 模式: 设置 CF_Token/CF_Account_ID 等环境变量后重跑, 或临时释放 80 端口。"
    fi

    # 默认 CA 用 Let's Encrypt：acme.sh 出厂是 ZeroSSL，必须先注册账号拿 EAB 且邮箱
    # 必须是真实邮箱，多一道坑；LE 不需要 EAB，直接用。
    local issue_args=(--issue -d "$domain" --keylength ec-256 --server letsencrypt)

    # 识别 DNS 提供商：直接读变量，不经过 env|grep（原因见 _cert_dns_plugin 注释）
    local dns_plugin=""
    dns_plugin="$(_cert_dns_plugin || true)"

    # 未检测到 DNS 凭证且处于交互终端时, 主动询问 Cloudflare 凭证
    if [ -z "$dns_plugin" ] && [ -t 1 ]; then
        _warn "未检测到 DNS API 凭证。"
        _info "DNS-01 模式无需开放 80 端口，是否输入 Cloudflare 凭证? [y/N]"
        read -r -t 30 _ans 2>/dev/null
        if [[ "${_ans:-}" =~ ^[Yy]$ ]]; then
            local CF_Token="" CF_Account_ID=""
            _info "Token: CF 后台 → 头像 → My Profile → API Tokens → Create Token → Edit zone DNS"
            _info "       形如 40 位字母数字、没有固定前缀；Account ID 为 32 位十六进制（域名 Overview 页右侧）"
            while [ -z "$CF_Token" ]; do
                read -r -p "Cloudflare API Token: " CF_Token
                CF_Token="$(echo "$CF_Token" | tr -d '[:space:]')"
                if [ -z "$CF_Token" ]; then
                    _warn "API Token 不能为空，请重新输入"
                elif echo "$CF_Token" | grep -qiE '^[0-9a-f]{32}$'; then
                    _warn "你输入的是 32 位十六进制字符串（这是 Account ID 的格式），不是 API Token"
                    CF_Token=""
                elif [ "${#CF_Token}" -lt 20 ]; then
                    _warn "Token 看起来太短（${#CF_Token} 位），请确认复制完整"
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
            dns_plugin="$(_cert_dns_plugin || true)"
            _cf_from_interactive=1
        fi
    fi

    if [ -n "$dns_plugin" ]; then
        if [ -n "${_cf_from_interactive:-}" ]; then
            _info "已采用你输入的 Cloudflare 凭证，使用 DNS-01 挑战 (无需开放 80 端口)..."
        else
            _info "检测到 DNS API 环境变量，使用 DNS-01 挑战 (无需开放 80 端口)..."
        fi
        # 必须指定具体插件，光给 --dns 不够
        _info "使用 DNS 插件: ${dns_plugin}"
        if ! _cert_ensure_dns_plugin "$dns_plugin"; then
            _error "缺少 acme.sh 的 DNS 插件 ${dns_plugin}：单文件安装不含 dnsapi/ 目录，镜像下载也没成功"
            _warn "可手动补这一个文件后重跑："
            echo "    mkdir -p ${ACME_HOME}/dnsapi && curl -fsSL https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi/${dns_plugin}.sh -o ${ACME_HOME}/dnsapi/${dns_plugin}.sh" >&2
            return 1
        fi
        # Cloudflare 额外预检一次：把 "invalid domain" / 401 这类含糊报错提前翻译成人话
        if [ "$dns_plugin" = "dns_cf" ] && [ -n "${CF_Token:-}" ]; then
            _cert_cf_preflight "$CF_Token" "$domain" || return 1
        fi
        local acme_out rc=0
        acme_out=$("$ACME_BIN" "${issue_args[@]}" --dns "$dns_plugin" 2>&1) || rc=$?
        # 账号邮箱被 LE 拒（invalidContact）时，先换邮箱重注册再重试一次。
        # 老账号可能还绑着 example.com，只改 issue 参数不生效，必须 update-account。
        if [ $rc -ne 0 ] && _cert_out_bad_contact "$acme_out"; then
            _warn "Let's Encrypt 拒了这个账号邮箱，用 ${email} 重新注册账号后重试一次..."
            _cert_acme_register "$email"
            rc=0
            acme_out=$("$ACME_BIN" "${issue_args[@]}" --dns "$dns_plugin" 2>&1) || rc=$?
        fi
        # acme.sh 证书已存在时会输出 "Skipping" 并返回非 0, 视为成功继续落地证书 (幂等)
        if [ $rc -ne 0 ] && ! _cert_out_reuse "$acme_out"; then
            _error "DNS 模式签发失败，请重点看 acme.sh 错误关键字：invalid / permission / not found"
            echo "$acme_out" | tail -15
            if _cert_out_bad_contact "$acme_out"; then
                _warn "这次是账号邮箱被拒（example.com 是保留域名）。换真实邮箱重试：sb cert issue ${domain} you@yourdomain.com"
            else
                _info "常见原因：Token 无 DNS 编辑权限 / 域名未解析 / 子域名与 Zone 不匹配。详见：sb cert guide"
            fi
            return 1
        fi
        echo "$acme_out" | tail -3
    else
        _warn "未检测到 DNS API 变量。"
        _info "建议：export CF_Token/CF_Account_ID 后用 DNS-01（无需 80 端口），或尝试 standalone（需 80 可达）。"
        local acme_out rc=0
        acme_out=$("$ACME_BIN" "${issue_args[@]}" --standalone 2>&1) || rc=$?
        if [ $rc -ne 0 ] && _cert_out_bad_contact "$acme_out"; then
            _warn "Let's Encrypt 拒了这个账号邮箱，用 ${email} 重新注册账号后重试一次..."
            _cert_acme_register "$email"
            rc=0
            acme_out=$("$ACME_BIN" "${issue_args[@]}" --standalone 2>&1) || rc=$?
        fi
        # acme.sh 证书已存在时会输出 "Skipping" 并返回非 0, 视为成功继续落地证书 (幂等)
        if [ $rc -ne 0 ] && ! _cert_out_reuse "$acme_out"; then
            _error "standalone 签发失败：80 端口不可达或域名未解析。建议改用 DNS-01，详见：sb cert guide"
            echo "$acme_out" | tail -10
            return 1
        fi
        echo "$acme_out" | tail -3
    fi

    # 复制证书到统一目录
    mkdir -p "${CERT_ACME_DIR}/${domain}"
    # renew-hook: acme.sh 自动续期成功后, 同步新证书到 sing-box 并重启加载。
    # 路径在注册时即展开为绝对路径 (cron/timer 环境无我们的变量), 否则 90 天后续期
    # 成功但 cert.pem 还是旧证书 → 全部 TLS inbound 在旧证书过期后崩。
    local renew_hook
    renew_hook="$(_cert_renew_hook_cmd "$domain")"
    if ! "$ACME_BIN" --install-cert -d "$domain" \
        --fullchain-file "${CERT_ACME_DIR}/${domain}/fullchain.pem" \
        --key-file "${CERT_ACME_DIR}/${domain}/privkey.pem" \
        --renew-hook "$renew_hook" 2>/dev/null; then
        # 回退: 直接复制 acme.sh 仓库内证书 (ECC 证书落在 <域名>_ecc/)
        local src_dir=""
        for src_dir in "${ACME_HOME}/${domain}_ecc" "${ACME_HOME}/${domain}"; do
            [ -d "$src_dir" ] || continue
            cp -f "${src_dir}/fullchain.cer" "${CERT_ACME_DIR}/${domain}/fullchain.pem" 2>/dev/null || true
            cp -f "${src_dir}/${domain}.key" "${CERT_ACME_DIR}/${domain}/privkey.pem" 2>/dev/null || true
            break
        done
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
        # 没有自动续期调度 = 90 天后静默失效。这里保证一定有 (无 cron 时装 systemd timer)
        _cert_ensure_renew_schedule || true
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

     想要到期提醒就加邮箱：export CERT_EMAIL=you@qq.com；不加则用 acme@你的域名。
     ⚠️ 别用 example.com 结尾的邮箱——那是保留域名，Let's Encrypt 注册账号时会直接拒。

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
    # 续期顺手把"自动续期调度 + renew hook"补齐, 避免这次手动续了、下次到期又静默失效
    _cert_ensure_renew_schedule || true
    if [ -n "$domain" ]; then
        _cert_ensure_hook "$domain" || true
    fi
    _success "续期完成 (已签证书会在到期前自动续期, 续期后自动同步到 sing-box)"
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
        local days="" mark=""
        if [ -f "$cert_path" ] && command -v openssl >/dev/null 2>&1; then
            expiry=$( { openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2; } || true)
            expiry=$(date -d "$expiry" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                     || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                     || echo "$expiry")
            days=$(_cert_days_left "$cert_path" 2>/dev/null || true)
            if [ -n "$days" ] && [ "$days" -le 0 ]; then
                mark=" ${RED}[已过期]${NC}"
            elif [ -n "$days" ] && [ "$days" -lt 15 ]; then
                mark=" ${YELLOW}[剩 ${days} 天]${NC}"
            fi
        else
            expiry="未知"
        fi
        echo -e "  ${domain}  过期: ${expiry}${mark}  cert: ${cert_path}"
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
        sync)
            _cert_sync_all
            ;;
        fix)
            _cert_fix
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
            local _mode
            _mode=$(_cert_renew_schedule 2>/dev/null || true)
            case "$_mode" in
                cron)  _info "自动续期: 已注册 (cron)" ;;
                timer) _info "自动续期: 已注册 (systemd timer acme-renew.timer)" ;;
                *)     _warn "自动续期: 未注册 —— 证书到期后会静默失效，执行 sb cert fix 修复" ;;
            esac
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
    echo '  sync                  把 acme 证书同步到 cert.pem/key.pem 并重启 (修「续了没生效」)'
    echo "  fix                   一键修复: 补自动续期调度 + 补 renew hook + 同步证书"
    echo "  list                  列出已签发证书"
    echo "  status                状态"
fi
