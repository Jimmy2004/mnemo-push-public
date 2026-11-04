# mnemo-push

把手机上「极米记得」(mnemosyne-memory-gateway) 的数据增量同步到自己的 VPS，手机离线时也能查询。

```
手机 Termux: mnemo_push.py
  ├─ HMAC 签名请求 127.0.0.1:8723/v1/*（与官方 bridge v10 相同，并校验响应签名）
  ├─ 写入本地队列 ~/mnemo-queue
  └─ HTTPS 推送（经代理 → Cloudflare → nginx）
VPS: mnemo_recv.py（127.0.0.1:20953，systemd 沙箱）
  └─ 校验推送签名 + 时间戳 + 防重放 → SQLite 按 (sourceType,id) 去重
```

## 安全设计
- 通行证 secret **只存在于手机**，从不发往 VPS 或网络。
- 推送使用独立的 `PUSH_KEY`：`HMAC-SHA256(key, ts + "\n" + sha256hex(body))`，时间偏差 ≤ 300s，签名只接受一次。
- 鉴权失败返回 404，与不存在的路径不可区分；源站只接受 Cloudflare IP。
- 本仓库不包含任何密钥、域名、IP 或随机路径。

## 部署
**VPS**：复制 `server/` 到 VPS，运行 `sh deploy/install.sh`，再按 `deploy/nginx-location.conf` 配置 nginx。

**手机（Termux，F-Droid 版）**
```sh
pkg install python cronie termux-services
cp phone/mnemo_push.py ~/
cp phone/mnemo-push.env.example ~/.mnemo-push.env && chmod 600 ~/.mnemo-push.env   # 填入实际值
python ~/mnemo_push.py --days 1          # 首次测试
crontab phone/crontab.txt                 # 每 10 分钟
```
开机自启：安装 Termux:Boot，把 `phone/termux-boot-start.sh` 放到 `~/.termux/boot/start.sh`。

## 排错
| 现象 | 原因 |
|---|---|
| 响应签名校验失败 | `MNEMOSYNE_AGENT` 与通行证不符或 token 有误 |
| 推送 403 + Cloudflare 1010 | User-Agent 被 Browser Integrity Check 拦截（脚本已设置 `mnemo-push/1.0`） |
| 推送 404 | 签名/时间戳错误，或 PUSH_URL 路径不对 |
| 推送 409 | 重放，被拒绝 |
