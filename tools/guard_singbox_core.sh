#!/bin/bash
# v2rayN sing-box 核心版本守护脚本
# 用途: v2rayN 7.24.x 与 sing-box >=1.14 不兼容(DNS 规则缺 match_response 会 FATAL 崩核心)。
#       本脚本检测核心版本 + 校验配置, 不兼容时自动回滚到 1.13.21。
# 用法: bash guard_singbox_core.sh          # 检测并按需修复
#       bash guard_singbox_core.sh --check  # 只检测不修复

set -uo pipefail

VN_DIR="$HOME/Library/Application Support/v2rayN"
SB="$VN_DIR/bin/sing_box/sing-box"
CFG="$VN_DIR/binConfigs/config.json"
LOCK_VER="1.13.21"
MIRROR="https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ARCH=$(uname -m)   # arm64 / x86_64
[ "$ARCH" = "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"

# ── v2rayN 版本判定: >=7.25.0 已支持 sing-box 1.14, 无需降级 ──
VN_VER=$(defaults read /Applications/v2rayN.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
[ -z "$VN_VER" ] && VN_VER=$(grep -o 'v2rayN - V[0-9.]*' "$VN_DIR/guiLogs/$(date +%Y-%m-%d).txt" 2>/dev/null | tail -1 | sed 's/.*V//')
echo "[i] v2rayN 版本: ${VN_VER:-未知}"
VN_MAJOR_MINOR=$(echo "${VN_VER:-0.0}" | awk -F. '{print $1"."$2}')
VN_OK=0
case "$VN_MAJOR_MINOR" in
  7.25|7.26|7.27|7.28|7.29|8.*) VN_OK=1 ;;
esac
if [ "$VN_OK" -eq 1 ]; then
  echo "[✓] v2rayN >= 7.25.0, 原生支持 sing-box 1.14, 核心无需降级"
fi

if [ ! -x "$SB" ]; then
  echo "[✗] 找不到核心: $SB"
  exit 1
fi

CUR=$("$SB" version 2>/dev/null | head -1 | awk '{print $3}')
echo "[i] 当前核心版本: ${CUR:-未知}"
echo "[i] 配置文件: $CFG"

# 配置校验
if [ -f "$CFG" ]; then
  ERR=$("$SB" check -c "$CFG" 2>&1)
  if [ -n "$ERR" ]; then
    echo "[✗] 配置校验失败:"
    echo "$ERR" | head -3 | sed 's/^/     /'
    NEED_FIX=1
  else
    echo "[✓] 配置校验通过"
    NEED_FIX=0
  fi
else
  echo "[!] 还没有生成配置(先在 v2rayN 里启动一次核心) -> 跳过校验"
  NEED_FIX=0
fi

# 版本是否 >= 1.14 且 v2rayN 不支持
VER_MAJOR_MINOR=$(echo "$CUR" | awk -F. '{print $1"."$2}')
if { [ "$VER_MAJOR_MINOR" = "1.14" ] || [ "$VER_MAJOR_MINOR" = "1.15" ]; } && [ "$VN_OK" -eq 0 ]; then
  echo "[!] 核心版本 >=1.14, 且 v2rayN <7.25.0 -> 不兼容(需升级 v2rayN 或降级核心)"
  NEED_FIX=1
fi

if [ "$NEED_FIX" -eq 0 ]; then
  echo "[✓] 一切正常, 无需处理"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "[i] --check 模式, 不做修改。去掉 --check 即自动修复。"
  exit 2
fi

# ── 修复: 下载锁定版本核心并替换 ──
URL="$MIRROR/v$LOCK_VER/sing-box-$LOCK_VER-darwin-$SB_ARCH.tar.gz"
TMP=$(mktemp -d)
echo "[→] 下载 sing-box $LOCK_VER ($SB_ARCH)..."
if ! curl -m 300 -sL -o "$TMP/sb.tar.gz" "$URL" || [ ! -s "$TMP/sb.tar.gz" ]; then
  echo "[✗] 下载失败(镜像不可用?), 手动下载地址:"
  echo "     https://github.com/SagerNet/sing-box/releases/tag/v$LOCK_VER"
  rm -rf "$TMP"; exit 1
fi
tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
SRC=$(find "$TMP" -type f -name sing-box | head -1)

if [ -z "$SRC" ]; then
  echo "[✗] 解压失败"; rm -rf "$TMP"; exit 1
fi

cp "$SB" "$SB.$CUR.bak" 2>/dev/null || true
cp "$SRC" "$SB"
chmod +x "$SB"
xattr -d com.apple.quarantine "$SB" 2>/dev/null || true
rm -rf "$TMP"

NEW=$("$SB" version 2>/dev/null | head -1 | awk '{print $3}')
echo "[✓] 核心已回滚: $CUR -> $NEW"

if [ -f "$CFG" ]; then
  ERR2=$("$SB" check -c "$CFG" 2>&1)
  [ -z "$ERR2" ] && echo "[✓] 配置校验通过, 回 v2rayN 点「启用系统代理」即可" || { echo "[✗] 仍失败:"; echo "$ERR2" | head -3; exit 1; }
fi
