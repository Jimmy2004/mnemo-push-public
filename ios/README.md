# Mnemo Push · iOS

Swift 5.9+、SwiftUI、iOS 16+，无第三方运行依赖。版本 0.3.2 (1)，Bundle ID 为 `dev.mnemo.push`。MnemoCore 也支持 macOS 13+。

## 生成工程与运行

1. 安装完整 Xcode 和所需 iOS 平台支持。
2. 安装 XcodeGen 并生成工程：
   ```sh
   brew install xcodegen
   cd ios && xcodegen
   open MnemoPush.xcodeproj
   ```
3. 选择 MnemoPush target，在 Signing & Capabilities 中自行选择签名团队。
4. 选择真实 iPhone 或已下载的 iOS 模拟器，在 Xcode 运行。
5. NoLog 版选择 `MnemoPush-NoLog` scheme；同 Bundle ID，会替换普通版，保留共享配置。
6. 安装后粘贴本机安装提示词、云端推送配置，测试连接，保存，再立即同步。测试连接使用当前输入，立即同步使用已保存配置。

`MnemoCoreTests` 为不依赖 App host 的单元测试 target，引用 Package 的测试源码；也可由 Swift Package 使用同一套测试。本次交付未生成 Xcode 工程、未编译、未运行测试。

## 个人侧载

本 App 仅供个人侧载，不面向 App Store。源码使用 iOS 26 SDK 中的 continued processing API，需 Xcode 26+；运行最低 iOS 16。

- Xcode 免费 Apple ID（Personal Team）：连接 iPhone、选择签名团队后安装；免费签名通常 7 天有效，到期重新签名安装。
- AltStore / SideStore：导入自行签名的 IPA，按各自要求配置续签；自动续签需其配套服务、网络及后台条件满足，安装后检查剩余有效期。
- 免费账号通常最多同时安装 3 个侧载 App；AltStore / SideStore 自身也占名额。
- 安装后到「设置 → 通用 → VPN 与设备管理」信任开发者证书；按提示在「隐私与安全性 → 开发者模式」开启并重启确认。具体入口可能随系统版本变化。
- 签名工具若修改 Bundle ID，continued 白名单必须保持 `$(PRODUCT_BUNDLE_IDENTIFIER).continued.*` 与提交时前缀一致。

## 三档后台保活

| 档位 | 能力与取舍 |
|---|---|
| 省电（默认） | BGAppRefresh + 需网络、无需电源的 BGProcessing；系统安排运行，可能数小时一次。后台 URLSession 继续上传已签名的文件。 |
| 均衡 | 包含省电能力；「始终」定位下监听显著位置变化（约 500 米）、到访和单一约 150 米退出围栏。低耗电，移动更容易触发。系统可能因位置事件重新启动 App，强制划掉后的行为须真机确认，不能保证。 |
| 强力 | 包含均衡能力；程序生成静音 PCM 循环播放、音频会话混音，按同步间隔触发；额外计步和静止转运动触发。耗电较高，音频中断期间暂停，结束后尝试恢复。系统仍可能限制运行，无法承诺硬实时。 |

在③后台选择档位立即生效，首次升档需确认耗电及权限；定位从使用期间升级为始终，拒绝则回退省电并提示。自动同步开关、同步间隔（15–1440 分钟）、事件最小间隔（1–1440 分钟，默认15）、步数阈值（50–5000，默认200）点保存生效。关闭自动同步停止保活。

位置、到访、围栏、步数、运动状态和回到前台共用事件最小间隔，以**上次同步开始时间**判断；被节流只累计计数。手动同步不受节流，BGTask 和音频计时器使用同步间隔；所有入口共享单一同步操作。计步/运动回调不能唤醒已挂起的 App，仅在 App 运行时有效；无计步硬件时隐藏阈值。位置和运动仅作触发信号，不记录、不上传坐标或运动数据。系统区域监控自身保存围栏定义，App 不另存坐标。

手动立即同步在 iOS 26+ 提交 BGContinuedProcessingTask 并报告拉取/推送进度；提交失败或较低系统直接前台执行。后台任务过期取消当前同步，已交给系统的上传可独立继续，队列下轮重试。

**极米记得自身在后台被 iOS 挂起时，本 App 无法拉取其新数据，此时只能推送已排队数据。** 更强保活不等于能唤醒另一个 App 的网关。首次全量拉取最好让网关和本 App 都保持可访问状态。

## 后台上传恢复

后台任务和事件同步使用 `dev.mnemo.push.upload` 后台 session：签名后的 NDJSON 写入沙盒暂存文件，再以文件上传；前台手动同步及测试连接使用普通 session，及时反馈。只有 HTTP 200 才删除原队列。404 可能是签名时间戳超出服务端 300 秒容差，也可能是地址/密钥错误；非200保留文件，下一轮重新签名。进行中文件集合持久化，启动通过 getAllTasks 对账，普通上传与后台上传共享文件占用，避免重复上传。系统可能在签名后延迟发起，因此无法完全消除时间戳过期。

## 存储与网络

token / pushKey 只存 Keychain，使用 AfterFirstUnlockThisDeviceOnly；其他配置和已脱敏最近 50 条日志、上次状态存 UserDefaults。队列与 state.json 在 App 沙盒 Application Support/mnemo/；卸载会删除沙盒数据。队列先写 .tmp 再同目录原子改名为 %013d-UUID.ndjson，之后保存游标；收到推送 HTTP 200 后才删除文件。

网关仅访问 loopback，ephemeral URLSession 的代理字典设为空，拒绝重定向并验证响应签名。推送沿用系统代理配置、HTTPS 和固定 User-Agent，拒绝重定向以避免密钥签名头流向其他站点；PUSH_URL 应填最终接收地址。

读取超时沿用 Android（网关 ping 5 秒、转录 180 秒、证据 90 秒、待办 15 秒、推送 60 秒、推送 ping 10 秒）。URLSession 的请求超时是空闲超时，资源总超时设为读取值加连接预算（网关 5 秒 / 云端 15 秒）；它无法独立设置与 HttpURLConnection 完全相同的 connectTimeout，因此连接超时语义存在差异。

图标为 Python 标准库生成的 1024×1024 RGB PNG，使用 Android 指定三色和手环/云意象。

详细文件清单、差异与待确认项见 [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md)。
