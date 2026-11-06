import Foundation
import CryptoKit

public enum Crypto {
    public static func sha256(_ body: Data) -> String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
    public static func hmac(key: String, text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined()
    }
    public static func randomHex(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
    public static func requestCanonical(tokenID: String, timestamp: String, nonce: String, path: String, agent: String, body: String) -> String {
        ["mnemosyne-request-v1", tokenID, timestamp, nonce, "POST", path, agent, "10", body].joined(separator: "\n")
    }
    public static func responseCanonical(nonce: String, status: Int, body: String) -> String {
        ["mnemosyne-response-v1", nonce, String(status), body].joined(separator: "\n")
    }
    public static func pushCanonical(timestamp: String, body: Data) -> String { timestamp + "\n" + sha256(body) }
    public static func constantEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
