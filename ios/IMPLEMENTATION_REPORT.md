# iOS 保活与事件触发实现报告

仅修改 ios/。先阅读现有 App、Core、配置、网关、队列及文档源码。按要求未编译、未运行测试、未生成工程、未启动模拟器。

## 改动文件

- `MnemoPush/BackgroundSettings.swift`：独立 UserDefaults 配置，兼容上一版 Config JSON；默认省电、事件间隔15分钟、步数200。
- `MnemoPush/KeepAliveController.swift`：位置权限、显著变化、到访、单一动态退出围栏、静音音频、计时器及运动事件。
- `MnemoPush/SyncModel.swift`：统一同步互斥、事件节流、后台执行租约、BGProcessing 调度与过期取消、continued processing 手动任务、状态计数。
- `MnemoPush/MnemoPushApp.swift`：后台任务注册、位置冷启动恢复、后台 URLSession 系统 completion 转交。
- `MnemoPush/ContentView.swift`：档位 Picker、首次确认、事件/步数校验、权限/音频/上传/触发状态。
- `MnemoPush/Info.plist`：processing/location/audio 模式、权限中文说明、continued identifier 通配白名单。
- `MnemoCore/Sources/MnemoCore/BackgroundUploader.swift`：后台文件上传、签名、占用持久化及任务恢复、200删除、错误保留和脱敏日志。
- `MnemoCore/Sources/MnemoCore/Syncer.swift`：后台队列提交与前台即时上传分流、共享文件占用、进度上报。
- `README.md`、本报告：侧载、取舍、平台限制及人工确认事项。

## 各档能力

省电：保留 BGAppRefresh，新增网络必需、电源非必需 BGProcessing；处理过期并提前重新调度。后台任务先补推积压再尝试网关，使用后台 session 文件上传；手动及测试连接使用普通 session。后台任务交接上传完成不代表服务器已收到，只有上传回调 HTTP 200 才删除队列。

均衡：增加显著位置变化、到访和约150米退出围栏；仅管理固定 identifier 的一个围栏，唤醒后请求当前位置重新围住。沿用传统 CLLocationManager 区域监控，未使用 CLMonitor。坐标仅在回调内用于注册系统围栏，不写 App 文件、不传到服务器、不记日志。位置冷启动重新监听。系统自身必须保存区域定义才能监控，不能将“不保存坐标”理解为系统也不保留围栏。始终定位被拒绝时停止增强保活并回退省电。

强力：包含均衡能力，额外程序生成静音PCM、playback + mixWithOthers、零音量循环和按同步间隔的计时器。中断停止、结束重新激活；媒体服务重置后重建。步数阈值和静止转步行/跑步/骑行/驾车均受事件节流；运动事件不具有唤醒挂起App的保证。降档立即释放不再需要的监听和音频会话。

事件节流统一参考上次同步开始时间；被抑制事件仅增加计数，不逐条输出日志。手动绕过节流；定时使用同步间隔。同步 operation 全局互斥，后台/前台文件上传也共享占用。

## 必须人工在 Xcode / 真机确认

1. **BGContinuedProcessingTask**：需 Xcode 26+ SDK；较低运行系统已用 `#available(iOS 26.0, *)` 退回前台执行。按公开 API 编写 `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)`、`.strategy = .fail`、`progress`、过期取消；仍须人工核对实际 SDK 签名、Swift 并发诊断，以及在按钮事件中动态注册唯一 identifier 的系统行为。核对签名工具改 Bundle ID 后通配前缀、任务进度 UI、用户取消及系统过期。拉取页数未知，进度表示阶段和页/文件处理推进，不预估准确剩余时间。
2. **后台 session 恢复**：真机测试锁屏、网络切换、系统终止重启、didFinishEvents 与 getAllTasks 对账、completion 恰好调用、临时文件寿命和HTTP200删除。测试404（超过300秒）、403、断网与重新签名重试，以及普通上传与后台任务并发时不会重复同文件。后台URLSession不保证在用户强制退出后继续。
3. **定位唤醒**：测试先whenInUse再always的系统授权流程、暂不升级/拒绝、在设置撤销权限、精确定位关闭、硬件能力限制、位置冷启动、显著变化/到访/围栏离开。系统策略决定划掉后的恢复，不能保证每次都拉起；150米围栏不等于精准150米立即回调。
4. **音频中断恢复**：来电、闹钟、Siri、独占音频、耳机拔插/蓝牙切换、媒体服务重置后确认恢复；长时间锁屏确认零音量静音仍获后台运行预算及实际耗电。即使配置audio模式，系统仍可能暂停或终止进程；无法保证硬实时同步。
5. **运动**：真机确认运动权限拒绝/撤销、无计步硬件隐藏选项、阈值重置、静止转运动；这些回调不能独立唤醒挂起的App。
6. **互斥与节流**：同时触发 BGTask/位置/音频计时器/前台/手动，确认仅一轮；过期取消、下轮重试，1/1440分钟及50/5000步边界、非法输入、档位即时降级和状态显示。
7. **NOLOG**：保留原 `NOLOG` 条件，新增UI不依赖日志区；人工确认普通和NoLog scheme均能编译运行，Package及App的编译条件传播与原版日志存储语义。
8. **本机网关限制**：极米记得后台被挂起时不能拉取新数据，只能推送既有队列；保活仅作用于本App。首次全量拉取建议保持网关可访问。免费侧载签名/续签条件和3个App名额需按实际账号与侧载工具确认。

## API 参考

- [Apple：continued request 初始化与 Bundle ID 通配规则](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:))
- [Apple：BGContinuedProcessingTask / ProgressReporting](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Apple WWDC25：continued任务可在启动完成后注册](https://developer.apple.com/videos/play/wwdc2025/227/)

仅做源码审阅与 `git diff --check`，没有编译或运行任何测试。工作区出现的 `tools/` 未跟踪文件未作改动。本次交付是源码实现，未声称已通过编译或真机验证。
