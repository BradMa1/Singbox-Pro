#!/usr/bin/env python3
"""把 Singbox-Pro 导出的节点 URI 合并成一份 Clash Meta (Mihomo) 订阅 YAML。

零第三方依赖，只用 Python 标准库。节点 URI 从两台 VPS 的菜单 [3] 现场导出，
此脚本负责「合并 + 转成 Clash 格式」，不碰服务端配置。

用法:
    python3 gen_clash_sub.py -i hk.txt -i us.txt -o sub/clash.yaml
    python3 gen_clash_sub.py -i nodes.txt              # 只打印到屏幕，不写文件

输入文件可以是（也支持混着粘）:
    1. 明文 URI 列表，每行一个（# 开头为注释，空行忽略）
    2. Singbox-Pro 菜单 [3] 打印的那一整串 base64「订阅链接」
    3. data:text/yaml;base64,... 会被跳过（那是已经转好的 YAML，不重复转换）

注意: 订阅 YAML 内含 UUID / 密码 / Reality 公钥等凭据明文，
      别提交进 git，别发群里，托管时用随机长路径。
"""
import argparse
import base64
import json
import os
import re
import sys
from collections import Counter
from urllib.parse import urlsplit, parse_qs, unquote

SUPPORTED = ('vless', 'anytls', 'tuic', 'hysteria2', 'hy2',
             'trojan', 'ss', 'vmess', 'socks5')


def b64pad(s):
    return s + '=' * (-len(s) % 4)


def load_uris(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        raw = f.read()
    uris = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '://' in line and not line.startswith('data:'):
            uris.append(line)
            continue
        if line.startswith('data:'):
            continue  # 已经转好的 YAML/JSON 订阅，跳过
        try:
            decoded = base64.b64decode(b64pad(line)).decode('utf-8', 'replace')
            uris.extend(x.strip() for x in decoded.splitlines()
                        if '://' in x and not x.strip().startswith('#'))
        except Exception:
            print(f'  [跳过] 无法识别的行: {line[:40]}...', file=sys.stderr)
    return uris


def split_authority(uri):
    """拆出 userinfo / host / port，正确处理 [IPv6]:port。"""
    netloc = urlsplit(uri).netloc
    userinfo, sep, hostport = netloc.rpartition('@')
    if not sep:
        userinfo, hostport = '', netloc
    if hostport.startswith('['):
        m = re.match(r'\[([^\]]+)\](?::(\d+))?', hostport)
        if not m:
            raise ValueError(f'无法解析 IPv6 地址: {hostport}')
        return userinfo, m.group(1), int(m.group(2) or 0)
    host, sep, port = hostport.rpartition(':')
    if not sep or not port.isdigit():
        return userinfo, hostport, 0
    return userinfo, host, int(port)


def ystr(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'


def scalar(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    if v is None:
        return '""'
    return ystr(v)


def is_insecure(q, *keys):
    """自签证书节点统一跳过校验（与 singbox-pro 生成的 YAML 保持一致）。"""
    for k in keys:
        v = q.get(k, [''])[0].lower()
        if v in ('1', 'true', 'yes'):
            return True
    # 没有明确写 insecure 参数 = 服务端用了真实证书
    return False


def alpn_list(q, default):
    raw = q.get('alpn', [''])[0]
    if not raw:
        return default
    return [x for x in re.split(r'[,;]', raw) if x]


def to_proxy(uri, used_names):
    u = urlsplit(uri)
    scheme = u.scheme.lower()
    if scheme not in SUPPORTED:
        return None, f'不支持的协议 {scheme}'
    q = parse_qs(u.query, keep_blank_values=True)

    def qv(k, default=''):
        return q.get(k, [default])[0]

    userinfo, host, port = split_authority(uri)
    name = unquote(u.fragment).strip()

    if scheme == 'vmess':
        # 标准 vmess:// 是 base64(JSON)，名字在 ps 字段里
        try:
            cfg = json.loads(base64.b64decode(b64pad(u.netloc)).decode('utf-8'))
        except Exception as e:
            return None, f'vmess 链接解码失败: {e}'
        host = cfg.get('add', host)
        port = int(cfg.get('port', port))
        name = name or cfg.get('ps', '')
        p = {
            'name': name, 'type': 'vmess', 'server': host, 'port': port,
            'uuid': cfg.get('id', ''), 'alterId': int(cfg.get('aid', 0)),
            'cipher': cfg.get('scy', 'auto'), 'network': cfg.get('net', 'ws'),
            'tls': cfg.get('tls', '') == 'tls', 'udp': True,
            'ws-opts': {'path': cfg.get('path', '/ws')},
            'servername': cfg.get('sni', ''), 'skip-cert-verify': True,
        }
    elif scheme == 'vless':
        if qv('security') == 'reality':
            p = {
                'name': name, 'type': 'vless', 'server': host, 'port': port,
                'uuid': unquote(userinfo), 'network': 'tcp', 'tls': True,
                'udp': True, 'flow': qv('flow', 'xtls-rprx-vision'),
                'client-fingerprint': qv('fp', 'chrome'),
                'servername': qv('sni', host),
                'reality-opts': {'public-key': qv('pbk'),
                                 'short-id': qv('sid')},
            }
        else:
            p = {
                'name': name, 'type': 'vless', 'server': host, 'port': port,
                'uuid': unquote(userinfo), 'network': 'ws', 'tls': True,
                'udp': True, 'client-fingerprint': qv('fp', 'chrome'),
                'servername': qv('sni', host),
                'ws-opts': {'path': qv('path', qv('ws_path', '/ws'))},
                'skip-cert-verify': is_insecure(q, 'insecure', 'allowInsecure'),
            }
    elif scheme == 'anytls':
        p = {
            'name': name, 'type': 'anytls', 'server': host, 'port': port,
            'password': unquote(userinfo), 'client-fingerprint': 'chrome',
            'tls': True, 'udp': True,
            'skip-cert-verify': is_insecure(q, 'insecure', 'allowInsecure'),
        }
    elif scheme == 'tuic':
        parts = unquote(userinfo).split(':', 1)
        if len(parts) != 2:
            return None, 'tuic 链接缺 uuid:password'
        p = {
            'name': name, 'type': 'tuic', 'server': host, 'port': port,
            'uuid': parts[0], 'password': parts[1],
            'ip': host, 'sni': qv('sni', host),
            'alpn': alpn_list(q, ['h3']),
            'congestion-controller': qv('congestion_control', 'bbr'),
            'udp-relay-mode': qv('udp_relay_mode', 'native'),
            'disable-sni': False, 'reduce-rtt': True, 'udp': True,
            'skip-cert-verify': is_insecure(q, 'allow_insecure',
                                            'insecure', 'allowInsecure'),
        }
    elif scheme in ('hysteria2', 'hy2'):
        p = {
            'name': name, 'type': 'hysteria2', 'server': host, 'port': port,
            'password': unquote(userinfo), 'sni': qv('sni', host),
            'alpn': alpn_list(q, ['h3']), 'udp': True,
            'skip-cert-verify': is_insecure(q, 'insecure', 'allowInsecure'),
        }
    elif scheme == 'trojan':
        p = {
            'name': name, 'type': 'trojan', 'server': host, 'port': port,
            'password': unquote(userinfo), 'sni': qv('sni', host),
            'alpn': alpn_list(q, ['h2', 'http/1.1']),
            'client-fingerprint': 'chrome', 'udp': True,
            'skip-cert-verify': is_insecure(q, 'allowInsecure',
                                            'insecure', 'allow_insecure'),
        }
    elif scheme == 'ss':
        try:
            plain = base64.b64decode(b64pad(unquote(userinfo))).decode('utf-8')
        except Exception:
            plain = unquote(userinfo)  # 老式明文 method:password
        if ':' not in plain:
            return None, 'ss 链接缺 method:password'
        method, psk = plain.split(':', 1)
        p = {
            'name': name, 'type': 'ss', 'server': host, 'port': port,
            'cipher': method, 'password': psk, 'udp': True,
        }
    else:  # socks5
        parts = unquote(userinfo).split(':', 1)
        p = {
            'name': name, 'type': 'socks5', 'server': host, 'port': port,
            'username': parts[0], 'password': parts[1] if len(parts) > 1 else '',
            'udp': True,
        }

    if not name:
        name = f'{scheme}-{host}-{port}'
        p['name'] = name
    # 两台机器可能有同名节点，Clash 里重名会互相覆盖
    if name in used_names:
        n = 2
        while f'{name} #{n}' in used_names:
            n += 1
        name = f'{name} #{n}'
        p['name'] = name
    used_names.add(name)
    return p, None


def render_proxy(p):
    lines = []
    first = True
    for k, v in p.items():
        prefix = '  - ' if first else '    '
        first = False
        if isinstance(v, dict):
            lines.append(f'{prefix}{k}:')
            for kk, vv in v.items():
                lines.append(f'      {kk}: {scalar(vv)}')
        elif isinstance(v, list):
            lines.append(f'{prefix}{k}:')
            for item in v:
                lines.append(f'      - {scalar(item)}')
        else:
            lines.append(f'{prefix}{k}: {scalar(v)}')
    return lines


def build_yaml(proxies):
    names = [p['name'] for p in proxies]
    out = ['# 由 gen_clash_sub.py 生成 — 供 Mihomo / Clash.Meta / OpenClash(Meta 内核) 使用',
           '# 内含节点凭据明文，请勿公开或提交 git', 'proxies:']
    for p in proxies:
        out.extend(render_proxy(p))
    out += [
        'proxy-groups:',
        '  - name: "🚀 节点选择"',
        '    type: select',
        '    proxies:',
        '      - "♻️ 自动选择"',
    ]
    out += [f'      - {ystr(n)}' for n in names]
    out += [
        '  - name: "♻️ 自动选择"',
        '    type: url-test',
        '    url: https://www.gstatic.com/generate_204',
        '    interval: 300',
        '    tolerance: 50',
        '    proxies:',
    ]
    out += [f'      - {ystr(n)}' for n in names]
    out += [
        'rules:',
        '  - GEOIP,CN,DIRECT',
        '  - GEOSITE,CN,DIRECT',
        '  - MATCH,"🚀 节点选择"',
        '',
    ]
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser(
        description='合并两台 VPS 的节点 URI，生成 Clash Meta 订阅 YAML')
    ap.add_argument('-i', '--input', action='append', required=True,
                    help='URI 文件，可重复指定（例如 -i hk.txt -i us.txt）')
    ap.add_argument('-o', '--output', help='输出 YAML 路径；不填则打印到屏幕')
    args = ap.parse_args()

    uris = []
    for path in args.input:
        if not os.path.isfile(path):
            print(f'[错误] 找不到输入文件: {path}', file=sys.stderr)
            sys.exit(1)
        found = load_uris(path)
        print(f'  读取 {path}: {len(found)} 条 URI', file=sys.stderr)
        uris.extend(found)

    proxies, used, errors = [], set(), []
    for uri in uris:
        p, err = to_proxy(uri, used)
        if err:
            errors.append(err)
        else:
            proxies.append(p)

    for e in errors:
        print(f'  [警告] {e}', file=sys.stderr)
    if not proxies:
        print('[错误] 没解析出任何节点，检查输入文件内容', file=sys.stderr)
        sys.exit(1)

    yaml_text = build_yaml(proxies)
    if args.output:
        out = os.path.abspath(args.output)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'w', encoding='utf-8') as f:
            f.write(yaml_text)
        os.chmod(out, 0o600)
        print(f'  已写出: {out}（权限 600）', file=sys.stderr)
    else:
        print(yaml_text, end='')

    print('\n  节点统计:', file=sys.stderr)
    for k, v in Counter(p['type'] for p in proxies).most_common():
        print(f'    {k}: {v}', file=sys.stderr)
    print('  按服务器:', file=sys.stderr)
    for k, v in Counter(p['server'] for p in proxies).most_common():
        print(f'    {k}: {v}', file=sys.stderr)


if __name__ == '__main__':
    main()
