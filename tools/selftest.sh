#!/usr/bin/env bash
# ============================================================
# tools/selftest.sh — Singbox-Pro 冒烟测试
#
# 目的: 在没有真 sing-box / 真网卡的机器上，用假命令验证「不会静默崩」和
#       「NAT 机器入口 IP 判定」这两类最容易复发的问题。
#       全部操作在临时目录内，不读写 /etc，不动真实服务。
#
# 用法: bash tools/selftest.sh
# 退出码: 0 全部通过 / 1 有用例失败
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

_ok() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
_no() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
_eq() {
    if [ "$2" = "$3" ]; then _ok "$1"; else _no "$1  期望='$2' 实际='$3'"; fi
}

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t sb)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/singbox"

# ---------- 假命令 ----------
# ip: v4 输出受 FAKE_NIC_IP 控制; v6 一律空（本测试不覆盖 IPv6 探测）
cat > "$TMP/bin/ip" <<'FAKE_IP'
#!/bin/sh
case " $* " in
    *" -6 "*) exit 0 ;;
esac
# FAKE_NIC_DOCKER=1: 把 docker 网桥排在物理网卡前面（真机上的常见顺序），
# 用来验证「按接口名跳过网桥」而不是「按整行子串过滤」。
if [ "${FAKE_NIC_DOCKER:-0}" = "1" ]; then
    echo "3: br-994f372c53db: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP"
    echo "    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-994f372c53db"
fi
echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP"
echo "    inet ${FAKE_NIC_IP:-10.91.0.3}/24 brd 10.91.0.255 scope global eth0"
FAKE_IP

# curl: 任何请求都返回 FAKE_API_IP（模拟出口 IP 探测）
cat > "$TMP/bin/curl" <<'FAKE_CURL'
#!/bin/sh
echo "${FAKE_API_IP:-140.245.60.28}"
FAKE_CURL

# timeout: macOS 默认没有，用 shim 模拟（忽略超时参数，直接执行后面的命令）
cat > "$TMP/bin/timeout" <<'FAKE_TIMEOUT'
#!/bin/sh
shift
exec "$@"
FAKE_TIMEOUT

chmod +x "$TMP/bin/ip" "$TMP/bin/curl" "$TMP/bin/timeout"
export PATH="$TMP/bin:$PATH"

# ---------- 加载被测模块 ----------
export SINGBOX_DIR="$TMP/singbox"
export CONFIG_FILE="$SINGBOX_DIR/config.json"
export SERVER_IP_OVERRIDE=""
export DEFAULT_SNI="www.microsoft.com"
# shellcheck source=/dev/null
. "$ROOT/lib/core.sh"
# shellcheck source=/dev/null
. "$ROOT/lib/protocols.sh"

# 不同用例之间清掉 _get_public_ip 的全局缓存
_reset_ip() { server_ip=""; }

echo ""
echo "── 1. 语法检查 ─────────────────────────────"
for f in "$ROOT/sb.sh" "$ROOT/install.sh" "$ROOT"/lib/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        _ok "语法 OK: ${f#"$ROOT"/}"
    else
        _no "语法错误: ${f#"$ROOT"/}"
    fi
done

echo ""
echo "── 2. 内网 / CGNAT 判定 ────────────────────"
_t() { # 描述 期望(0=内网) IP
    if _is_private_ip "$3"; then got=0; else got=1; fi
    _eq "$1" "$2" "$got"
}
_t "10.91.0.3 是内网"        0 "10.91.0.3"
_t "100.64.0.7 是 CGNAT"     0 "100.64.0.7"
_t "100.127.255.254 是 CGNAT" 0 "100.127.255.254"
_t "172.20.1.1 是内网"       0 "172.20.1.1"
_t "fd91:cafe::3 是 ULA"     0 "fd91:cafe::3"
_t "fe80::1 是链路本地"      0 "fe80::1"
_t "100.128.0.1 不是 CGNAT"  1 "100.128.0.1"
_t "140.245.60.28 是公网"    1 "140.245.60.28"
_t "2603:c02b::7c 是公网"    1 "2603:c02b:30a:cd00::7c"

echo ""
echo "── 3. 入口 IP 探测（_get_public_ip）───────"
# 3.1 网卡有公网 IP → 优先用网卡，不该去问 API
_reset_ip
got=$(FAKE_NIC_IP=82.152.161.198 FAKE_API_IP=1.1.1.1 _get_public_ip 2>/dev/null)
_eq "网卡公网优先于 API" "82.152.161.198" "$got"

# 3.1b 回归：旧写法 grep -v 'lo' 会连 "scope global" 的正常行一起过滤掉（"global" 含 "lo"），
#      导致网卡探测永远为空。这里直接断言 _nic_ipv4 拿得到地址。
got=$(FAKE_NIC_IP=82.152.161.198 _nic_ipv4 2>/dev/null)
_eq "网卡 IPv4 能被取出（不被 scope global 里的 lo 误杀）" "82.152.161.198" "$got"

# 3.1c docker 网桥排在物理网卡前面时必须跳过网桥（真机顺序常见）
got=$(FAKE_NIC_DOCKER=1 FAKE_NIC_IP=82.152.161.198 _nic_ipv4 2>/dev/null)
_eq "docker 网桥排在前面时跳过网桥" "82.152.161.198" "$got"

# 3.2 网卡是 NAT 内网 → 回退 API；且必须告警（不能静默把 10.x 写进节点）
_reset_ip
got=$(FAKE_NIC_IP=10.91.0.3 FAKE_API_IP=140.245.60.28 _get_public_ip 2>"$TMP/err1")
_eq "NAT 内网 → 回退 API" "140.245.60.28" "$got"
if grep -q '内网' "$TMP/err1"; then _ok "NAT 内网场景有告警"; else _no "NAT 内网场景缺少告警"; fi

# 3.3 探测到 CGNAT → 同样要告警
_reset_ip
got=$(FAKE_NIC_IP=10.91.0.3 FAKE_API_IP=100.64.1.2 _get_public_ip 2>"$TMP/err2")
if grep -q 'CGNAT' "$TMP/err2"; then _ok "CGNAT 场景有告警"; else _no "CGNAT 场景缺少告警"; fi

# 3.4 手动指定入口（域名）必须原样返回 —— NAT 机器的常用解法
_reset_ip
got=$(SERVER_IP_OVERRIDE="mo1.deeprush.ai" _get_public_ip 2>/dev/null)
_eq "入口 IP 可填域名" "mo1.deeprush.ai" "$got"

# 3.5 set -euo pipefail 下不得崩溃（历史 bug: 管道非零把整个面板带走）
if ( set -euo pipefail; _reset_ip; FAKE_NIC_IP=10.91.0.3 _get_public_ip >/dev/null 2>&1 ); then
    _ok "set -e 下调用不退出"
else
    _no "set -e 下调用直接退出（会表现为菜单闪退）"
fi

echo ""
echo "── 4. 节点链接生成 ────────────────────────"
# 4.1 VLESS-WS 省略 SNI 时必须回落到服务器地址（历史 bug: 同一 local 里引用未赋值变量 → SNI 为空）
uri=$(_proto_vless_ws_uri "11111111-2222-3333-4444-555555555555" "82.152.161.198" "50006")
case "$uri" in
    *"sni=82.152.161.198"*) _ok "VLESS-WS 缺省 SNI 回落到服务器地址" ;;
    *) _no "VLESS-WS 缺省 SNI 异常: $uri" ;;
esac

# 4.2 IPv6 地址必须带方括号，否则链接无法解析
h=$(_proto_fmt_host "2603:c02b:30a:cd00::7c")
_eq "IPv6 地址加方括号" "[2603:c02b:30a:cd00::7c]" "$h"

# 4.3 IPv4 不得被加括号
h=$(_proto_fmt_host "82.152.161.198")
_eq "IPv4 原样输出" "82.152.161.198" "$h"

# 4.4 Reality 全参调用：sni / pbk / sid 都要正确落进链接
uri=$(_proto_reality_uri "uuid-1" "82.152.161.198" "50001" "www.microsoft.com" "ab12" "HK-Reality" "xtls-rprx-vision" "PBKKEY")
case "$uri" in
    *"sni=www.microsoft.com"*"pbk=PBKKEY"*"sid=ab12"*) _ok "Reality 链接参数完整" ;;
    *) _no "Reality 链接参数缺失: $uri" ;;
esac

# 4.5 Reality 省略 sid/name/pbk（set -u 下不得 unbound 崩溃）
if uri=$(_proto_reality_uri "uuid-1" "82.152.161.198" "50001" 2>/dev/null); then
    _ok "Reality 缺省参数不崩溃"
else
    _no "Reality 缺省参数直接崩溃"
fi

echo ""
echo "── 5. acme.sh 安装判定 ────────────────────"
CT="$TMP/cert"; mkdir -p "$CT/bin" "$CT/home"
# 假 curl：get.acme.sh 返回一个「只打印 Install error、退出码 0」的安装器，其余请求一律失败。
# 这正是线上踩到的形态——安装器失败却不 exit 1，旧代码据此判成功，后面各档全被跳过。
cat > "$CT/bin/curl" <<'FAKE_ACMECURL'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    *get.acme.sh)
        printf '#!/bin/sh\necho "Install error"\nexit 0\n' > "$out"
        exit 0 ;;
    *) exit 22 ;;
esac
FAKE_ACMECURL
printf '#!/bin/sh\nexit 1\n' > "$CT/bin/git"      # 假装没有 git，避免真联网
printf '#!/bin/sh\nexit 1\n' > "$CT/bin/crontab"  # 不碰本机 crontab
chmod +x "$CT/bin/"*

rm -f /tmp/acme_install.diag

# 5.1 安装器退出码 0 却没生成 acme.sh → 必须判失败，且不能把 set -e 带崩
rc=0
HOME="$CT/home" SINGBOX_DIR="$CT/sb" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"; _cert_acme_install' \
    _ "$ROOT" >/dev/null 2>&1 || rc=$?
_eq "安装器假成功（退出码0/无文件）判为失败" "1" "$rc"

# 5.2 失败时诊断表要写明是哪一档断的，而不是一片空白
if grep -q 'Install error' /tmp/acme_install.diag 2>/dev/null; then
    _ok "失败诊断表记录了安装器报错"
else
    _no "失败诊断表为空或没记原因"
fi

# 5.3 已存在 acme.sh 时直接返回 0，不应再联网
mkdir -p "$CT/home2/.acme.sh"
printf '#!/bin/sh\necho v9.9.9\n' > "$CT/home2/.acme.sh/acme.sh"
chmod +x "$CT/home2/.acme.sh/acme.sh"
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CT/sb2" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"; _cert_acme_install >/dev/null 2>&1' \
    _ "$ROOT" || rc=$?
_eq "已装 acme.sh 时直接返回 0" "0" "$rc"

# 5.4 DNS 插件识别不得走 env|grep（pipefail 下 SIGPIPE 会让它误判成"没设置凭证"）
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CT/sb2" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        export CF_Token="dummy_token_1234567890" CF_Account_ID="72031701f741ca2f0d287c2d6fdf750a"
        p="$(_cert_dns_plugin)"; [ "$p" = "dns_cf" ] || exit 3' _ "$ROOT" || rc=$?
_eq "有 CF_Token 时识别为 dns_cf" "0" "$rc"

# 5.5 无凭证时不得误判成有插件
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CT/sb2" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        unset CF_Token CF_Key Ali_Key DP_Id DNSPOD_ID GANDI_API_KEY OCI_CLI_TENANCY 2>/dev/null || true
        p="$(_cert_dns_plugin)" || exit 0; [ -z "$p" ] || exit 4' _ "$ROOT" || rc=$?
_eq "无凭证时插件识别为空" "0" "$rc"

# 5.6 账号邮箱不能再用 example.com（LE 保留域名，注册即 400 invalidContact）
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CT/sb2" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        if _cert_email_ok "admin@example.com"; then exit 3; fi
        if ! _cert_email_ok "acme@hk.brad.dpdns.org"; then exit 4; fi
        [ "$(_cert_default_email zouter.hk.brad.dpdns.org)" = "acme@zouter.hk.brad.dpdns.org" ] || exit 5
        [ -z "$CERT_EMAIL" ] || exit 6' _ "$ROOT" || rc=$?
_eq "默认邮箱推导为 acme@<域名> 且拒收 example.com" "0" "$rc"

# 5.7 acme.sh 输出判定：invalidContact 要能认出来，"Skipping" 要当成功
#     (注意别写成 `cmd && exit N`：set -e 会在 cmd 返回 1 时直接退出整个脚本)
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CT/sb2" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        bad="Error validating contact(s) :: contact email has forbidden domain example.com"
        if ! _cert_out_bad_contact "$bad"; then exit 3; fi
        if _cert_out_bad_contact "Cert success"; then exit 4; fi
        if ! _cert_out_reuse "Skipping. Next renewal time is 2027-02-01"; then exit 5; fi
        if _cert_out_reuse "Some other error"; then exit 6; fi' _ "$ROOT" || rc=$?
_eq "签发输出判定（invalidContact / Skipping）" "0" "$rc"

# 5.8 端到端：第一次 --issue 被 LE 拒邮箱 → 必须换邮箱重注册 + 重试一次才成功
#     同时保证 --issue 参数里不再塞 --accountemail（旧 bug 的源头）
AD="$CT/acme3"; mkdir -p "$AD/home/.acme.sh/dnsapi" "$AD/sb"
printf '#!/bin/sh\n' > "$AD/home/.acme.sh/dnsapi/dns_cf.sh"
cat > "$AD/home/.acme.sh/acme.sh" <<'FAKE_ACME'
#!/bin/sh
log="${ACME_ARGV_LOG:?}"
printf '%s\n' "$*" >> "$log"
case " $* " in
    *" --version "*) echo "v3.1.7"; exit 0 ;;
esac
case " $* " in
    *" --issue "*)
        n=$(grep -c -- '--issue' "$log" 2>/dev/null || echo 0)
        if [ "${n:-0}" -le 1 ]; then
            cat <<'ERR'
Using CA: https://acme-v02.api.letsencrypt.org/directory
Account registration error: {
"type": "urn:ietf:params:acme:error:invalidContact",
"detail": "contact email has forbidden domain \"example.com\"",
"status": 400
}
ERR
            exit 1
        fi
        echo "Cert success."
        exit 0 ;;
esac
case " $* " in
    *" --install-cert "*)
        while [ $# -gt 0 ]; do
            case "$1" in
                --fullchain-file) echo CERT > "$2"; shift 2 ;;
                --key-file) echo KEY > "$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        exit 0 ;;
esac
exit 0
FAKE_ACME
chmod +x "$AD/home/.acme.sh/acme.sh"
# 假 curl：让 Cloudflare 预检（tokens/verify + zones）通过，走到真正的 --issue
mkdir -p "$AD/bin"
cat > "$AD/bin/curl" <<'FAKE_CURL2'
#!/bin/sh
case "$*" in
    *tokens/verify*) echo '{"success":true,"result":{"status":"active"}}' ;;
    *"/zones?name="*) echo '{"success":true,"result":[{"name":"brad.dpdns.org","id":"z"}]}' ;;
    *) exit 22 ;;
esac
FAKE_CURL2
chmod +x "$AD/bin/curl"
export ACME_ARGV_LOG="$AD/argv.log"; : > "$ACME_ARGV_LOG"
rc=0
HOME="$AD/home" SINGBOX_DIR="$AD/sb" CERT_ACME_DIR="$AD/sb/acme" \
    PATH="$AD/bin:$PATH" CF_Token="dummy_token_1234567890" CF_Account_ID="72031701f741ca2f0d287c2d6fdf750a" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        _cert_acme_issue zouter.hk.brad.dpdns.org' _ "$ROOT" >/dev/null 2>&1 || rc=$?
_eq "邮箱被拒后自动换邮箱重试并签发成功" "0" "$rc"

issue_n=$(grep -c -- '--issue' "$ACME_ARGV_LOG" 2>/dev/null || true)
_eq "失败后真的重试了一次 --issue" "2" "${issue_n:-0}"

if grep -q 'acme@zouter.hk.brad.dpdns.org' "$ACME_ARGV_LOG" && ! grep -q 'example\.com' "$ACME_ARGV_LOG"; then
    _ok "注册账号用的是 acme@<域名>，未出现 example.com"
else
    _no "账号邮箱仍是 example.com 或没带邮箱"
fi

if grep -q -- '--accountemail' "$ACME_ARGV_LOG"; then
    _no "--issue 仍带 --accountemail（该参数不生效，会被 LE 忽略/误用）"
else
    _ok "--issue 不再带 --accountemail"
fi

# 5.9 剩余天数计算：2 天期的自签证书应算出 1~3 天；文件不存在要返回非 0
CD="$CT/certchk"; mkdir -p "$CD/sb"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CD/k.pem" -out "$CD/c.pem" \
    -days 2 -subj "/CN=selftest" >/dev/null 2>&1
rc=0
HOME="$CT/home2" SINGBOX_DIR="$CD/sb" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        d=$(_cert_days_left "$2") || exit 3
        { [ "$d" -ge 1 ] && [ "$d" -le 3 ]; } || exit 4
        if _cert_days_left /nonexistent/x.pem; then exit 5; fi' _ "$ROOT" "$CD/c.pem" || rc=$?
_eq "剩余天数计算 (_cert_days_left)" "0" "$rc"

# 5.10 续期调度三态识别：cron / systemd timer / 都没有
FB="$CT/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\ncat "$CRON_OUT" 2>/dev/null\n' > "$FB/crontab"
printf '#!/bin/sh\ncat "$TIMER_OUT" 2>/dev/null\n' > "$FB/systemctl"
chmod +x "$FB/crontab" "$FB/systemctl"
printf '47 2,8,14,20 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null\n' > "$CT/cron.txt"
printf 'acme-renew.timer acme-renew.timer - Daily acme.sh renewal check\n' > "$CT/timer.txt"
: > "$CT/empty.txt"
rc=0
CRON_OUT="$CT/cron.txt" TIMER_OUT="$CT/empty.txt" \
HOME="$CT/home2" SINGBOX_DIR="$CD/sb" PATH="$FB:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        [ "$(_cert_renew_schedule)" = "cron" ] || exit 3' _ "$ROOT" || rc=$?
_eq "调度识别: crontab 有 acme --cron → cron" "0" "$rc"

rc=0
CRON_OUT="$CT/empty.txt" TIMER_OUT="$CT/timer.txt" \
HOME="$CT/home2" SINGBOX_DIR="$CD/sb" PATH="$FB:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        [ "$(_cert_renew_schedule)" = "timer" ] || exit 3' _ "$ROOT" || rc=$?
_eq "调度识别: 无 cron 但有 acme-renew.timer → timer（香港机那种情况）" "0" "$rc"

rc=0
CRON_OUT="$CT/empty.txt" TIMER_OUT="$CT/empty.txt" \
HOME="$CT/home2" SINGBOX_DIR="$CD/sb" PATH="$FB:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        if _cert_renew_schedule >/dev/null; then exit 3; fi
        [ "$(_cert_renew_schedule || true)" = "none" ] || exit 4' _ "$ROOT" || rc=$?
_eq "调度识别: 两者都没有 → none 且返回非 0" "0" "$rc"

# 5.11 配置定位要兼容 <域名>_ecc/ 与 <域名>/ 两种布局（acme.sh ECC 证书用前者）
AC="$CT/acmehome"; mkdir -p "$AC/.acme.sh/a.example_ecc" "$AC/.acme.sh/b.example"
: > "$AC/.acme.sh/a.example_ecc/a.example.conf"
: > "$AC/.acme.sh/b.example/b.example.conf"
rc=0
HOME="$AC" SINGBOX_DIR="$CD/sb" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        [ "$(_cert_conf_file a.example)" = "$HOME/.acme.sh/a.example_ecc/a.example.conf" ] || exit 3
        [ "$(_cert_conf_file b.example)" = "$HOME/.acme.sh/b.example/b.example.conf" ] || exit 4
        if _cert_conf_file c.example >/dev/null; then exit 5; fi' _ "$ROOT" || rc=$?
_eq "acme 配置定位（_ecc 与普通布局）" "0" "$rc"

# 5.12 自检必须能发现「cert.pem 与 acme 证书不一致」与「没注册 renew hook」
SC="$CT/sc"; mkdir -p "$SC/sb/acme/d.example"
cp "$CD/c.pem" "$SC/sb/acme/d.example/fullchain.pem"; cp "$CD/k.pem" "$SC/sb/acme/d.example/privkey.pem"
cp "$CD/c.pem" "$SC/sb/cert.pem"
printf '{"d.example":{"cert":"%s","key":"%s"}}\n' "$SC/sb/acme/d.example/fullchain.pem" "$SC/sb/acme/d.example/privkey.pem" > "$SC/sb/cert_metadata.json"
mkdir -p "$SC/home/.acme.sh/d.example_ecc"
printf "Le_RenewHook=''\nLe_ReloadCmd=''\n" > "$SC/home/.acme.sh/d.example_ecc/d.example.conf"
rc=0
CRON_OUT="$CT/cron.txt" TIMER_OUT="$CT/empty.txt" \
HOME="$SC/home" SINGBOX_DIR="$SC/sb" CERT_META_FILE="$SC/sb/cert_metadata.json" \
CERT_ACME_DIR="$SC/sb/acme" PATH="$FB:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        out=$(_cert_selfcheck)
        printf "%s\n" "$out" | grep -q "未注册续期 hook" || exit 3
        printf "%s\n" "$out" | grep -q "剩" || exit 4
        printf "%s\n" "$out" | grep -q "同步" || exit 5' _ "$ROOT" || rc=$?
_eq "自检: 无 hook 要告警、证书一致时要报同步" "0" "$rc"

# 5.13 selfcheck 每条输出都必须是 "<ok|warn|fail>\t<文案>"（健康检查靠 tab 分列渲染）
rc=0
CRON_OUT="$CT/cron.txt" TIMER_OUT="$CT/empty.txt" \
HOME="$SC/home" SINGBOX_DIR="$SC/sb" CERT_META_FILE="$SC/sb/cert_metadata.json" \
CERT_ACME_DIR="$SC/sb/acme" PATH="$FB:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        _cert_selfcheck | while IFS=$'"'"'\t'"'"' read -r st msg; do
            case "$st" in ok|warn|fail) ;; *) exit 3 ;; esac
            [ -n "$msg" ] || exit 4
        done' _ "$ROOT" || rc=$?
_eq "自检输出格式 (状态\\t文案)" "0" "$rc"

# 5.14 cert.pem 对齐后 serial 必须与 acme 证书一致（这就是事故的判据）
rc=0
HOME="$SC/home" SINGBOX_DIR="$SC/sb" CERT_ACME_DIR="$SC/sb/acme" PATH="$CT/bin:$PATH" \
    bash -c 'set -euo pipefail; . "$1/lib/core.sh"; . "$1/lib/cert.sh"
        _cert_sync_cert d.example || exit 3
        s1=$(_cert_serial "$SINGBOX_DIR/cert.pem"); s2=$(_cert_serial "$SINGBOX_DIR/acme/d.example/fullchain.pem")
        [ -n "$s1" ] && [ "$s1" = "$s2" ] || exit 4
        [ "$(stat -c %a "$SINGBOX_DIR/cert.pem" 2>/dev/null || stat -f %Lp "$SINGBOX_DIR/cert.pem")" = "644" ] || exit 5' _ "$ROOT" || rc=$?
_eq "证书同步后 cert.pem 与 acme 序列号一致且权限 644" "0" "$rc"

echo ""
echo "────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    printf '  \033[0;32m全部通过\033[0m (%d 项)\n\n' "$PASS"
    exit 0
fi
printf '  \033[0;31m失败 %d 项\033[0m / 通过 %d 项\n\n' "$FAIL" "$PASS"
exit 1
