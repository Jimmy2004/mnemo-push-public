# mnemo-push

把手机上「极米记得」(mnemosyne-memory-gateway) 的数据增量同步到自己的 VPS，手机关机或离线时也能查询。

## 工作原理

```
Android 手机
  极米记得 App ── 本机 gateway 127.0.0.1:8723（只读，HMAC 签名鉴权）
        ▲
        │ ① 签名请求 /v1/*，并校验响应签名
  推送端（Mnemo Push App 或 Termux 脚本）
        │ ② 写入本地队列（离线时积累，恢复后补推）
        │ ③ HTTPS 推送：手机代理 → Cloudflare → nginx
        ▼
VPS: mnemo_recv.py（127.0.0.1:20953，systemd 沙箱）
        └─ 校验推送签名 + 时间戳 + 防重放 → SQLite，按 (sourceType, id) 去重
```

同步内容：转录（按 `sinceId` 增量）、会议、记忆、时间线卡片、待办（按最近 N 天窗口，服务端去重）。

## 目录结构

| 路径 | 说明 |
|---|---|
| `android/` | **Mnemo Push** 安卓 App（Kotlin，开发中）：图形化配置、加密保存密钥、WorkManager 定时推送 |
| `phone/` | Termux 版脚本：`mnemo_push.py`、`probe.sh`、配置模板、crontab、开机自启脚本 |
| `server/` | VPS 接收端 `mnemo_recv.py`，以及 `deploy/` 下的 systemd 服务、nginx 片段、安装脚本 |

## 安全设计
- 极米记得通行证（`tokenId.secret`）的 secret **只留在手机上**：请求在本地签名，secret 从不发往 VPS 或网络。
- 校验 gateway 的响应签名，防止 8723 端口被其它程序冒充。
- 推送使用独立的 `PUSH_KEY`：`HMAC-SHA256(key, ts + "\n" + sha256hex(body))`，时间偏差 ≤ 300 秒，同一签名只接受一次。
- 接收端鉴权失败返回 404，与不存在的路径不可区分；源站只接受 Cloudflare IP。
- App 内的通行证和 `PUSH_KEY` 用 Android Keystore（AES-GCM）加密保存；明文 HTTP 只允许访问 `127.0.0.1`。
- 本仓库不包含任何密钥、域名、IP 或随机路径。

## 部署

### 1. VPS 接收端
```sh
scp -r server/ root@<vps>:/root/mnemo-server && ssh root@<vps> 'cd /root/mnemo-server && sh deploy/install.sh'
```
再把 `server/deploy/nginx-location.conf` 加进 Cloudflare 域名的 server 块（随机路径见 VPS 上的 `/etc/mnemo-recv/path`），`nginx -t` 通过后 reload。

推送需要的两项配置：
- `PUSH_URL` = `https://<你的 CF 域名>/<随机路径>`
- `PUSH_KEY` = VPS 上 `/etc/mnemo-recv/key` 的内容

### 2a. 手机：Mnemo Push App（推荐，开发中）
安装 APK 后在界面里填写：
1. **网关**：极米记得通行证、agent（默认 `claude`），点「测试连接」
2. **推送**：`PUSH_URL`、`PUSH_KEY`
3. **自动同步**：打开开关，选择间隔（15/30/60 分钟），并「请求忽略电池优化」

构建：
```sh
cd android && ./gradlew :app:assembleDebug   # 需要 JDK 17+ 和 Android SDK 36
# 产物：android/app/build/outputs/apk/debug/app-debug.apk
```

### 2b. 手机：Termux 脚本
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
| 响应签名校验失败 | agent 与通行证不符，或通行证有误 |
| 网关 HTTP 401 / 403 | 通行证被吊销，或未开启 full transcripts |
| 推送 403 + Cloudflare 1010 | User-Agent 被 Browser Integrity Check 拦截（已设置 `mnemo-push/1.0`） |
| 推送 404 | 推送签名错误、手机时间不准，或 `PUSH_URL` 路径不对 |
| 推送 409 | 重放请求，被拒绝 |
| 自动同步不运行 | 系统杀后台：关闭电池优化、允许自启动 |
