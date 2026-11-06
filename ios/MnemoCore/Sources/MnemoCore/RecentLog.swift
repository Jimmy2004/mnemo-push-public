import Foundation
public enum RecentLog {
    public struct Last: Codable {
        public let at: Date
        public let ok: Bool
        public let count: Int
        public let error: String
        public init(at: Date, ok: Bool, count: Int, error: String) {
            self.at = at; self.ok = ok; self.count = count; self.error = error
        }
    }
    private static let lock = NSLock()
    public static func read() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array((UserDefaults.standard.stringArray(forKey: "recent") ?? []).suffix(50))
    }
    public static func append(_ message: String, config: Config) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = Array(((UserDefaults.standard.stringArray(forKey: "recent") ?? []) + [f.string(from: Date()) + " " + safe(message, config: config)]).suffix(50))
        UserDefaults.standard.set(lines, forKey: "recent")
        return lines
    }
    public static func last() -> Last? {
        guard let data = UserDefaults.standard.data(forKey: "last") else { return nil }
        return try? JSONDecoder().decode(Last.self, from: data)
    }
    public static func setLast(_ last: Last, config: Config) {
        let sanitized = Last(at: last.at, ok: last.ok, count: last.count, error: safe(last.error, config: config))
        UserDefaults.standard.set(try? JSONEncoder().encode(sanitized), forKey: "last")
    }
    public static func safe(_ message: String, config: Config) -> String {
        var text = message
        let secrets = ([config.token, config.pushKey] + config.token.components(separatedBy: ".")).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        for secret in secrets { text = text.replacingOccurrences(of: secret, with: "[已隐藏]") }
        return String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(1000))
    }
}
