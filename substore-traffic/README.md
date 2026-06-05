# SubStore Traffic

通过统计 VPS 网卡流量，给 Sub-Store 提供 `subscription-userinfo`。

支持：

- 一键安装 / 一键卸载。
- SSH 终端配置面板。
- 自定义监听端口。
- 选择统计方式：仅出站、仅入站、双向。
- 手动设置套餐总流量 `total`。
- 手动设置当前已用流量 `download`。
- 手动输入到期时间 `expire`，使用 Unix 时间戳。
- 设置自动重置时间 `reset_at`，使用 Unix 时间戳。
- 续费后自动重置流量：`expire` 变大时自动清零。
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
2. 选择统计方式：仅出站 / 入站 / 双向
3. 设置套餐流量 / 到期时间 / 重置时间
4. 手动清零当前周期流量
5. 安装或更新 systemd 服务
6. 重启服务
7. 查看配置 JSON
0. 退出
```

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
  "traffic_mode": "outbound",
  "quota_bytes": 1099511627776,
  "manual_used_bytes": null,
  "upload_bytes": 0,
  "expire": 4115721600,
  "reset_at": 0,
  "plan_name": "VIP1",
  "app_url": "http://a.com",
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
| `traffic_mode` | `outbound` / `inbound` / `both` |
| `quota_bytes` | 套餐总流量，Sub-Store 的 `total` |
| `manual_used_bytes` | 手动指定已用流量，Sub-Store 的 `download` 起始值 |
| `upload_bytes` | Sub-Store 的 `upload`，通常填 0 |
| `expire` | 到期 Unix 时间戳，用户手动输入 |
| `reset_at` | 自动重置 Unix 时间戳，0 表示不按固定时间重置 |
| `plan_name` | 套餐名称 |
| `app_url` | Sub-Store 可点击跳转链接 |
| `auto_reset_on_renewal` | `expire` 变大时是否自动清零 |

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