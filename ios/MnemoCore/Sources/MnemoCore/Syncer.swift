import Foundation

public struct SyncResult {
    public let pulled: Int
    public let pushed: Int
    public let pending: Int
    public let sinceId: Int64
}
public final class Syncer {
    public static let ALL_DAYS = 3650
    private let config: Config
    private let dir: URL
    private let log: @Sendable (String) -> Void
    private var queue: URL { dir.appendingPathComponent("queue", isDirectory: true) }
    private var state: URL { dir.appendingPathComponent("state.json") }
    public init(config: Config, dir: URL, log: @escaping @Sendable (String) -> Void = { _ in }) { self.config = config; self.dir = dir; self.log = log }
    private func files() throws -> [URL] {
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ndjson" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func sinceID() -> Int64 {
        guard let data = try? Data(contentsOf: state),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return (obj["transcript_since_id"] as? NSNumber)?.int64Value ?? 0
    }
    public func run(backgroundUpload: Bool = false, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> SyncResult {
        progress(0, 100)
        await BackgroundUploader.shared.restore()
        if backgroundUpload && config.hasPush { _ = try await BackgroundUploader.shared.enqueue(config: config, dir: dir) }
        _ = try files()
        var pulled = 0
        var pullError: Error?
        if config.hasGateway {
            do { pulled = try await pull(progress: progress) }
            catch { if Task.isCancelled { throw CancellationError() }; pullError = error }
        }
        progress(70, 100)
        let pushed: Int
        if backgroundUpload && config.hasPush {
            _ = try await BackgroundUploader.shared.enqueue(config: config, dir: dir)
            pushed = 0 // Handed to the system; delegate confirmation is authoritative.
        } else { pushed = config.hasPush ? try await push(progress: progress) : 0 }
        progress(100, 100)
        if let pullError { throw pullError }
        return SyncResult(pulled: pulled, pushed: pushed, pending: try files().count, sinceId: sinceID())
    }
    public func ping() async throws { _ = try await Gateway(config).call("ping", timeout: 5) }
    public func pingPush() async throws -> Int64 {
        guard config.hasPush else { throw SyncException("请填写 https:// 开头的 PUSH_URL 和 PUSH_KEY") }
        let body = Data(("ping:" + Crypto.randomHex(bytes: 16)).utf8)
        let start = DispatchTime.now().uptimeNanoseconds
        let code = try await post(body, timeout: 10)
        let ms = Int64((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        guard code == 200 else { throw SyncException("HTTP \(code)\(hint(code))") }
        return ms
    }
    private func results(_ obj: [String: Any]) -> [[String: Any]] { (obj["results"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
    private func pull(progress: @Sendable (Int64, Int64) -> Void) async throws -> Int {
        var pages: Int64 = 0
        func advanced() { pages += 1; progress(min(65, 5 + pages), 100) }
        let gw = Gateway(config)
        _ = try await gw.call("ping", timeout: 5)
        var since = sinceID()
        let days = config.days > 0 ? config.days : (since == 0 ? Self.ALL_DAYS : 2)
        var items: [[String: Any]] = []
        while true {
            try Task.checkCancellation()
            var args: [String: Any] = ["fullText": true, "limit": 200, "maxChars": 200_000]
            if since > 0 { args["sinceId"] = since } else { args["days"] = days }
            let page = results(try await gw.call("get_transcripts", args: args, timeout: 180))
            if page.isEmpty { break }
            items += page
            advanced()
            let newest = page.map { ($0["id"] as? NSNumber)?.int64Value ?? 0 }.max() ?? 0
            if newest <= since { break }
            since = newest
        }
        for src in ["meetings", "memories", "timeline_cards"] {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = results(try await gw.call("search_evidence", args: ["sources": [src], "days": days, "limit": 100, "offset": offset, "maxChars": 100_000], timeout: 90))
                items += page
                advanced()
                if page.count < 100 { break }
                offset += 100
            }
        }
        items += results(try await gw.call("get_open_loops", args: ["days": days, "limit": 200], timeout: 15))
        let device = config.device.trimmingCharacters(in: .whitespacesAndNewlines)
        if !device.isEmpty { for i in items.indices { items[i]["device"] = device } }
        try Task.checkCancellation()
        if !items.isEmpty {
            let name = String(format: "%013lld", Int64(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString
            let tmp = queue.appendingPathComponent(name + ".tmp")
            var data = Data()
            for item in items {
                data.append(try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes]))
                data.append(10)
            }
            do {
                try data.write(to: tmp)
                try FileManager.default.moveItem(at: tmp, to: queue.appendingPathComponent(name + ".ndjson"))
            } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        }
        try JSONSerialization.data(withJSONObject: ["transcript_since_id": since]).write(to: state, options: .atomic)
        log(RecentLog.safe("拉取 \(items.count) 条，transcript_since_id=\(since)", config: config))
        return items.count
    }
    private func push(progress: @Sendable (Int64, Int64) -> Void) async throws -> Int {
        var n = 0
        let pending = try files()
        for file in pending {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard await BackgroundUploader.shared.claim(name) else { continue }
            do {
                let code = try await post(Data(contentsOf: file), timeout: 60)
                guard code == 200 else { throw SyncException("推送 \(file.lastPathComponent) 失败：HTTP \(code)\(hint(code))") }
                try FileManager.default.removeItem(at: file)
                n += 1
                progress(70 + Int64(n * 30 / max(1, pending.count)), 100)
                log(RecentLog.safe("已推送 \(file.lastPathComponent)", config: config))
                await BackgroundUploader.shared.release(name)
            } catch { await BackgroundUploader.shared.release(name); throw error }
        }
        return n
    }
    private func post(_ body: Data, timeout: TimeInterval) async throws -> Int {
        guard let url = URL(string: config.pushUrl.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil else { throw SyncException("必须以 https:// 开头") }
        let ts = String(Int64(Date().timeIntervalSince1970))
        let key = config.pushKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = timeout
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.setValue("mnemo-push/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(ts, forHTTPHeaderField: "X-Push-Ts")
        req.setValue(Crypto.hmac(key: key, text: Crypto.pushCanonical(timestamp: ts, body: body)), forHTTPHeaderField: "X-Push-Sig")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout + 15
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SyncException("推送响应无效") }
        return http.statusCode
    }
    private func hint(_ code: Int) -> String {
        switch code {
        case 403: return "（可能被 Cloudflare 拦截）"
        case 404: return "（URL 路径或推送密钥不对，或手机时间不准）"
        case 409: return "（重放被拒绝）"
        default: return ""
        }
    }
}
