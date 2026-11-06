import Foundation

/// One owner for each queue file, shared by foreground and background uploads.
public actor BackgroundUploader {
    public static let shared = BackgroundUploader()
    private var names = Set<String>()
    private var foreground = Set<String>()
    private var restored = false
    private var restoration: Task<[URLSessionTask], Never>?
    private var completion: (() -> Void)?
    private var finishedEvents = false
    private let dir = ConfigStore.directory
    private var registry: URL { dir.appendingPathComponent("uploads.json") }
    private var bodies: URL { dir.appendingPathComponent("upload-bodies", isDirectory: true) }
    #if os(iOS)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.mnemo.push.upload")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 300
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: UploadDelegate(), delegateQueue: queue)
    }()
    #endif

    public func restore() async {
        guard !restored else { return }
        #if os(iOS)
        if restoration == nil {
            let currentSession = session
            restoration = Task {
                await withCheckedContinuation { continuation in
                    currentSession.getAllTasks { continuation.resume(returning: $0) }
                }
            }
        }
        let tasks = await restoration!.value
        guard !restored else { return }
        // The persisted list is a crash-recovery hint; system tasks are authoritative.
        if let data = try? Data(contentsOf: registry), let saved = try? JSONDecoder().decode([String].self, from: data) {
            names = Set(saved.filter(validName))
        }
        names = Set(tasks.compactMap(\.taskDescription).filter(validName))
        for task in tasks where task.state == .suspended { task.resume() }
        restored = true; restoration = nil
        persist()
        if let files = try? FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil) {
            for file in files where !names.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        #else
        restored = true
        #endif
    }
    public func activeNames() async -> Set<String> { await restore(); return names.union(foreground) }
    public func count() async -> Int { await restore(); return names.count }
    public func claim(_ name: String) async -> Bool {
        await restore()
        guard !names.contains(name), !foreground.contains(name) else { return false }
        foreground.insert(name); return true
    }
    public func release(_ name: String) { foreground.remove(name) }

    public func enqueue(config: Config, dir: URL) async throws -> Int {
        await restore()
        #if os(iOS)
        guard config.hasPush, let url = URL(string: config.pushUrl), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw SyncException("推送配置无效") }
        let queue = dir.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        var submitted = 0
        let files = try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard validName(name), !names.contains(name), !foreground.contains(name) else { continue }
            let body = try Data(contentsOf: file)
            let bodyFile = bodies.appendingPathComponent(name)
            try body.write(to: bodyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let ts = String(Int64(Date().timeIntervalSince1970))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
            request.setValue("mnemo-push/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue(ts, forHTTPHeaderField: "X-Push-Ts")
            request.setValue(Crypto.hmac(key: config.pushKey.trimmingCharacters(in: .whitespacesAndNewlines), text: Crypto.pushCanonical(timestamp: ts, body: body)), forHTTPHeaderField: "X-Push-Sig")
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            task.taskDescription = name
            names.insert(name); persist()
            task.resume(); submitted += 1
        }
        changed()
        return submitted
        #else
        return 0
        #endif
    }
    public func handleEvents(completion: @escaping () -> Void) async {
        self.completion = completion
        await restore()
        if finishedEvents { finishEvents() }
    }
    fileprivate func completed(name: String?, status: Int?, errorCode: Int?) async {
        await restore()
        guard let name, validName(name) else { return }
        let config = (try? ConfigStore.load()) ?? Config()
        if errorCode == nil && status == 200 {
            do {
                let file = dir.appendingPathComponent("queue").appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                _ = RecentLog.append("后台上传成功", config: config)
            } catch { _ = RecentLog.append("后台上传成功但队列清理失败，保留重试", config: config) }
        } else {
            let hint = status == 404 ? "；可能超过签名300秒容差，下次重新签名" : ""
            _ = RecentLog.append("后台上传未确认：HTTP \(status ?? 0)，网络错误码 \(errorCode ?? 0)\(hint)；保留队列", config: config)
        }
        names.remove(name)
        try? FileManager.default.removeItem(at: bodies.appendingPathComponent(name))
        persist(); changed()
    }
    fileprivate func finishEvents() {
        finishedEvents = true
        guard let handler = completion else { return }
        completion = nil; finishedEvents = false
        DispatchQueue.main.async { handler() }
    }
    private func validName(_ name: String) -> Bool { name == URL(fileURLWithPath: name).lastPathComponent && name.hasSuffix(".ndjson") && !name.contains("/") }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(names).sorted()).write(to: registry, options: .atomic)
        } catch {
            _ = RecentLog.append("后台上传占用状态保存失败，将在重启后与系统任务对账", config: Config())
        }
    }
    private func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("MnemoUploadChanged"), object: nil) }
    }
}
#if os(iOS)
private final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private func ordered(_ action: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        tail = Task { await previous?.value; await action() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let name = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let code = (error as NSError?)?.code
        ordered { await BackgroundUploader.shared.completed(name: name, status: status, errorCode: code) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Drain response bytes without storing or logging server response bodies.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        ordered { await BackgroundUploader.shared.finishEvents() }
    }
}
#endif
