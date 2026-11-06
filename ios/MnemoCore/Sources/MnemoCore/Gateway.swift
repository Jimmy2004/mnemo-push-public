import Foundation

// Never follow redirects: local authentication headers must stay on loopback.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class Gateway {
    public static let BRIDGE_VERSION = "10"
    private let config: Config
    public init(_ config: Config) { self.config = config }
    public func call(_ name: String, args: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard config.hasGateway, let dot = config.token.firstIndex(of: "."),
              (1...65535).contains(config.gatewayPort),
              ["ping", "get_transcripts", "search_evidence", "get_open_loops"].contains(name) else { throw SyncException("通行证格式应为 tokenId.secret，或网关配置无效") }
        let id = String(config.token[..<dot]), secret = String(config.token[config.token.index(after: dot)...])
        let path = "/v1/" + name
        let body = try args.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) } ?? Data()
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000)), nonce = Crypto.randomHex(bytes: 32)
        let agent = config.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let canonical = Crypto.requestCanonical(tokenID: id, timestamp: ts, nonce: nonce, path: path, agent: agent, body: String(decoding: body, as: UTF8.self))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.gatewayPort)" + path)!)
        req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(agent, forHTTPHeaderField: "X-Mnemosyne-Agent")
        req.setValue(Self.BRIDGE_VERSION, forHTTPHeaderField: "X-Mnemosyne-Bridge")
        req.setValue(["v1", id, ts, nonce, Crypto.hmac(key: secret, text: canonical)].joined(separator: ":"), forHTTPHeaderField: "X-Mnemosyne-Request-Auth")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SyncException("网关响应无效") }
        let text = String(decoding: data, as: UTF8.self)
        let expect = Crypto.hmac(key: secret, text: Crypto.responseCanonical(nonce: nonce, status: http.statusCode, body: text))
        guard Crypto.constantEqual(expect, http.value(forHTTPHeaderField: "X-Mnemosyne-Response-Auth") ?? "") else { throw SyncException("\(name)：响应签名校验失败（HTTP \(http.statusCode)），请检查通行证和 agent") }
        guard http.statusCode == 200 else { throw SyncException("\(name)：HTTP \(http.statusCode) \(text.prefix(200))") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncException("网关响应格式无效") }
        return obj
    }
}
