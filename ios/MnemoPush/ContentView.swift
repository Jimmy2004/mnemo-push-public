import SwiftUI
import MnemoCore

@MainActor struct ContentView: View {
    @ObservedObject private var model = SyncModel.shared
    @Environment(\.scenePhase) private var phase
    @State private var config = Config()
    @State private var port = "8723"
    @State private var days = "2"
    @State private var interval = "15"
    @State private var showToken = false
    @State private var showKey = false
    @State private var testingGateway = false
    @State private var testingPush = false
    @State private var pushLabel = "测试连接"
    @State private var gatewayResult = ""
    @State private var pushResult = ""
    @State private var refreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var guide = false
    @ObservedObject private var keepAlive = KeepAliveController.shared
    @State private var tier = BackgroundSettings.tier
    @State private var pendingTier: String?
    @State private var confirmTier = false
    @State private var eventMinutes = String(BackgroundSettings.eventMinutes)
    @State private var steps = String(BackgroundSettings.steps)
    private var eventError: String? {
        guard let value = Int(eventMinutes), (1...1440).contains(value) else { return "事件触发最小间隔须为 1–1440 的整数" }
        return nil
    }
    private var stepsError: String? {
        guard let value = Int(steps), (50...5000).contains(value) else { return "步数阈值须为 50–5000 的整数" }
        return nil
    }
    private var settingsInvalid: Bool { intervalError != nil || eventError != nil || stepsError != nil }
    private var intervalError: String? {
        guard let n = Int(interval), n >= 0 else { return "请输入整数" }
        let (minutes, overflow) = n.multipliedReportingOverflow(by: config.intervalInHours ? 60 : 1)
        if overflow || minutes > 1440 { return config.intervalInHours ? "最多 24 小时" : "最多 1440 分钟（24 小时）" }
        return minutes < 15 ? "最少 15 分钟（系统限制）" : nil
    }
    private func current() throws -> Config {
        guard intervalError == nil, let n = Int(interval), let p = Int(port), let d = Int(days) else { throw SyncException(intervalError ?? "端口和天数须为整数") }
        var c = config; c.intervalMinutes = n * (c.intervalInHours ? 60 : 1); c.gatewayPort = p; c.days = d
        return try c.validated()
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.running ? "同步中…" : (model.last.map { $0.ok ? "同步正常" : "同步失败" } ?? "尚未同步")).font(.title2)
                    if let last = model.last {
                        Text(last.ok ? "上次同步：\(SyncModel.stamp(last.at))，共 \(last.count) 条" : "上次同步：\(SyncModel.stamp(last.at))\n\(last.error.prefix(120))")
                    } else { Text("填写下方两部分配置后保存") }
                    Button("立即同步") { model.manual() }.disabled(model.running)
                }.listRowBackground(model.last?.ok == false ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                Section("① 本机 · 只读") {
                    Text("极米记得网关").font(.headline)
                    Text("在手机本机读取数据，通行证不会离开手机").font(.caption)
                    Button("粘贴安装提示词") { paste(gateway: true) }
                    Text("只提取文字，不会执行其中脚本").font(.caption)
                    secret("通行证 token", text: $config.token, shown: $showToken)
                    TextField("agent", text: $config.agent)
                    TextField("端口", text: $port).keyboardType(.numberPad)
                    Button(testingGateway ? "测试中…" : "测试连接") { test(gateway: true) }.disabled(testingGateway)
                    if !gatewayResult.isEmpty { Text(gatewayResult).font(.caption).textSelection(.enabled) }
                }
                Section("② 云端 · HTTPS") {
                    Text("VPS 推送").font(.headline)
                    Text("数据签名后推送到你自己的服务器，离线时在本机排队").font(.caption)
                    Button("粘贴推送配置") { paste(gateway: false) }
                    TextField("PUSH_URL（https://）", text: $config.pushUrl).keyboardType(.URL)
                    secret("PUSH_KEY", text: $config.pushKey, shown: $showKey)
                    TextField("设备标识（可选）", text: $config.device)
                    Text("留空则不标识。字母数字 -_.，最多 32 位").font(.caption)
                    Button(testingPush ? "测试中…" : pushLabel) { test(gateway: false) }.disabled(testingPush)
                    if !pushResult.isEmpty { Text(pushResult).font(.caption).textSelection(.enabled) }
                }
                Section("③ 后台") {
                    Toggle("定时自动同步", isOn: $config.autoSync)
                    Picker("保活强度", selection: Binding(get: { tier }, set: chooseTier)) {
                        ForEach(BackgroundSettings.tiers, id: \.self) { Text($0).tag($0) }
                    }
                    Text(BackgroundSettings.description(tier)).font(.caption)
                    Text("保活档位立即生效；自动同步开关和间隔修改后点保存。").font(.caption)
                    TextField("事件触发最小间隔 n 分钟", text: $eventMinutes).keyboardType(.numberPad)
                    if let error = eventError { Text(error).foregroundStyle(.red) }
                    if tier == "强力" {
                        if KeepAliveController.stepsAvailable {
                            TextField("步数触发阈值（步）", text: $steps).keyboardType(.numberPad)
                            if let error = stepsError { Text(error).foregroundStyle(.red) }
                        }
                        Text("计步和运动事件仅在 App 活着时有效，不能唤醒已挂起的 App；强力档依靠音频维持运行。").font(.caption)
                    }
                    TextField("同步间隔", text: $interval).keyboardType(.numberPad)
                    Picker("单位", selection: $config.intervalInHours) {
                        Text("分钟").tag(false); Text("小时").tag(true)
                    }.pickerStyle(.segmented)
                    if let error = intervalError { Text(error).foregroundStyle(.red) }
                    TextField("首次拉取天数", text: $days).keyboardType(.numberPad)
                    Text("填 0 拉取全部历史（首次 3650 天）；之后会议/记忆等按最近 2 天窗口增量拉取。大于 0 时使用该天数。").font(.caption)
                    Text("请在系统设置中开启「后台 App 刷新」。iOS 的后台间隔只是「最早不早于」，系统自行决定实际时间，无法保证准点同步。").font(.caption)
                    Text("实际档位：" + keepAlive.effectiveTier)
                    Text("后台 App 刷新：" + refreshText)
                    Text("定位权限：" + keepAlive.locationStatus)
                    Text("音频保活：" + (keepAlive.audioRunning ? "运行中" : "未运行"))
                    Text("后台上传队列：\(model.uploadCount) 个文件")
                    Text("上次触发：\(model.triggerSource)" + (model.triggerTime.map { " · " + SyncModel.stamp($0) } ?? ""))
                    Text("被节流次数：\(model.throttled)")
                    Button("打开本 App 的系统设置", action: settings)
                }
                #if !NOLOG
                Section("最近日志") {
                    ScrollView {
                        Text(model.logs.isEmpty ? "暂无同步日志" : model.logs.reversed().joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 240)
                }
                #endif
                Section {
                    Button("保存", action: save).disabled(settingsInvalid)
                    if !model.notice.isEmpty { Text(model.notice).font(.caption).textSelection(.enabled) }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Mnemo Push")
            .onAppear(perform: load)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MnemoUploadChanged"))) { _ in
                Task { await model.refreshUploads() }
            }
            .onChange(of: phase) { if $0 == .active { refreshStatus = UIApplication.shared.backgroundRefreshStatus } }
            .onChange(of: keepAlive.locationStatus) { _ in tier = BackgroundSettings.tier }
            .alert("启用更强保活", isPresented: $confirmTier) {
                Button("启用") { if let value = pendingTier { commitTier(value) }; pendingTier = nil }
                Button("取消", role: .cancel) { pendingTier = nil }
            } message: { Text(BackgroundSettings.description(pendingTier ?? "省电") + "位置和运动仅用作触发，不记录、不上传。") }
            .alert("让自动同步稳定运行", isPresented: $guide) {
                Button("现在设置", action: settings); Button("稍后", role: .cancel) {}
            } message: { Text("请开启「后台 App 刷新」。系统自行安排执行时间；关闭应用或系统限制后台时可能无法同步。") }
        }
    }
    @ViewBuilder private func secret(_ title: String, text: Binding<String>, shown: Binding<Bool>) -> some View {
        HStack {
            if shown.wrappedValue { TextField(title, text: text) } else { SecureField(title, text: text) }
            Button(shown.wrappedValue ? "隐藏" : "显示") { shown.wrappedValue.toggle() }.buttonStyle(.borderless)
        }.privacySensitive()
    }
    private var refreshText: String {
        switch refreshStatus { case .available: return "已开启"; case .denied: return "已关闭"; case .restricted: return "受系统限制"; @unknown default: return "未知" }
    }
    private func settings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func load() {
        do {
            config = try ConfigStore.load(); port = String(config.gatewayPort); days = String(config.days)
            if config.intervalInHours && config.intervalMinutes % 60 != 0 { config.intervalInHours = false }
            interval = String(config.intervalInHours ? config.intervalMinutes / 60 : config.intervalMinutes)
        } catch { model.notice = "无法读取配置，请解锁设备后重试" }
    }
    private func paste(gateway: Bool) {
        let parsed = PromptParser.parse(UIPasteboard.general.string ?? "")
        let selected = gateway ? parsed.gatewayOnly() : parsed.pushOnly()
        guard !selected.isEmpty else {
            model.notice = gateway ? "剪贴板里没有找到极米记得通行证" : "剪贴板里没有找到 PUSH_URL / PUSH_KEY"; return
        }
        config = selected.apply(to: config)
        if let p = selected.gatewayPort { port = String(p) }
        UIPasteboard.general.items = []
        model.notice = RecentLog.safe("已填入：\(selected.summary())，确认后点「保存」", config: config)
    }
    private func chooseTier(_ value: String) {
        if value != "省电" && !UserDefaults.standard.bool(forKey: "confirmedTier." + value) {
            pendingTier = value; confirmTier = true
        } else { commitTier(value) }
    }
    private func commitTier(_ value: String) {
        UserDefaults.standard.set(true, forKey: "confirmedTier." + value)
        BackgroundSettings.tier = value; tier = value
        model.applyKeepAlive(); tier = BackgroundSettings.tier
    }
    private func save() {
        do {
            guard eventError == nil, stepsError == nil, let events = Int(eventMinutes), let threshold = Int(steps) else {
                throw SyncException(eventError ?? stepsError ?? "请输入整数")
            }
            let c = try current()
            try ConfigStore.save(c); config = c
            BackgroundSettings.eventMinutes = events; BackgroundSettings.steps = threshold
            model.applyKeepAlive()
            try model.schedule()
            if BackgroundSettings.tier == tier { model.notice = "已保存" }
            tier = BackgroundSettings.tier
            if c.autoSync && !UserDefaults.standard.bool(forKey: "guided") {
                guide = true; UserDefaults.standard.set(true, forKey: "guided")
            }
        } catch { model.notice = RecentLog.safe(error.localizedDescription, config: config) }
    }
    private func test(gateway: Bool) {
        // Connectivity tests use the current draft; immediate sync uses saved settings.
        var c = config
        c.token = c.token.trimmingCharacters(in: .whitespacesAndNewlines)
        c.agent = c.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.agent.isEmpty { c.agent = "claude" }
        c.pushUrl = c.pushUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        c.pushKey = c.pushKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = Int(port) { c.gatewayPort = p }
        if gateway { testingGateway = true } else { testingPush = true }
        Task {
            defer { if gateway { testingGateway = false } else { testingPush = false } }
            do {
                let syncer = Syncer(config: c, dir: ConfigStore.directory)
                if gateway { try await syncer.ping(); gatewayResult = "✓ 已连接极米记得网关" }
                else { let ms = try await syncer.pingPush(); pushLabel = "✓ 已连接 · \(ms) ms"; pushResult = "" }
            } catch {
                let message = String(RecentLog.safe(error.localizedDescription, config: c).prefix(120))
                if gateway { gatewayResult = message } else { pushResult = message; pushLabel = "测试连接" }
            }
        }
    }
}
