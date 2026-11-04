# Android 0.2 验证报告

验证日期：2026-11-04（Asia/Hong_Kong）。范围：`android/`，Kotlin / Material 3，包名 `dev.mnemo.push`，versionName `0.2`、versionCode `2`（`android/app/build.gradle.kts:7-14`）。只验证，不修复源文件。

## 结论

**不通过**：存在代码审查问题，且本轮构建、单元测试、lint 与设备验证受沙箱限制未能完成。环境阻断不代表编译或测试断言失败，也不计入代码问题数量。

代码发现共 **7 项：高 1、中 5、低 1、致命 0**。其中涉及设备表现的项目为静态风险判断，未声称真机复现。

## 1. 构建与测试

在 `<HOME>/mnemo-push/android/` 原样执行：

```sh
JAVA_HOME=$(/usr/libexec/java_home -v 21) ./gradlew --offline :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

Java 21 可定位：`/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home`。命令退出码 **1**，Gradle Wrapper 阶段即失败：

```text
java.io.FileNotFoundException:
<HOME>/.gradle/wrapper/dists/gradle-8.13-bin/5xuhj0ry160q40clulazy9h7d/gradle-8.13-bin.zip.lck
(Operation not permitted)
```

用户目录 Gradle 缓存不在当前沙箱可写范围，无法创建/打开分发包锁文件。未更换 GRADLE_USER_HOME、复制分发包、提权或采用其他绕过方式。

| 任务 | 本轮结果 |
| --- | --- |
| `:app:testDebugUnitTest` | 未执行，Wrapper 被阻断 |
| `:app:assembleDebug` | 未执行，Wrapper 被阻断 |
| `:app:lintDebug` | 未执行，Wrapper 被阻断 |

**lint Error 与安全/后台/权限 Warning：无本轮结果可列，不可解释为零问题。** `android/app/build/` 内也未发现现存 lint 报告。现存单元测试报告与 APK 属于先前产物，不作为本轮通过证据；本轮未运行替代测试。

## 2. 问题清单

以下路径均相对于仓库根目录，严重程度为审查评级，不是 lint 输出。

### V01：粘贴时整表回填会改动另一部分输入（中）

- 位置：`android/app/src/main/java/dev/mnemo/push/MainActivity.kt:105-123,136`。
- 问题：解析结果的 `gatewayOnly()` / `pushOnly()` 确实分离，但随后执行 `fill(parsed.applyTo(currentConfig()))`。`currentConfig()` 会 trim 所有文本、将空 agent 改成 `claude`、将无效端口改为 `8723`、将天数归一化，然后 `fill()` 重写整张表。因此“云端只填 PUSH_URL/PUSH_KEY”在界面行为上不严格成立。
- 复现路径（静态推导）：将 agent 清空、端口清空或填 `0`，粘贴合法云端配置；本机 agent 会变成 `claude`，端口变成 `8723`。本机粘贴同样会 trim 云端字段。无需解析器跨区提取即可发生。
- 建议：按按钮只更新对应 EditText；保存时再校验/归一化，避免粘贴触碰其余未保存输入。

### V02：边到边布局遗漏横向安全区（中）

- 位置：`android/app/src/main/java/dev/mnemo/push/MainActivity.kt:50,61-66`；`android/app/src/main/res/layout/activity_main.xml:32-44,329-335`。
- 问题：监听器只使用 systemBars/IME 的 bottom；没有处理左右 systemBars 或 displayCutout。横屏侧边导航栏/刘海下，滚动内容与右下保存按钮没有相应安全边距，可能遮挡。AppBar 的 `fitsSystemWindows=true` 不能替代兄弟滚动区和 FAB 的横向处理。
- 建议：针对滚动区/FAB 合并 systemBars 与 displayCutout 的左右安全边距，保留原始 padding/margin；补测横屏、刘海、三键导航及键盘弹出。当前 bottom 使用合并后的 IME/系统栏最大值而非相加，这一点合理。

### V03：Android 8.x / 9 以下受支持版本不会清空密钥剪贴板（中）

- 位置：`android/app/src/main/java/dev/mnemo/push/MainActivity.kt:137`；`android/app/build.gradle.kts:11`。
- 问题：最低支持 API 26，但仅在 API >=28 调用 `clearPrimaryClip()`。API 26/27 粘贴 token 或 pushKey 后原剪贴板仍保留密钥。API >=28 也仅在当前按钮确实提取到密钥时清空；未命中/只识别 agent 或 URL 时保留原剪贴板是现行行为。
- 建议：API 26/27 用空白 ClipData 覆盖；API >=28 继续清空。以实际支持系统版本验证。

### V04：BOOT_COUNT 读取失败时放行，违背关闭自启语义（中）

- 位置：`android/app/src/main/java/dev/mnemo/push/Background.kt:14-22`；`android/app/src/main/java/dev/mnemo/push/SyncWorker.kt:57-59`。
- 问题：读取失败返回 `-1`，只有 now/saved 均非负且不等才判为重启。任一值未知时返回 false；即使 autoStart=false，WorkManager 恢复的任务仍可同步。此为确定的错误分支行为，未在具体厂商设备上复现读取失败。
- 建议：未知计数时采取保守暂停，待用户明确打开应用恢复，或采用可验证的备用重启标识；不要把“无法判断”当作“未重启”。

### V05：厂商入口成功启动不等于打开自启动页面（低）

- 位置：`android/app/src/main/java/dev/mnemo/push/Background.kt:49-76`；`android/app/src/main/java/dev/mnemo/push/MainActivity.kt:202-208`。
- 问题：不按品牌筛选，循环全部厂商组件，首个 startActivity 无异常就返回 true。列表含华为 `ProtectActivity`、三星 `BatteryActivity` 等后台保护/电池入口，不能保证就是自启动管理页；存在多个兼容组件的系统也可能命中非目标入口。Activity 成功启动后系统仍可能重定向，返回 true 无法确认目标页面。
- 崩溃审查：循环中的 ActivityNotFoundException/SecurityException 被 runCatching 捕获；兜底应用详情页的异常也由 Activity 调用处外层 runCatching 捕获，未发现此调用链必然造成应用崩溃。但兜底也失败时提示仍声称“已打开应用详情”，不准确。
- 建议：品牌分组并区分“自启动”“后台保护”入口，返回明确结果；全部失败时提示无法打开，保留手动路径。厂商版本差异必须设备验证。

### V06：秒级队列文件名可能覆盖尚未推送的数据（高）

- 位置：`android/app/src/main/java/dev/mnemo/push/SyncCore.kt:140-144`。
- 问题：队列名只取 Unix 秒，`writeText()` 覆盖同名文件。两次拉取在同一秒完成且上一批仍排队时（如推送配置未完成/推送失败后立即重试），后一批覆盖前一批；游标已前移，可能永久漏传前一批 transcript。Worker 的 Mutex 只保证串行，不保证两次落盘跨秒。
- 建议：使用 UUID/原子创建唯一文件，并通过临时文件原子落盘后再更新游标，禁止覆盖现存批次。补充同秒连续拉取且队列不消费的验证。

### V07：解密失败静默降级为空配置，可显示伪成功（中）

- 位置：`android/app/src/main/java/dev/mnemo/push/SecureStore.kt:35-48`；`android/app/src/main/java/dev/mnemo/push/SyncCore.kt:26-27,93-99`；`android/app/src/main/java/dev/mnemo/push/SyncWorker.kt:64-66`。
- 问题：Base64 损坏、GCM 验证失败或 Keystore 不可用时解密一律返回空串。两项密钥均无法解密时 hasGateway/hasPush 均为 false，Syncer 可返回拉取/推送均为零，Worker 记“同步成功”；用户无法区分未配置与已保存密钥失效。
- 建议：区分不存在与解密失败；失败时向 UI/Worker 返回不含密钥的配置错误，提示重新配置，不记为同步成功。AES/GCM 本身并未因此泄露明文。

## 3. 逐项审查记录

### MainActivity 与布局

- **ID/类型匹配通过（静态）**：脚本比较全部 `R.id` 引用与 XML，28 个引用全部存在，未发现缺失/类型冲突。包括 token/agent/port/pushUrl/pushKey/days、两个 switch、interval/i15/i30/i60、statusTitle/statusDetail/logs、pastePrompt/pastePush/testGateway/syncNow/battery/autostartSettings/lockGuide、keepAliveHint、tokenLayout/pushUrlLayout、root/scroll/save。appBar/toolbar 为布局独有 ID，无须 Activity 绑定。
- **insets 部分通过**：`MainActivity.kt:61-66` 保留底部 96dp 滚动空间并将 FAB 放到 IME/系统栏上方；顶部 AppBar 使用 XML:13 的 fitsSystemWindows。横向缺口见 V02；实际键盘调整行为尚未设备验证。
- **粘贴解析范围通过、界面严格隔离不通过**：`MainActivity.kt:72-73,130-136` 与 `PromptParser.kt:33-41` 明确分流；整表回填问题见 V01。
- **剪贴板清空部分通过**：API >=28 提取密钥后清空；旧版遗漏见 V03。
- **密钥输出常规路径静态通过**：`PromptParser.kt:23-29` 摘要只输出字段名称、agent、端口，不输出 token/pushKey；`MainActivity.kt:151-152` 先经 RecentLog.safe 再截断错误；保存/调度失败只用固定提示。
- `SyncWorker.kt:31-37,61-81` 对当前 token、token 的点分片和 pushKey 做精确字符串替换后再写最近日志；未发现 Log/println 输出密钥。`SyncCore.kt:74` 可包含服务端错误正文，但当前 UI/Worker 调用路径均经过该过滤。过滤只保证当前配置的精确明文匹配，不是对编码/变形密钥、任意恶意 agent 或历史日志的形式化无泄露保证；实际输出未运行验证。
- `activity_main.xml:117-119,218-220` 密码字段禁用 Autofill 与 View 状态保存；Manifest:11 禁用备份。未发现明文 token/pushKey 写入配置偏好。

### Background / 启动语义

- `BootReceiver`（`Background.kt:35-42`）只在 autoStart=true 时调用 Scheduler；`Scheduler.apply`（`SyncWorker.kt:91-97`）仍由 autoSync 决定登记或取消周期任务。因此开机自启不是强行打开定时同步。
- `MainActivity.kt:168-171` 保存时更新 Receiver 组件状态并记录当前 boot；XML 开关说明“重启后暂停，打开应用后恢复”（XML:273-274）与 `SyncWorker.kt:57-59` 的正常计数分支一致。关闭 Receiver 不会取消 WorkManager 自身重启恢复，Worker 内守卫是必要的。
- `Settings.Global.BOOT_COUNT` 从 API 24 提供，本项目 minSdk 26 可用；比较“上次用户打开时计数”与当前计数是正常情况下正确的重启检测，不需要把同一次开机内的进程重启当手机重启。失败分支见 V04。
- `MainActivity.kt:98` 在用户打开应用时 markOpened，恢复后续任务资格；不是立即启动一次同步，周期任务仍按 WorkManager 调度。“打开后恢复”不保证打开即刻同步。
- `setComponentEnabledSetting`（`Background.kt:26-31`）对自身显式 BootReceiver 使用 ENABLED/DISABLED 与 DONT_KILL_APP，参数用法正确；设置同时影响该 Receiver 的 BOOT_COMPLETED 和 MY_PACKAGE_REPLACED。
- Receiver 声明 exported=false（Manifest:20-24），未向普通第三方应用开放。未注册 LOCKED_BOOT_COMPLETED，也未声称解锁前可读 Keystore。
- Receiver 同步加载 Keystore/偏好并调度，没有异常保护；慢设备耗时与异常行为需后续设备验证，未据此额外计数。
- autoSync=false 时 Receiver 仍记录“已恢复定时同步”（Background:41），实际 Scheduler 已取消周期任务，日志措辞不严谨，作为语义备注，不重复计入 7 项功能问题。

### SyncWorker / SyncCore / SecureStore

- 自启关闭且确认跨 boot 时先返回 success，不拉取也不推队列（SyncWorker:57-59）；同次开机内关闭自启不会阻止手动/定时同步，符合 UI 文案。
- **pull 失败仍尝试推队列：通过（静态）**。SyncCore:95 捕获 pull 失败，:96 执行 push，:97 才重抛 pull 异常；push 成功后队列可清除，但本轮最终报告 pull 失败。若 push 也失败，push 异常优先传播，原 pull 异常不会被报告；不影响“仍尝试推”的结论。
- **Keystore 算法结构：通过（静态）**。SecureStore:19-32 使用 AndroidKeyStore AES-256/GCM/NoPadding，随机 IV 由 Cipher 生成；保存 IV+ciphertext/tag，解密取前 12 字节 IV 和 128 位 tag（:35-41）。先加密两项再 commit，避免第二项加密失败时先写入半份配置（:51-59）。实际设备加解密往返未执行；失败处理见 V07。
- **gatewayPort/autoStart 持久化：通过（静态）**。SecureStore:48 读取，:58-59 写入，默认 8723/true；MainActivity:106-108 回填、:122-123 收集。网关固定 loopback 并使用该端口（SyncCore:33）；网络策略仅对 127.0.0.1/localhost 放行 HTTP，其余禁明文（network_security_config.xml:4-7）。
- 队列使用应用私有目录明文存数据，不含 Keystore 配置保护；本次不把未提出的数据静态加密要求计为缺陷。队列覆盖问题见 V06。

### PromptParser 与安装提示词

- `PromptParser.kt:47-51` 同时支持 JSON 字符串与 env 的 KEY=value、单/双引号；键名大小写敏感，env 有键名前边界，避免把 USB 前缀变量误认成目标键。
- :59-63 优先 MNEMOSYNE_AGENT，再 AGENT；优先 MNEMOSYNE_GATEWAY_URL，再 gatewayUrl。只从匹配网关 URL 取显式端口，并限制 1..65535；不会扫描任意数字，USB_LOCAL_PORT=18723 不会单独被当网关端口。
- 现存 `PromptParserTest.kt:12-33` 安装结构夹具包含 `AGENT="claude"`、USB 18723、gatewayUrl 8723 和 MNEMOSYNE_GATEWAY_URL 9123，断言选 9123；另有云端配置、保留原值、摘要不含伪密钥测试（:36-54），共 4 个测试方法。本轮均未运行。
- **稳健性结论：对仓库所提供的安装结构夹具静态匹配合理；真实提示词兼容性未完全验证**。仓库未提供可独立核对的实际安装提示词生成器/脱敏完整原件，不能将测试注释“结构一致”直接当成真实来源证据。
- 边界：token 仅接受 id>=4、secret>=8 的字母数字/下划线/短横线结构；agent 1..32；PUSH_KEY 仅接受 32..128 位十六进制。URL 端口用正则而非 URI，IPv6 host、shell 变量引用/转义 JSON、不显式写端口的 URL 不完整支持。未证明这些是当前真实生成格式，故列为覆盖限制，不额外计为已确认缺陷。若 prompt 同时含多份配置，取首个同键匹配，无法关联“当前有效分支”。

## 4. ADB / 截图 / 深色模式

PATH 中无 adb，但找到 `<HOME>/Library/Android/sdk/platform-tools/adb`（36.0.0）。执行该完整路径的 `adb devices` 后 daemon 启动失败：

```text
ADB server didn't ACK
could not install *smartsocket* listener: Operation not permitted
failed to start daemon
adb: failed to check server version: cannot connect to daemon
```

沙箱不允许监听 ADB 本机端口，**无法取得设备列表，不能断言“没有设备”**。没有确认状态为 device 的设备，因此跳过安装与截图；未自行启动模拟器、未更换 ADB 端口或绕过限制。现存 `app/build/outputs/apk/debug/app-debug.apk` 约 7.0 MB、时间 17:54，并非本轮构建产物。

未生成 `verify-shots/` 截图，不存在首页/滚动后画面的观察证据，无法确认错位、截断或深色模式的实际表现。静态主题为 `Theme.Material3.DynamicColors.DayNight.NoActionBar`（themes.xml:2），文本/卡片使用语义色，App.kt:9 启用可用时动态色；这些支持深色主题，但不足以判定实际显示通过。横向 insets 风险见 V02；小屏、大字体与状态栏图标对比度仍待设备验证。

## 5. 验证边界与后续复验

本轮未修改任何源文件、Gradle 配置、Manifest 或测试；仅新增本报告。重新具备正常缓存写权限与 ADB 访问条件后，应原样重跑三项任务，并在已启动设备验证首页/滚动后、深色/浅色、键盘、横屏，以及重启开关语义。本轮不把旧报告或静态判断包装为运行通过。

API 核对参考：[BOOT_COUNT](https://developer.android.com/reference/android/provider/Settings.Global#BOOT_COUNT)、[边到边布局](https://developer.android.com/develop/ui/views/layout/edge-to-edge)、[组件启用状态 API](https://developer.android.com/reference/android/content/pm/PackageManager#setComponentEnabledSetting(android.content.ComponentName,%20int,%20int))。
