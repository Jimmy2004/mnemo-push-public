import SwiftUI
import BackgroundTasks
import MnemoCore

@MainActor final class SyncModel: ObservableObject {
    static let shared = SyncModel()
    static let identifier = "dev.mnemo.push.sync"
    typealias Last = RecentLog.Last
    @Published var running = false
    @Published var last: Last?
    @Published var logs: [String] = []
    @Published var notice = ""
    @Published var uploadCount = 0
    @Published var triggerSource = UserDefaults.standard.string(forKey: "triggerSource") ?? "尚无"
    @Published var triggerTime = UserDefaults.standard.object(forKey: "triggerTime") as? Date
    @Published var throttled = UserDefaults.standard.integer(forKey: "throttled")
    private var started = UserDefaults.standard.object(forKey: "syncStarted") as? Date
    private var operation: Task<Bool, Never>?
    init() {
        last = RecentLog.last()
        logs = RecentLog.read()
    }
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
    func append(_ text: String, config: Config) {
        logs = RecentLog.append(text, config: config)
    }
    func sync(source: String = "手动", background: Bool = false, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async -> Bool {
        guard !Task.isCancelled else { return false }
        // A second caller joins the existing task; actor reentrancy cannot start another run.
        if let operation { return await operation.value }
        running = true
        started = Date(); triggerTime = started; triggerSource = source
        UserDefaults.standard.set(started, forKey: "syncStarted")
        UserDefaults.standard.set(started, forKey: "triggerTime")
        UserDefaults.standard.set(source, forKey: "triggerSource")
        let task = Task { @MainActor () -> Bool in
            var c = Config()
            do {
                c = try ConfigStore.load()
                let snapshot = c
                let result = try await Syncer(config: c, dir: ConfigStore.directory, log: { message in
                    Task { @MainActor in self.append(message, config: snapshot) }
                }).run(backgroundUpload: background, progress: progress)
                try Task.checkCancellation()
                self.last = Last(at: Date(), ok: true, count: result.pulled, error: "")
                self.append("同步成功：拉取 \(result.pulled)，推送 \(result.pushed)，待推送 \(result.pending)，sinceId=\(result.sinceId)", config: c)
            } catch {
                self.last = Last(at: Date(), ok: false, count: 0, error: RecentLog.safe(error is CancellationError ? "同步已取消，后台时间不足" : error.localizedDescription, config: c))
                self.append("同步失败：" + (self.last?.error ?? ""), config: c)
            }
            if let last = self.last { RecentLog.setLast(last, config: c) }
            return self.last?.ok == true
        }
        operation = task
        let result = await task.value
        operation = nil; running = false
        await refreshUploads()
        return result
    }
    func cancel() { operation?.cancel() }
    static let processIdentifier = "dev.mnemo.push.process"
    func refreshUploads() async {
        await BackgroundUploader.shared.restore()
        uploadCount = await BackgroundUploader.shared.count()
        logs = RecentLog.read()
    }
    func applyKeepAlive() {
        let controller = KeepAliveController.shared
        controller.onEvent = { [weak self] source in self?.event(source) }
        controller.onFallback = { [weak self] message in
            BackgroundSettings.tier = "省电"
            self?.notice = message
        }
        guard let c = try? ConfigStore.load() else { return }
        controller.apply(tier: BackgroundSettings.tier, enabled: c.autoSync,
                         intervalMinutes: c.intervalMinutes, stepThreshold: BackgroundSettings.steps)
    }
    func schedule() throws {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processIdentifier)
        let c = try ConfigStore.load()
        guard c.autoSync else { return }
        let date = Date().addingTimeInterval(Double(c.intervalMinutes) * 60)
        let req = BGAppRefreshTaskRequest(identifier: Self.identifier)
        req.earliestBeginDate = date
        let process = BGProcessingTaskRequest(identifier: Self.processIdentifier)
        process.requiresNetworkConnectivity = true; process.requiresExternalPower = false
        process.earliestBeginDate = date
        // Attempt both requests even when one scheduler request is rejected.
        var failure: Error?
        do { try BGTaskScheduler.shared.submit(req) } catch { failure = error }
        do { try BGTaskScheduler.shared.submit(process) } catch { failure = error }
        if let failure { throw failure }
    }
    func foreground() {
        applyKeepAlive(); KeepAliveController.shared.refreshStatus()
        Task { await refreshUploads() }
        event("前台")
    }
    func event(_ source: String) {
        guard let c = try? ConfigStore.load(), c.autoSync else { return }
        let minutes = source == "定时" ? c.intervalMinutes : BackgroundSettings.eventMinutes
        guard Date().timeIntervalSince(started ?? .distantPast) >= Double(minutes) * 60 else {
            if source != "定时" {
                throttled += 1; UserDefaults.standard.set(throttled, forKey: "throttled")
            }
            return
        }
        guard !running else { return }
        let lease = ExecutionLease { [weak self] in self?.cancel() }
        Task {
            _ = await sync(source: source, background: true)
            lease.end()
            try? schedule()
        }
    }
    func handle(_ task: BGTask) {
        let completion = BackgroundCompletion(task)
        let work = Task { @MainActor in
            // Reschedule before work so expiration also leaves a future request.
            try? self.schedule()
            let success = await self.sync(source: "定时", background: true)
            completion.finish(success)
        }
        task.expirationHandler = {
            completion.finish(false); work.cancel()
            Task { @MainActor in self.cancel() }
        }
    }
    func manual() {
        guard !running else { return }
        if #available(iOS 26.0, *) { submitContinued() }
        else { Task { _ = await sync() } }
    }
    @available(iOS 26.0, *) private func submitContinued() {
        let id = (Bundle.main.bundleIdentifier ?? "dev.mnemo.push") + ".continued." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let completion = BackgroundCompletion(continued)
                continued.progress.totalUnitCount = 100
                continued.expirationHandler = {
                    completion.finish(false)
                    Task { @MainActor in self.cancel() }
                }
                let ok = await self.sync(progress: { done, total in
                    continued.progress.totalUnitCount = total
                    continued.progress.completedUnitCount = done
                })
                completion.finish(ok)
            }
        }
        guard registered else { Task { _ = await sync() }; return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Mnemo Push 同步", subtitle: "拉取记忆并推送队列")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Task { _ = await sync() } }
    }
}
@MainActor private final class ExecutionLease {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(expiration: @escaping @MainActor () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "Mnemo event") { [weak self] in
            Task { @MainActor in expiration(); self?.end() }
        }
    }
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
    }
}
// Expiration and normal completion may race. Complete the system task exactly once.
final class BackgroundCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func finish(_ success: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; task.setTaskCompleted(success: success) }
    }
}
