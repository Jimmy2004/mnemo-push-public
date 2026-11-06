import Foundation

public struct SyncException: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Config: Codable, Sendable {
    public var token = ""
    public var agent = "claude"
    public var pushUrl = ""
    public var pushKey = ""
    public var autoSync = false
    public var intervalMinutes = 15
    public var days = 2
    public var gatewayPort = 8723
    public var device = ""
    public var intervalInHours = false
    public init() {}
    public var hasGateway: Bool {
        guard let dot = token.firstIndex(of: ".") else { return false }
        return dot != token.startIndex && token.index(after: dot) != token.endIndex
    }
    public var hasPush: Bool { pushUrl.hasPrefix("https://") && !pushKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public func validated() throws -> Config {
        var c = self
        c.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        c.agent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.agent.isEmpty { c.agent = "claude" }
        c.pushUrl = pushUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        c.pushKey = pushKey.trimmingCharacters(in: .whitespacesAndNewlines)
        c.device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (15...1440).contains(c.intervalMinutes) else { throw SyncException("同步间隔须为 15–1440 分钟") }
        guard (1...65535).contains(c.gatewayPort) else { throw SyncException("端口须为 1–65535") }
        guard (0...3650).contains(c.days) else { throw SyncException("首次拉取天数须为 0–3650") }
        guard c.device.range(of: "^[A-Za-z0-9_.-]{0,32}$", options: .regularExpression) != nil else { throw SyncException("设备标识限字母数字 -_.，最多 32 位") }
        if !c.pushUrl.isEmpty {
            guard let u = URL(string: c.pushUrl), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { throw SyncException("必须以 https:// 开头") }
        }
        return c
    }
}
