# mnemo-push

<img src="android/icon-preview.svg" width="96" align="right" alt="Mnemo Push 图标">

把手机上「极米记得」(mnemosyne-memory-gateway) 的记忆、记录、代办等数据，增量同步到自己的 VPS，再让电脑上的 AI 助手通过 MCP 从 VPS 读取 —— **手机关机、不在同一局域网时也能查询自己的记忆**。

## 隐私提醒
开发者本人没有埋任何指向GitHub以外的网站代码，也不收集你的数据。但你需要对于自己的数据安全负全责，在AI时代，什么都有可能被破解，**放公网=裸奔**，使用本项目，默认你愿意将自己的一切信息开源。

## 设备需求
极米记得手环或眼镜

安卓手机、对应极米记得App

一台有公网IP的Linux主机，可以是VPS，云服务器，软路由，NAS，甚至旧手机（发挥想象力），并且手机和你安装MCP的电脑都能连上它

## 说人话步骤讲解
本项目几乎完全由Claude Opus 5.5打造，消耗50M token，感谢A畜。
目前仅支持安卓手机，测试环境安卓17，OPPO PKH 110。**iOS用户可以自己写，我的服务端好歹也能帮你省一半token。** 需要一台有公网IP的7*24h的Linux主机，用于接收。
本项目有关AI Agent，所以我相信你已经有一个好使的Agent了。如果你不喜欢自己动手，可以直接跳到下方安装提示词的部分，将提示词 A 和提示词 B 分别交给你的智能体，它会帮你完成VPS端的配置。你作为人类只需要：
1. 下载安卓app（apk）
2. 获取极米记得中的通行证，复制通行证中的提示词
3. 打开安卓app，粘贴提示词。将VPS推送部分的push url和push key填入（也可以直接从agent粘贴）
4. 设置自动同步时间，首次拉取天数设为0，保存，顶部立即同步。
5. 按需设置后台保活。
6. 结束了，接下来把MCP接入工作流吧～

我自己写的部分到此结束，以下都是AI写的：

## 工作原理

```
┌─ Android 手机 ───────────────────────────────────────────┐
│ 极米记得 App ── 本机 gateway 127.0.0.1:8723（只读，HMAC）    │
│        ▲ ① 签名请求 /v1/*，并校验响应签名                   │
│ Mnemo Push App（或 Termux 脚本）                           │
│        │ ② 写入本地队列（离线积累，恢复后补推）               │
└────────┼─────────────────────────────────────────────────┘
         │ ③ HTTPS 推送（PUSH_KEY 签名）：手机代理 → Cloudflare → nginx
         ▼
┌─ VPS ────────────────────────────────────────────────────┐
│ mnemo_recv.py（127.0.0.1:20953，systemd 沙箱）            │
│   写：校验 PUSH_KEY + 时间戳 + 防重放 → SQLite 去重入库   │
│   读：校验 READ_KEY → 只读查询，响应签名                  │
└────────▲─────────────────────────────────────────────────┘
         │ ④ HTTPS 查询（READ_KEY 签名，校验响应签名）
┌─ 电脑 ──┴────────────────────────────────────────────────┐
│ mnemosyne-cloud MCP（Node，零依赖）→ Claude / 其它助手    │
└──────────────────────────────────────────────────────────┘
```

同步内容：转录（按 `sinceId` 增量）、会议、记忆、时间线卡片、待办（按最近 N 天窗口；首次拉取天数填 0 = 全部历史）。服务端按 `(device, sourceType, id)` 去重：换推送/只读密钥或通行证都不会产生重复；多台设备推到同一台 VPS 时，在 App 里填不同的「设备标识」即可互不覆盖（留空 = 不标识）。

## 目录结构

| 路径 | 说明 |
|---|---|
| `android/` | **Mnemo Push** 安卓 App（Kotlin / Material 3）：粘贴即配置、Keystore 加密密钥、WorkManager 定时推送、开机自启开关、保活指引 |
| `server/` | VPS 服务 `mnemo_recv.py`（写入 + 只读查询）、一键安装 `install.sh`、本机一键部署 `deploy.sh` |
| `mcp/` | 电脑端只读 MCP `index.mjs` 与安装脚本 `install.sh` |
| `phone/` | Termux 版脚本（App 的命令行替代方案） |

## 安全设计
- **三把互不通用的钥匙**：极米记得通行证（只在手机上）、`PUSH_KEY`（手机只能写）、`READ_KEY`（电脑只能读）。任何一把泄露都不影响另外两把。
- 通行证 secret 从不离开手机：请求在本地签名，并校验 gateway 的响应签名，防止 8723 端口被冒充。
- 写与读请求都使用 `HMAC-SHA256` 签名、时间偏差 ≤ 300 秒、同一签名只接受一次；只读查询的响应也带签名，MCP 端校验后才使用。
- 鉴权失败统一返回 404，与不存在的路径不可区分；源站只接受 Cloudflare IP；服务只监听 `127.0.0.1`，以无登录权限的专用用户在 systemd 沙箱中运行。
- App 内密钥用 Android Keystore（AES-GCM）加密；导入后清空剪贴板；明文 HTTP 只允许访问 `127.0.0.1`。电脑端密钥文件权限 600，不写入 MCP 配置明文。
- 本仓库不包含任何密钥、域名、IP 或随机路径。
- **AI配套的人类来补一句：其实这些安全设计屁用没有，真在意隐私就别用，用就默认把自己给开源了。2026年11月了，AI的网络攻防大家有目共睹**

---

## 快速开始

### 1. VPS（一条命令）

前提：VPS 上已有 nginx 和一个 HTTPS 站点（建议套 Cloudflare），root 权限，Python 3.8+。

```sh
git clone https://github.com/<you>/mnemo-push && cd mnemo-push
./server/deploy.sh root@<VPS-IP> --domain <你的域名> [-i ~/.ssh/key.pem]
```

脚本会：创建专用用户 → 生成 `PUSH_KEY` / `READ_KEY` / 随机路径 → 安装 systemd 服务 → 本机自检（写入 + 只读查询 + 签名）→ 在 `server_name` 为该域名的 nginx 站点中插入路径（先备份，`nginx -t` 失败自动回滚）。可重复运行，已有密钥与配置会保留。

结束时输出两段内容：**① 给手机的两行**、**② 给电脑的一条命令**。

其它操作（在 VPS 的 `server/` 目录内）：

| 命令 | 作用 |
|---|---|
| `sh install.sh --show` | 重新显示手机配置与电脑命令 |
| `sh install.sh --rotate-key` | 更换推送密钥（手机需重新粘贴） |
| `sh install.sh --rotate-read-key` | 更换只读密钥（电脑需重新安装 MCP） |
| `sh install.sh --no-nginx` | 只装服务，nginx 自行配置 |
| `sh install.sh --uninstall [--purge]` | 卸载（`--purge` 同时删除数据与密钥） |

### 2. 手机：Mnemo Push App

1. 安装 APK（`cd android && ./gradlew :app:assembleDebug`，产物 `app/build/outputs/apk/debug/app-debug.apk`）。
2. **① 本机**：在极米记得里复制整段安装提示词 → 点「粘贴安装提示词」→「测试连接」。
3. **② 云端**：复制 VPS 输出的 `PUSH_URL` / `PUSH_KEY` 两行 → 点「粘贴推送配置」→「测试连接」（显示延迟毫秒）。多台设备时填写「设备标识」。
4. **③ 后台**：打开「定时自动同步」，输入间隔并选择分钟/小时（15 分钟 – 24 小时）；按需打开「开机后自动恢复同步」；依次完成「忽略电池优化」「允许自启动」「在最近任务中上锁」。
5. 点「保存」，再点「立即同步」，在「最近日志」看到“同步成功”即可。

### 3. 电脑：mnemosyne-cloud MCP

运行 VPS 输出的那条命令（Node.js 18+）：

```sh
sh mcp/install.sh --url 'https://<域名>/<随机路径>' --read-key '<64 位只读密钥>'
```

脚本把 MCP 安装到 `~/.mnemosyne/cloud/`（密钥文件 600），自检连通与响应签名后注册到 Claude Code（用户级）。重启 Claude 生效。其它客户端按脚本提示手动添加 `node ~/.mnemosyne/cloud/index.mjs`。

提供的工具：

| 工具 | 说明 |
|---|---|
| `sync_status` | 各类数据条数、最新时间、最近接收时间（判断新鲜度） |
| `available_days` | 哪些天有数据（`offset` = 往前偏移天数） |
| `search_evidence` | 搜索会议 / 记忆 / 卡片 / 待办，`includeTranscripts` 含转录 |
| `get_transcripts` | 按时间窗口读原话，支持 `query`、`sinceId`、分页 |
| `get_memory_item` | 按 `sourceType + id` 读单条 |
| `get_open_loops` | 未完成待办 |

所有工具都接受可选的 `device` 参数筛选设备（未标识的数据为空字符串），不传则查全部。

自检：`sh mcp/install.sh --check`；卸载：`sh mcp/install.sh --uninstall`。

---

## 安装提示词（交给 AI 助手执行）

可把下面的提示词直接发给 Claude Code 等能执行命令的助手，替换尖括号里的内容即可。**提示词里不要放任何密钥**：密钥由脚本在 VPS 与本机之间直接传递，或只显示在你自己的终端里。

### 提示词 A：部署 VPS 服务端

```text
请帮我部署 mnemo-push 的 VPS 服务端。
- 仓库：<仓库地址或本地路径>（server/ 目录）
- VPS：root@<VPS-IP>，SSH 私钥 <私钥路径>
- 域名：<已在 nginx 中配置 HTTPS 的域名>（建议经 Cloudflare）

要求：
1. 先只读检查 VPS：系统、python3 版本、nginx 是否存在、哪个配置文件里有 server_name <域名>、127.0.0.1:20953 是否被占用。把结论告诉我再继续。
2. 在本机仓库根目录运行：./server/deploy.sh root@<VPS-IP> -i <私钥路径> --domain <域名>
   脚本会自动备份 nginx 配置并在 nginx -t 失败时回滚，不要手动改 nginx，也不要修改代理（如 S-UI / Xray / sing-box）相关配置。
3. 脚本最后会输出 PUSH_URL / PUSH_KEY 和一条 mcp/install.sh 命令。不要把 PUSH_KEY 和 read-key 原文显示在对话里，用 <hidden> 代替；告诉我在 VPS 上运行 `cd /root/mnemo-push-server && sh install.sh --show` 自己查看。
4. 用一条正确签名的测试请求验证 https://<域名>/<路径> 可从公网访问（错误签名应返回 404），测试数据验证后删除。
5. 汇报：服务状态、nginx 备份文件路径、自检结果。
```

### 提示词 B：在本机配置 MCP（从 VPS 读取）

```text
请在这台电脑上为我配置 mnemo-push 的只读 MCP「mnemosyne-cloud」，让 AI 从我的 VPS 读取极米记得数据。
- 仓库：<仓库地址或本地路径>（mcp/ 目录）
- VPS：root@<VPS-IP>，SSH 私钥 <私钥路径>（服务端已用 server/install.sh 部署）

要求：
1. 检查本机 Node.js ≥ 18。
2. 通过 SSH 读取 VPS 上的 /etc/mnemo-recv/path、/etc/mnemo-recv/domain、/etc/mnemo-recv/read.key，
   直接存进 shell 变量并传给：sh mcp/install.sh --url "https://<domain>/<path>" --read-key "$KEY"
   全程不要把 read.key 的内容打印到对话或写进任何文件（脚本会自行写入 ~/.mnemosyne/cloud/read.key，权限 600）。
3. 脚本会自检并注册到 Claude Code（claude mcp add -s user）。确认 `claude mcp list` 中 mnemosyne-cloud 为 Connected。
4. 通过 MCP 协议实测 sync_status、available_days、search_evidence 三个工具能返回数据，只汇报条数和日期，不要展示记忆原文。
5. 提醒我重启 Claude；若原来的局域网 MCP（mnemosyne-memory）仍在，询问我是否保留。
```

### 提示词 C：从极米记得安装提示词配置手机（无需 AI）

手机端不需要 AI：在 Mnemo Push 中点「粘贴安装提示词」即可，App 只从文本中提取 `MNEMOSYNE_TOKEN`、agent 和网关端口，**不会执行**其中的脚本。

---

## Termux 脚本（和apk互为替代关系，如果你是极简主义者，可以使用termux脚本）

```sh
pkg install python cronie termux-services
cp phone/mnemo_push.py ~/
cp phone/mnemo-push.env.example ~/.mnemo-push.env && chmod 600 ~/.mnemo-push.env   # 填入实际值
python ~/mnemo_push.py --days 1
crontab phone/crontab.txt
```

## 排错

| 现象 | 原因 |
|---|---|
| App「测试连接」签名校验失败 | agent 与通行证不符，或通行证有误 |
| 网关 HTTP 401 / 403 | 通行证被吊销，或未开启 full transcripts |
| 推送 403 + Cloudflare 1010 | User-Agent 被 Browser Integrity Check 拦截（已设置 `mnemo-push/1.0`） |
| 推送 / 查询 404 | 签名错误、设备时间偏差超过 5 分钟，或 URL 路径不对 |
| 推送 / 查询 409 | 重放请求，被拒绝 |
| MCP 响应签名校验失败 | 服务端未更新到支持只读查询的版本，或中间被篡改：重新运行 `deploy.sh` |
| 自动同步不运行 | 系统杀后台：完成 App「后台」卡片中的三步 |
| 重启后不同步 | 关闭了「开机后自动恢复同步」：打开一次 App 即恢复 |
