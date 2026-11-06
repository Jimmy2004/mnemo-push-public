import Foundation
import Security

public enum ConfigStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.mnemo.push", kSecAttrAccount as String: account]
    }
    static func secret(_ name: String) throws -> String {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else { throw SyncException("无法读取密钥，请解锁设备后重试") }
        return s
    }
    private static func put(_ name: String, _ value: String) throws {
        let q = query(name)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; attrs.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SyncException("保存密钥失败") }
        } else if status != errSecSuccess { throw SyncException("保存密钥失败") }
    }
    public static func load() throws -> Config {
        var c = Config()
        if let data = UserDefaults.standard.data(forKey: "config") { c = try JSONDecoder().decode(Config.self, from: data) }
        c.token = try secret("token"); c.pushKey = try secret("pushKey")
        return c
    }
    public static func save(_ config: Config) throws {
        let c = try config.validated()
        try put("token", c.token); try put("pushKey", c.pushKey)
        var publicConfig = c; publicConfig.token = ""; publicConfig.pushKey = ""
        UserDefaults.standard.set(try JSONEncoder().encode(publicConfig), forKey: "config")
    }
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mnemo", isDirectory: true)
    }
}
