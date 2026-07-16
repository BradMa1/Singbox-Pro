# Sing-box Pro

多协议节点部署管理脚本，支持 5 种协议自由组合 + 协议中转 + Argo 隧道 + 端口转发 + WARP 域名分流。

## 支持协议

| 协议 | 特点 |
|:----|:----|
| VLESS Reality Vision | TCP 伪装，无需域名，最稳首选 |
| AnyTLS | 新一代伪装协议 |
| TUIC V5 | QUIC 协议，低延迟 |
| Hysteria2 | UDP 加速，弱网友好 |
| VMess WebSocket | WebSocket 传输，默认 TLS |

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```

> 上面命令优先用 `curl`，若系统没有 `curl` 会自动回退到 `wget`（仅装了 wget 的精简系统也能一键安装）。
如遇Alpine系统无法安装，可先执行以下命令：
```
# 更新仓库索引
apk update

# 安装 bash
apk add bash

# 安装完成后检查版本
bash --version
```

## 管理面板

安装后直接输入 `sb` 进入交互式管理面板，所有操作菜单驱动：

```
  ╔════════════════════════════════════════════════╗
  ║              Singbox-Pro   v2.0.2              ║
  ║              Multi-Protocol Proxy              ║
  ╚════════════════════════════════════════════════╝

  地区: 日本 东京 | racknerd-abc123
  系统: Debian 12 | BBR: bbr | CPU: Intel Xeon E5-2xxx | 内存: 256M/1.0G | 磁盘: 18%
  IPv4: 151.244.134.189  IPV6: 无

  Sing-box v1.13.14 ● 运行中 | Argo ● 运行中 (2隧道) | WARP ○ 未安装 | 节点: 5
  ─────────────────────────────────────────────────
  【节点管理】
    [1] 添加节点          [2] Argo 隧道节点
    [3] 查看节点链接      [4] 删除节点
    [5] 修改节点

  【服务控制】
    [6] 重启服务          [7] 停止服务

  【进阶功能】
    [8] 中转管理          [9] WARP 管理
    [10] IPv6 优化        [11] 流媒体 DNS

  【系统维护】
    [12] 安装/更新核心    [13] 卸载脚本
    [14] 健康检查          [15] 升级脚本

  ─────────────────────────────────────────────────
    [0] 退出脚本
```

除了交互面板，还支持命令行操作（见下方 [CLI 命令](#cli-命令)），方便脚本化管理和远程诊断。

## CLI 命令

安装后 `sb` 支持以下命令行操作：

| 命令 | 说明 |
|:-----|:------|
| `sb` (无参数) | 启动交互式管理面板 |
| `sb status` | 快速查看运行状态 |
| `sb health` | 深度健康检查（依赖/进程/端口/DNS/系统资源/扩展服务） |
| `sb restart` | 重启 sing-box 服务 |
| `sb stop` | 停止 sing-box 服务 |
| `sb log` | 查看实时日志 |
| `sb upgrade` | 升级管理脚本到最新版 |
| `sb backup` | 备份当前配置 |
| `sb help` | 显示帮助信息 |

### sb health 输出示例

```
══════════════════════════════════════════
       Singbox-Pro 深度健康检查
══════════════════════════════════════════

── 核心依赖 ──
  ✓ jq (jq-1.7.1)
  ✓ curl (curl 8.4.0)
  ✓ openssl (OpenSSL 3.1.4)

── sing-box ──
  ✓ 二进制文件 (/usr/local/bin/sing-box v1.13.14)
  ✓ 配置文件 (config.json 语法正确)
  ✓ 服务状态 (运行中)

── 端口监听 ──
  共 3 个节点:
    ✓ vless:44314 (监听正常)

── DNS 解析 ──
    ✓ google.com (解析正常)
  ✓ DNS 整体状况

── 系统资源 ──
  ✓ 内存使用 (128M / 1024M)
  ✓ 磁盘使用率 (18%)

── 扩展服务 ──
  ✓ Argo 隧道 (运行中)
  ✓ WARP (未安装)

══════════════════════════════════════════
  ✓ 所有检查通过，系统运行正常
══════════════════════════════════════════
```

## 添加节点（菜单 1）

多协议自由组合，支持批量添加，安装时可选节点名称前缀。

```
1) VLESS Reality   2) AnyTLS   3) TUIC V5
4) Hysteria2       5) VMess WS
```

## Argo 隧道节点（菜单 2）

通过 Cloudflare Tunnel 将节点暴露到公网，无需独立 IP 或开放端口。

| 模式 | 说明 |
|:-----|:-----|
| 临时隧道 | 免费，随机 `*.trycloudflare.com` 域名 |
| 固定隧道 | 需要 Cloudflare Token + 自定义域名，更稳定 |

子菜单: 创建 VLESS-WS/VMess-WS + Argo、查看/删除节点、重启隧道、查看日志。

> Argo 隧道由 systemd 托管（`argo-tunnel@<端口>` / `argo-fixed@<端口>`，`Restart=always`），VPS 重启后自动恢复，无需看门狗。

## 查看节点链接（菜单 3）

自动生成所有已启用协议的分享链接并打印到屏幕（不会写入文件）。

## 删除 / 修改节点（菜单 4/5）

按编号删除或修改单个节点（端口、UUID 等），自动重启服务生效。

---

## 中转管理（菜单 8）

支持两套中转方案。

### 方案一：线路机安装脚本

在落地机上生成安装脚本 → 复制到中转机一键执行。

```
客户端 → 中转机(VLESS Reality) → 落地机(VLESS Reality) → 外网
```

### 方案二：Token 全协议中转

落地机生成 Token → 中转机导入。支持所有已部署协议。

| 落地协议 | 支持 |
|:---------|:----|
| VLESS Reality | ✅ |
| TUIC V5 | ✅ |
| Hysteria2 | ✅ |
| AnyTLS | ✅ |
| Shadowsocks | ✅ |
| VMess WS | ✅ |

中转入口协议可选 VLESS Reality / Hysteria2 / TUIC / AnyTLS。VLESS Reality 入口的 outbound 会自动注入 `utls` 指纹和落地机 `public_key`。

---

## WARP 管理（菜单 9）

一键安装 WARP SOCKS5 代理 + 自动域名分流。

| 功能 | 说明 |
|:-----|:-----|
| [1] 安装 WARP | 下载安装 warp-plus |
| [2] 启动 WARP | 启动 SOCKS5 代理 (40000 端口) |
| [3] 停止 WARP | 停止 SOCKS5 代理 |
| [4] 添加到 sing-box | 加入 proxy 选择器 + 配置域名路由 |
| [5] 卸载 WARP | 清理 WARP 及分流规则 |

### 域名分流管理

| [6] 查看列表 | 显示当前所有分流域名 |
| [7] 添加域名 | 支持空格分隔多个域名 |
| [8] 删除域名 | 按编号删除自定义域名 |
| [9] 重置列表 | 恢复默认 AI 域名列表 |

**默认分流域名**: `openai.com` `chat.openai.com` `api.openai.com` `claude.ai` `api.claude.ai` `anthropic.ai` `gemini.google.com` `bard.google.com` `copilot.microsoft.com`

- 路由规则：通过 `warp-domain-rule` outbound 将匹配域名导向 WARP SOCKS5
- DNS 规则：通过 `dns-warp` 服务器走 WARP 加密通道解析，防 DNS 泄漏

---

## IPv6 优化（菜单 10）

让 sing-box 出站连接优先使用 IPv6，有助于解锁流媒体。

| 选项 | 说明 |
|:-----|:-----|
| [1] 启用 IPv6 优先 | DNS 策略切换为 `prefer_ipv6`，DNS 服务器改用 IPv6 地址 |
| [2] 恢复 IPv4 优先 | 恢复默认配置 |

启用后 DNS 变更：

| DNS 角色 | 默认 (IPv4) | IPv6 模式 |
|:---------|:-----------|:----------|
| 国内解析 | `223.5.5.5`（阿里） | `2400:3200::1`（阿里 IPv6） |
| 国外解析 | `8.8.8.8`（Google） | `2001:4860:4860::8888`（Google IPv6） |

前提：VPS 必须有公网 IPv6 地址。

---

## 流媒体 DNS 解锁（菜单 11）

设置专用 DNS 让 Netflix、Disney+ 等流媒体域名走指定解析，绕开机房 IP 封杀。

| 选项 | 说明 |
|:-----|:-----|
| [1] 设置流媒体 DNS | 输入 DNS 地址（如 `151.243.229.229`） |
| [2] 移除流媒体 DNS | 恢复默认 DNS 解析 |

**覆盖域名**: Netflix, Disney+, HBO Max, Hulu, Prime Video, YouTube, Spotify, TikTok, DAZN, Paramount+, Peacock, Apple TV+

原理：只对流媒体域名使用该 DNS，其他域名不受影响。

---

## 端口转发（中转菜单 6）

基于 iptables DNAT 的内核级端口转发，支持 TCP/UDP/双栈。

- 添加规则时自动持久化（systemd/Alpine local.d），重启不丢失
- 支持查看和按端口删除规则

---

## 文件结构

### 服务端（安装后）

```
/usr/local/etc/sing-box/
├── config.json          # 主配置（含 dns / route / ntp）
├── metadata.json        # 节点元数据（含 Reality public_key 等）
├── certs/               # 自签证书
├── pf.json              # 端口转发规则
├── relay.json           # 中转路由元数据
├── argo/                # Argo 固定隧道 Token（权限 600）
├── argo_metadata.json   # Argo 隧道元数据
├── warp-meta.json       # WARP 域名分流元数据
├── .ipv6_dns_enabled    # IPv6 DNS 状态标记
├── .streaming_dns       # 流媒体 DNS 地址缓存
├── .server_info         # VPS 状态面板缓存（60 分钟有效）
└── .backup.*/           # sb upgrade 自动备份目录
```

> sing-box 本体、Argo（cloudflared）、WARP（warp-plus）的可执行文件均安装在 `/usr/local/bin/`。

### 运行时

```
/var/log/sing-box.log                       # sing-box 运行日志
journalctl -u argo-tunnel@<端口>            # Argo 临时隧道日志（systemd）
journalctl -u argo-fixed@<端口>             # Argo 固定隧道日志（systemd）
journalctl -u warp-plus                     # WARP 日志（systemd）
```

### 系统配置

```
/etc/systemd/system/sing-box.service        # sing-box 服务（Restart=on-failure）
/etc/systemd/system/argo-tunnel@.service    # Argo 临时隧道模板（Restart=always）
/etc/systemd/system/argo-fixed@.service     # Argo 固定隧道模板（Restart=always）
/etc/systemd/system/warp-plus.service       # WARP 服务（Restart=always）
/etc/logrotate.d/sing-box                   # 日志轮转（保留 7 天，自动压缩）
```

### 项目源文件

```
singbox-pro/
├── sb.sh              # 主入口（CLI 命令 + 面板启动）
├── install.sh         # 一键安装脚本
├── README.md          # 本文件
├── lib/
│   ├── core.sh        # 核心工具（颜色/网络/JSON/版本号 SSOT）
│   ├── singbox.sh     # sing-box 安装/配置/健康检查/升级
│   ├── protocols.sh   # 5 种协议生成/URI/删除
│   ├── argo.sh        # Argo 隧道管理
│   ├── warp.sh        # WARP 安装 & 域名分流
│   ├── relay.sh       # 中转 & 端口转发
│   └── ui.sh          # 交互面板界面
```

## 系统要求

- OS: Debian 11+ / Ubuntu 20+ / CentOS 7+ / Alpine / Fedora
- 架构: x86_64 / aarch64
- 权限: root

## 国内加速

```bash
export GH_MIRROR="https://ghproxy.com/"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh || wget -qO- https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```

> `GH_MIRROR` 会作为 GitHub 镜像前缀使用（默认值 `https://ghproxy.net/`），可替换为任意可用镜像。该变量同时作用于安装脚本与各模块的下载回退逻辑。

## 注意事项

- VLESS Reality outbound 自动配置 `utls: chrome` 指纹（sing-box 要求）
- 中转 Token 生成时自动读取落地机 metadata.json 获取 `public_key`
- VMess WebSocket 使用自签证书加密，客户端需跳过证书验证
- AnyTLS / Hysteria2 / TUIC 使用自签证书，URI 已含 `insecure=1`
- WARP 域名分流通过 DNS 规则确保 AI 域名走 WARP 通道解析
- `sb upgrade` 自动备份当前版本到 `.backup.时间戳/`，升级失败自动回滚
- 安装脚本自动配置 logrotate 日志轮转（Logrotate 未安装时跳过）

---

## 更新日志

### v2.0.2 (2026-07-16)

**优化**
- 一键安装脚本与脚本内部下载全面支持 **wget 兜底**：系统没有 `curl` 时（仅装了 `wget` 的精简镜像）也能正常安装
  - README 一键安装 / 国内加速命令改为 `curl ... || wget -qO- ...` 双兜底
  - 依赖检查（`_check_deps`）放宽为 `curl` / `wget` 二选一
  - 公网 IP 探测（`_get_public_ip`）增加 `wget` 回退路径

### v2.0.1 (2026-07-16)

**修复**
- 修复「修改节点」功能因缺少用户输入导致永远返回「未修改」的 Bug
- 修复中转 Token 保存到文件时只保留最后一个节点的 Token
- 修复删除节点时端口号从 tag 名称猜测（`grep -oE`），改为从 config.json 提取真实端口

**新增功能**
- `sb health` — 深度健康检查（6 大项：依赖/进程/端口/DNS/系统资源/扩展服务）
- `sb upgrade` — 一键升级所有管理脚本到最新版（自动备份 + 回滚）
- 交互面板新增 **[14] 健康检查**、**[15] 升级脚本** 菜单项，小白用户无需记 CLI 命令
- 安装脚本自动配置 logrotate 日志轮转（保留 7 天，自动压缩）

**重构 / 优化**
- `SB_VERSION` 统一到 `core.sh`（SSOT 原则），`install.sh` 不再硬编码版本号
- 首次安装即生成含 `dns` / `route` / `ntp` 的完整配置，修复菜单 [9]/[10]/[11]（WARP / IPv6 DNS / 流媒体 DNS）因缺 dns 段而失效的问题
- sing-box 版本升级至 **1.13.14**
- Argo 隧道与 WARP 改为 **systemd 托管**（`Restart=always`），VPS 重启后自动恢复
- 安装阶段补装 DNS 工具（`dnsutils` / `bind-tools` / `bind-utils`），健康检查 DNS 项不再误报
- 中继线路机安装脚本自动识别 sing-box 安装路径（优先 `/usr/local`，回退官方 `/usr`）
- 修复 README 文档漂移：配置路径、被夸大的 `sb keepalive` 看门狗、未实际保存的 `uris.txt`、`GH_MIRROR` 环境变量现已生效
- `GH_MIRROR` 环境变量现已真正生效（作为 GitHub 镜像前缀）
- 健康检查版本号取值统一；DNS 解析判定统一为单一工具 + 明确成功/失败
- 清理冗余：`_download` 重复 curl、`sb restart` 双重启、`export -f` 多余导出
