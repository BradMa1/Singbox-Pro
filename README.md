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
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```
如遇Alpine系统无法安装，可先执行以下命令：
```# 更新仓库索引
apk update

# 安装 bash
apk add bash

# 安装完成后检查版本
bash --version
```

## 管理面板

安装后输入 `sb` 进入管理面板：

```
  ╔════════════════════════════════════════════════╗
  ║              Singbox-Pro   v2.0.0              ║
  ║              Multi-Protocol Proxy              ║
  ╚════════════════════════════════════════════════╝

  地区: 日本 东京 | racknerd-abc123
  系统: Debian 12 | BBR: bbr | CPU: Intel Xeon E5-2xxx | 内存: 256M/1.0G | 磁盘: 18%
  IPv4: 151.244.134.189  IPV6: 无

  Sing-box v1.13.12 ● 运行中 | Argo ● 运行中 (2隧道) | WARP ○ 未安装 | 节点: 5
  ─────────────────────────────────────────────────
  【节点管理】
    [1] 添加节点          [2] Argo 隧道节点
    [3] 查看节点链接      [4] 删除节点
    [5] 修改节点

  【服务控制】
    [6] 重启服务          [7] 停止服务

  【进阶功能】
    [8] 中转管理          [9] WARP 管理
    [10] IPv6 优化         [11] 流媒体 DNS

  【系统维护】
    [12] 安装/更新核心    [13] 卸载脚本

  ─────────────────────────────────────────────────
    [0] 退出脚本
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

子菜单: 创建 VLESS-WS/VMess-WS + Argo、查看/删除节点、重启隧道、查看日志、后台看门狗。

## 查看节点链接（菜单 3）

自动生成所有已启用协议的分享链接，保存到 `/etc/sing-box/uris.txt`。

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

```
安装后:
/etc/sing-box/
├── config.json          # 主配置
├── metadata.json        # 节点元数据（含 Reality public_key 等）
├── uris.txt             # 节点链接
├── certs/               # 自签证书
├── pf.json              # 端口转发规则
├── relay.json           # 中转路由元数据
├── argo_metadata.json   # Argo 隧道元数据
├── warp-meta.json       # WARP 域名分流元数据
└── .server_info         # VPS 状态面板缓存（60分钟有效）

运行时:
/tmp/singbox_argo_*.pid   # Argo 隧道进程 PID
/tmp/singbox_argo_*.log   # Argo 隧道日志

crontab:
* * * * * /usr/local/bin/sb keepalive   # Argo 看门狗
```

## 系统要求

- OS: Debian 11+ / Ubuntu 20+ / CentOS 7+ / Alpine / Fedora
- 架构: x86_64 / aarch64
- 权限: root

## 国内加速

```bash
export GH_MIRROR="https://ghproxy.com/"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```

## 注意事项

- VLESS Reality outbound 自动配置 `utls: chrome` 指纹（sing-box 要求）
- 中转 Token 生成时自动读取落地机 metadata.json 获取 `public_key`
- VMess WebSocket 使用自签证书加密，客户端需跳过证书验证
- AnyTLS / Hysteria2 / TUIC 使用自签证书，URI 已含 `insecure=1`
- WARP 域名分流通过 DNS 规则确保 AI 域名走 WARP 通道解析
