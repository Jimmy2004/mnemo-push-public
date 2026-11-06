# Mac 本机联调

验证链路：极米记得协议网关 → 实际 `ios/MnemoCore` 拉取、游标与 NDJSON 队列 → 接收端。工具仅依赖 Python 3 标准库和 Swift 5.9+，macOS 13+。首次使用需安装 Xcode Command Line Tools。所有数据均为明显虚构的测试数据。

## 一键本机验证

在仓库根目录运行：

```bash
bash tools/run_local_e2e.sh
```

自动生成测试 token / push key，使用随机本机端口，启动假网关与现有 `server/mnemo_recv.py`。接收端环境 `MNEMO_ETC`、`MNEMO_DB`、`MNEMO_PORT` 均指向临时测试配置，监听 127.0.0.1。分别以空 device 和 `mac-e2e` 运行两轮同步，校验五类数据完整、分页、transcript 增量、device 隔离、签名重放拒绝及重复记录去重；SQLite 最终应有 764 条（每台设备 382 条）。失败退出码非零，输出 PASS/FAIL；退出时清理进程、密钥、数据库及状态目录。Swift 的 `.build` 缓存由 SwiftPM 保留在 `tools/e2e`。

MnemoCore 只接受 HTTPS 推送。一键工具验证其真实拉取与入队，再由 Python 使用与服务端一致的签名将队列 POST 到本地 HTTP 接收端；这不覆盖 MnemoCore 自身的 HTTPS 推送实现。验证实际 VPS HTTPS 推送请使用下方 `--push-url`。

工具先检查带签名的 ping 确认可用，再继续，每次就绪检查上限 20 秒；Swift 编译和执行上限 300 秒。随机端口通过短暂绑定再释放选择，极小概率被其他进程抢占时会失败，可重跑。不会更改系统接收端配置或 Keychain。

## 假网关

```bash
python3 tools/fake_gateway.py --token 'localtest.only-for-local-testing' --log
# 或通过 FAKE_GATEWAY_TOKEN 环境变量传入
python3 tools/fake_gateway.py --port 8723 --add 3 --interval 5 --log
```

默认绑定 `127.0.0.1:8723`；支持 `--host`、`--port`。未传 token 时随机生成并打印到 stderr，复制到 Swift 命令使用，仅用于本机测试。日志只记录工具名、参数与返回条数，不输出密钥（自动生成 token 的启动提示除外）。`--add N` 每隔 `--interval` 秒新增 N 条 transcript。

支持 POST `/v1/ping`、`get_transcripts`、`search_evidence`、`get_open_loops`，校验 bridge 10、请求 HMAC、毫秒时间戳五分钟窗口和 nonce 重放，并签名响应（无法提取 nonce 时省略响应签名）。默认含 transcript 250、meeting 3、memory 120、card 5、todo 4，分布在最近 30 天。transcript 按 ID 升序分页；search_evidence 按 offset 分页；days=0 表示全部。

## Swift 核心库验证

另开终端，保持假网关运行：

```bash
swift run --package-path tools/e2e mnemo-e2e \
  --token 'localtest.only-for-local-testing' --port 8723 \
  --device mac-e2e --days 0 --rounds 2
```

状态目录默认随机创建，退出时清理。需保留检查时加 `--keep-state`；可加 `--state-dir /tmp/mnemo-e2e-fresh` 指定一个尚不存在的目录。输出目录位置、每轮 pulled（记录数）、pushed / pending（队列文件数）和 sinceId，并检查入队记录的 sourceType、ID 与 device。

首次 days=0 拉取全部历史，之后 MnemoCore 对非 transcript 类型使用最近两天窗口，因此第二轮总 pulled 通常不为零。增量检查针对 transcript：跨批次不能重复，ID 必须大于上一轮游标，且与新游标一致；meeting/memory/card/todo 重复允许，由服务端按 `(device, sourceType, id)` 去重。ID 唯一性按 sourceType 分组校验，不能要求不同来源的数字 ID 互不重叠。

可将 `--days` 改为 1–3650 缩小首次窗口；要确保触发 transcript 200 条分页和 memory 100 条 offset 分页，请保留 `--days 0`。配合假网关 `--add`，新增数据只有在两轮请求之间到达才会被第二轮观察到。

验证真实 HTTPS 接收端（会写入虚构测试记录，请使用测试实例）：

```bash
swift run --package-path tools/e2e mnemo-e2e \
  --token 'TOKEN_ID.SECRET' --port 8723 --device mac-test \
  --push-url 'https://your-test-vps.example/path' --push-key 'YOUR_TEST_PUSH_KEY'
```

配置推送时调用实际 `Syncer.run()` 推送，并调用 `pingPush()` 打印延迟；成功推送会删除队列，因此该模式仅检查结果与游标，完整 NDJSON 内容校验使用无 push-url 模式。命令行参数可能被本机进程列表看到，勿在共享 Mac 使用真实生产密钥。

## iOS 真机注意

真机上的 `127.0.0.1` 指向手机本身，无法访问 Mac 的假网关。跨 App 使用本机网关需要极米记得 App 在运行、网关已开启且未被 iOS 后台挂起；另一 App 活跃时其服务能否持续响应需在真机验证。iOS 网络策略也可能要求应用具备相应本机 HTTP 配置。

iOS 模拟器可通过 loopback 访问 Mac 服务，模拟器与 Mac 共享网络，Mac/模拟器成功不能证明真机上的跨 App 访问或后台保活可用。当前 MnemoCore 的网关地址固定为 127.0.0.1，仅提供端口配置，`--host` 不会改变核心库客户端地址。

## API 与文件范围

当前 `Config`、`Config.init()`、所需配置字段及 `validated()`、`Syncer.init(config:dir:log:)`、`run()`、`ping()`、`pingPush()`、`SyncResult` 及其结果字段均已 public，无需修改 iOS 可见性。工具直接依赖本地包，未复制或替代核心库实现。

新增文件仅位于 `tools/`：`fake_gateway.py`、`e2e/Package.swift`、`e2e/Sources/MnemoE2E/main.swift`、`run_local_e2e.sh`、`local_e2e.py`、本说明。按任务要求未编译、未运行或启动服务；首次实际验证由使用者执行。
