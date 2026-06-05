# SubStore Traffic

通过统计 VPS 网卡流量，给 Sub-Store 提供 `subscription-userinfo`。

## 支持功能

- 一键安装 / 一键卸载。
- SSH 终端配置面板。
- 自定义监听端口。
- 选择统计方式：
  - 仅出站：`tx_bytes`
  - 仅入站：`rx_bytes`
  - 双向：`rx_bytes + tx_bytes`
  - 出入取大：`max(rx_delta, tx_delta)`，按入站和出站本周期增量较大的那个计费
- 手动设置套餐总流量 `total`。
- 手动设置当前已用流量 `download`。
- 手动设置 `upload`。
- 续费周期：月付 / 季付 / 年付。
- 用户手动输入计费开始时间 Unix 时间戳。
- 用户手动输入初次设置时已经开通了几个计费周期。
- 开启自动续订后，到期会按设置的周期自动往后延长，并清零当前周期流量。
- 支持额外设置 `reset_at` Unix 时间戳，到点自动清零。
- 流量单位输入支持 `10KB`、`500MB`、`1GB`、`1TB`。

换算按 1024 进率：

```text
1KB = 1024B
10KB = 10240B
1MB = 1024KB
1GB = 1024MB
1TB = 1024GB
```

## 一键安装

```bash
git clone https://github.com/Lanlan13-14/Proxym-Easy.git
cd Proxym-Easy/substore-traffic
sudo sh install.sh
```

安装完成后打开 SSH 面板：

```bash
sudo vps-substore-panel
```

## 一键卸载

```bash
cd Proxym-Easy/substore-traffic
sudo sh uninstall.sh
```

卸载时会询问是否删除配置和流量状态。

## SSH 面板功能

```text
1. 修改监听端口 / 监听地址 / 网卡
2. 选择统计方式：仅出站 / 入站 / 双向 / 出入取大
3. 设置套餐流量 / 手动已用流量 / plan_name
4. 设置续费周期 / 开始时间 / 初始周期数 / 自动续订
5. 手动清零当前周期流量
6. 安装或更新 systemd 服务
7. 重启服务
8. 查看配置 JSON
0. 退出
```

## 续费逻辑

新版续费不是靠用户手动修改到期时间判断，而是按真实计费周期计算。

用户需要设置：

| 字段 | 说明 |
|---|---|
| `billing_start` | 计费开始时间，Unix 时间戳，用户手动输入 |
| `billing_cycle` | 计费周期：`month` / `quarter` / `year` |
| `billing_periods` | 初次设置时已经开通了几个计费周期 |
| `auto_renew` | 是否自动续订 |

计算方式：

```text
expire = billing_start + billing_periods × billing_cycle
```

周期换算：

```text
month   = 1 个月
quarter = 3 个月
year    = 12 个月
```

例如：

```text
billing_start = 2026-01-01 00:00:00 的 Unix 时间戳
billing_cycle = month
billing_periods = 2
```

则：

```text
expire = 2026-03-01 00:00:00
```

如果开启：

```json
"auto_renew": true
```

到了 `expire` 后，服务下一次被访问或重启时会：

1. `billing_periods` 自动 +1。
2. `expire` 按计费周期往后延伸。
3. 当前周期流量自动清零。

如果是季付：

```text
billing_cycle = quarter
```

每次自动续订会往后延长 3 个月。

如果是年付：

```text
billing_cycle = year
```

每次自动续订会往后延长 12 个月。

## Sub-Store 填写

如果监听端口是 `8899`：

```text
http://你的VPS_IP:8899/sub-userinfo
```

也支持：

```text
http://你的VPS_IP:8899/subscription-userinfo
```

服务同时支持 `GET` 和 `HEAD`，会在响应头和响应体里返回 `subscription-userinfo`。

输出示例：

```text
upload=0; download=10240; total=1099511627776; expire=4115721600; reset_day=14; plan_name=VIP1; app_url=http://a.com
```

## 配置文件

```text
/etc/vps-substore-traffic.json
```

示例：

```json
{
  "listen": "0.0.0.0",
  "port": 8899,
  "iface": "eth0",
  "traffic_mode": "max",
  "quota_bytes": 1099511627776,
  "manual_used_bytes": null,
  "upload_bytes": 0,
  "billing_start": 1767225600,
  "billing_cycle": "month",
  "billing_periods": 1,
  "expire": 1769904000,
  "reset_at": 0,
  "plan_name": "VIP1",
  "app_url": "http://a.com",
  "auto_renew": true,
  "auto_reset_on_renewal": true,
  "admin_token": "随机token",
  "state_file": "/var/lib/vps-substore-traffic/state.json"
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| `port` | HTTP 监听端口 |
| `iface` | 要统计的网卡 |
| `traffic_mode` | `outbound` / `inbound` / `both` / `max` |
| `quota_bytes` | 套餐总流量，Sub-Store 的 `total` |
| `manual_used_bytes` | 手动指定已用流量，Sub-Store 的 `download` 起始值 |
| `upload_bytes` | Sub-Store 的 `upload`，通常填 0 |
| `billing_start` | 计费开始 Unix 时间戳 |
| `billing_cycle` | 续费周期：`month` / `quarter` / `year` |
| `billing_periods` | 已开通周期数 |
| `expire` | 根据开始时间、周期、周期数计算出的到期 Unix 时间戳 |
| `reset_at` | 额外自动重置 Unix 时间戳，0 表示不用 |
| `plan_name` | 套餐名称 |
| `app_url` | Sub-Store 可点击跳转链接 |
| `auto_renew` | 到期后是否自动按周期续订并清零 |

## 测试

```bash
curl -i http://127.0.0.1:8899/sub-userinfo
curl http://127.0.0.1:8899/status
```

手动 API 清零：

```bash
curl 'http://127.0.0.1:8899/admin/reset?token=你的admin_token'
```

## 注意

这个方案统计的是 VPS 网卡流量，不是单独某一个代理用户的流量。如果 VPS 上还有网站、下载、备份、Docker 拉镜像等出入站流量，也会被一起计入。