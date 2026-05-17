# Sing-box Pro

多协议一键部署脚本，支持 5 种协议自由组合安装 + 全协议 Token 中转 + Argo 隧道 + 端口转发 + WARP 解锁。

## 支持协议

| 协议 | 特点 |
|:----|:----|
| VLESS Reality Vision | TCP 伪装，无需域名，最稳首选 |
| AnyTLS | 新一代伪装协议 |
| TUIC V5 | QUIC 协议，极致低延迟 |
| Hysteria2 | UDP 加速，弱网神器 |
| VMess WebSocket | WebSocket 传输，默认启用 TLS |

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```

## 安装流程

1. 选择要部署的协议（可多选，空格分隔）
2. 配置各协议端口（回车随机，也可手动输入）
3. 输入节点名称前缀（可选，回车使用默认名称）
4. 自动部署、启动服务并输出节点链接

## 管理面板

安装后直接输入 `sb` 进入管理面板，顶部显示 VPS 状态面板：

```
┌──────────────── VPS 状态 ────────────────┐
  系统: Debian GNU/Linux 11    内核: 6.12.63+deb13
  CPU:  amd64                  虚拟化: lxc
  BBR:  bbr
  IPv4: 151.244.134.189        IPv6: 无IPv6
  地区: JP Tokyo Tokyo
  sing-box: 运行中 ✅  v1.13.12
└──────────────────────────────────────────┘
 Argo: 2 节点  │  WARP: ✅  │  端口转发: 3 条

 1) 查看节点链接
 2) 重置端口
 3) 服务状态
 4) 重启服务
 5) 更新 sing-box
 6) 生成线路机脚本
 7) 查看运行日志
 8) Argo 隧道管理
 9) 端口转发
10) 管理 WARP 解锁
11) 卸载
 0) 退出
```

> **状态面板**：系统信息、网络 IP、服务器地区一目了然。IP 和地区信息缓存 60 分钟，菜单秒出不卡顿。sing-box 状态带颜色标识（绿色运行中/红色停止）。

## 查看节点链接（菜单 1）

自动读取当前配置，生成所有已启用协议的分享链接，同时保存到 `/etc/sing-box/uris.txt`。

| 支持协议 | 说明 |
|:---------|:-----|
| VLESS Reality | 含 XTLS Vision 流控 |
| AnyTLS | 自签证书，URI 含 `insecure=1` |
| TUIC V5 | QUIC 协议 |
| Hysteria2 | UDP 加速 |
| VMess WS | Base64 格式 |

## 重置端口（菜单 2）

单独修改某个协议的监听端口，支持手动输入或随机生成，自动重启服务并刷新节点链接。菜单编号根据已启用协议动态生成，避免错位。

## 更新 sing-box（菜单 5）

自动更新 sing-box 到最新版本，更新前**自动备份** `config.json` 到带时间戳的备份文件。优先走官方脚本/包管理器，失败时自动回退到 GitHub 直接下载（支持 `GH_MIRROR` 国内加速）。

## 生成线路机脚本 / 中转管理（菜单 6）

提供两套中转方案，可根据场景选择。

### 方案一：线路机安装脚本

在美西等落地机上生成独立安装脚本，传到中转机一键执行。中转机无需安装 sb。

**其中转链路：**
```
客户端 → 中转机(VLESS Reality) → 落地机(VLESS Reality) → 外网
```

### 方案二：Token 全协议中转

落地机生成 Token → 中转机导入，落地机上已有协议的**全部支持**。

| 落地协议 | 是否支持 |
|:---------|:--------|
| VLESS Reality | ✅ |
| TUIC V5 | ✅ |
| Hysteria2 | ✅ |
| AnyTLS | ✅ |
| Shadowsocks | ✅ |
| VMess WS | ✅ |

中转导入时入口协议可选 VLESS Reality / Hysteria2 / TUIC / AnyTLS。支持查看和删除中转路由。

> **注意**：选择 Hysteria2 / TUIC / AnyTLS 作为入口时，脚本会检查 TLS 证书路径（`/etc/sing-box/certs/`），如证书不存在会提示申请方法。

## Argo 隧道管理（菜单 8）

通过 Cloudflare Tunnel 将节点暴露到公网，无需独立 IP 或开放端口，支持**临时隧道**和**固定隧道**两种模式。

### 隧道模式

| 模式 | 说明 |
|:-----|:-----|
| 临时隧道 | 免费，随机 `*.trycloudflare.com` 域名，重启后域名变化 |
| 固定隧道 | 需要 Cloudflare Token + 自定义域名，重启后域名不变，更稳定 |

### 子菜单

| 选项 | 功能 |
|:-----|:-----|
| 1) 创建 VLESS-WS + Argo | 新建 VLESS WebSocket + Argo 隧道 |
| 2) 创建 Trojan-WS + Argo | 新建 Trojan WebSocket + Argo 隧道 |
| 3) 查看节点信息 | 显示状态、域名、分享链接 |
| 4) 删除节点 | 清理配置 + 元数据 + 停止隧道进程 |
| 5) 重启隧道 | 手动重启，临时隧道会获取新域名 |
| 6) 查看隧道日志 | `tail -20` 各端口隧道日志 |
| 7) 卸载 Argo | 清理所有隧道、crontab 看门狗 |

### 后台看门狗

启用 Argo 节点后自动开启，每分钟通过 crontab 检测隧道存活，失效自动重启。

## 端口转发（菜单 9）

基于 iptables DNAT 的内核级端口转发，支持 KVM 环境。

| 功能 | 说明 |
|:-----|:-----|
| 添加规则 | 指定本地端口、目标 IP/域名、目标端口、协议（TCP/UDP/双栈） |
| 查看规则 | 列出所有转发规则 |
| 删除规则 | 按端口删除，自动清理 iptables 规则 |

**重启不丢失**：添加规则时自动写入开机恢复脚本（systemd service 或 Alpine local.d），服务器重启后规则自动恢复。

适用于 NAT VPS 端口映射场景（如内部端口 84 → 外部 30004）。

## WARP 解锁（菜单 10）

一键安装 WARP SOCKS5 代理，自动配置 sing-box 分流规则，实现 AI 服务解锁。

| AI 服务 | 解锁状态 |
|:--------|:---------|
| Gemini (Google) | ✅ |
| OpenAI / ChatGPT | ✅ |
| Claude (Anthropic) | ✅ |
| Copilot (Microsoft) | ✅ |
| Perplexity | ✅ |
| 自定义域名 | ✅ 支持关键词/后缀匹配 |

- **安装**：自动安装 warp-go，添加 sing-box 分流 outbound 和路由规则
- **查看**：显示 WARP 状态、测试 AI 服务是否解锁
- **卸载**：自动清除分流规则和 WARP

## 卸载（菜单 11）

完整卸载 sing-box 及相关组件：

| 清理项 | 说明 |
|:--------|:-----|
| sing-box 服务 | 停止服务、禁用自启、删除 systemd/init.d 配置 |
| 配置文件 | 删除 `/etc/sing-box/` 全部内容 |
| Argo 隧道 | 停止所有隧道进程、清除 crontab 看门狗 |
| 端口转发 | 逐条删除 iptables DNAT 规则、清除元数据 |
| WARP | 保持独立（WARP 可单独卸载） |
| 管理命令 | 删除 `/usr/local/bin/sb` |

> 卸载前有确认提示，输入 `y` 确认后执行。

## 节点名称自定义

安装时可选输入节点名称前缀。例如输入 `my`，节点名称变为：
- `my-vless-reality`
- `my-hy2`
- `my-tuic-v5`

留空则使用默认名称（`vless-reality`、`hy2` 等）。

## 文件结构

```
安装后:
/etc/sing-box/
├── config.json          # 主配置
├── .config_cache        # 配置缓存
├── .protocols           # 协议标记
├── .reality_pub         # Reality 公钥
├── .reality_sid         # Reality ShortID
├── uris.txt             # 节点链接
├── certs/               # 自签证书
├── pf.json              # 端口转发规则
├── relay.json            # 中转路由元数据
├── argo_meta.json        # Argo 隧道元数据
└── .server_info          # VPS 状态面板缓存（60分钟有效）

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

## 国内加速（中国大陆用户）

如果你的服务器无法直接访问 GitHub，安装前设置镜像加速：

```bash
export GH_MIRROR="https://ghproxy.com/"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/BradMa1/Singbox-Pro/refs/heads/main/install.sh)"
```

常用镜像地址：
- `https://ghproxy.com/`
- `https://ghproxy.net/`
- `https://mirror.ghproxy.com/`

设置后脚本会自动通过镜像下载 sing-box。不设置也能跑，遇到 GitHub 访问问题时会有提示。

## 注意事项

- VMess WebSocket 直连模式默认启用 TLS，使用自签证书加密，客户端跳过证书验证
- AnyTLS / Hysteria2 / TUIC 使用自签证书，需要客户端允许不安全连接（URI 已包含 `insecure=1`）
- 所有自签证书在安装时自动生成，存放于 `/etc/sing-box/certs/`
- 配置缓存（`.config_cache`）中的节点名称前缀如果包含括号等特殊字符，脚本会自动加引号保护
