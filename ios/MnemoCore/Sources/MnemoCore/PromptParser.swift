import Foundation
public struct ParsedPrompt {
    public var token: String?
    public var agent: String?
    public var gatewayPort: Int?
    public var pushUrl: String?
    public var pushKey: String?
    public var isEmpty: Bool { !hasGateway && !hasPush }
    public var hasGateway: Bool { token != nil || agent != nil || gatewayPort != nil }
    public var hasPush: Bool { pushUrl != nil || pushKey != nil }
    public func summary() -> String {
        var s: [String] = []
        if token != nil { s.append("通行证") }
        if let agent { s.append("agent=\(agent)") }
        if let gatewayPort { s.append("端口=\(gatewayPort)") }
        if pushUrl != nil { s.append("PUSH_URL") }
        if pushKey != nil { s.append("PUSH_KEY") }
        return s.joined(separator: "、")
    }
    public func gatewayOnly() -> ParsedPrompt { ParsedPrompt(token: token, agent: agent, gatewayPort: gatewayPort) }
    public func pushOnly() -> ParsedPrompt { ParsedPrompt(pushUrl: pushUrl, pushKey: pushKey) }
    public func apply(to c: Config) -> Config {
        var c = c
        c.token = token ?? c.token; c.agent = agent ?? c.agent; c.gatewayPort = gatewayPort ?? c.gatewayPort
        c.pushUrl = pushUrl ?? c.pushUrl; c.pushKey = pushKey ?? c.pushKey
        return c
    }
}
public enum PromptParser {
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    private static func field(_ text: String, _ key: String, _ value: String) -> String? {
        let k = NSRegularExpression.escapedPattern(for: key)
        return capture(text, "\"" + k + "\"\\s*:\\s*\"(" + value + ")\"")
            ?? capture(text, "(?<![A-Za-z0-9_])" + k + "\\s*=\\s*[\"']?(" + value + ")[\"']?(?=[\\s;\"']|$)")
    }
    public static func parse(_ text: String) -> ParsedPrompt {
        let token = field(text, "MNEMOSYNE_TOKEN", "[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{8,}")
        let agent = (field(text, "MNEMOSYNE_AGENT", "[A-Za-z0-9_-]{1,32}") ?? field(text, "AGENT", "[A-Za-z0-9_-]{1,32}"))?.lowercased()
        let url = field(text, "MNEMOSYNE_GATEWAY_URL", "https?://[^\\s\"']+") ?? field(text, "gatewayUrl", "https?://[^\\s\"']+")
        let port = url.flatMap { capture($0, "^https?://[^/:]+:(\\d{1,5})") }.flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
        return ParsedPrompt(token: token, agent: agent, gatewayPort: port, pushUrl: field(text, "PUSH_URL", "https://[^\\s\"']+"), pushKey: field(text, "PUSH_KEY", "[A-Fa-f0-9]{32,128}"))
    }
}
