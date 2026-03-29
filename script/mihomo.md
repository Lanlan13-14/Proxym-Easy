安装mihomo
```bash
wget -O install.sh https://raw.githubusercontent.com/Lanlan13-14/Proxym-Easy/refs/heads/main/script/install_mihomo.sh && chmod +x install.sh && ./install.sh
```
mihomo配置位于
```
/root/mihomo
```
极简版yaml
```yaml
# 机场节点
proxies:
- name: "代理"
  type: socks5
  server: server
  port: 443
  # username: username
  # password: password
  # tls: true
  # fingerprint: xxxx
  # skip-cert-verify: true
  # udp: true
  # ip-version: ipv6

# 全局设置
allow-lan: false
ipv6: true
mixed-port: 7890
tproxy-port: 7891
external-controller: 127.0.0.1:9090
tun:
  enable: true
  stack: mixed
  mtu: 9000
  dns-hijack:
     - "any:53"
     - "tcp://any:53"
  auto-route: true
  auto-redirect: true

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  force-domain:
    - "*.v2ex.com"
  skip-domain:
    - "Mijia Cloud"
    - "dlg.io.mi.com"
    - "*.push.apple.com"
    - "*.apple.com"
    - "*.wechat.com"
    - "*.qpic.cn"
    - "*.qq.com"
    - "*.wechatapp.com"
    - "*.vivox.com"
    # 向日葵服务
    - "*.oray.com"
    - "*.sunlogin.net"
    
dns:
  enable: true
  ipv6: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 28.0.0.1/8
  fake-ip-range6: 2001:480:abcd::1/64
  default-nameserver:
    - 119.29.29.29
    - 180.184.1.1
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - https://223.5.5.5/dns-query#h3=true
  direct-nameserver:
    - https://doh.pub/dns-query
    - https://223.5.5.5/dns-query#h3=true
  nameserver:
    - https://dns.google/dns-query
    - https://dns.cloudflare.com/dns-query

# 代理组（只有一个默认组）
proxy-groups:
  - name: 默认
    type: select
    proxies: [代理]

# 规则：全部流量走默认代理
rules:
  - MATCH,默认
```