import XCTest
import MnemoCore

// Expected digests computed with Python hashlib/hmac; these tests have not been run.
final class CryptoTests: XCTestCase {
    func testGatewayRequestVector() {
        let canonical = Crypto.requestCanonical(tokenID: "placeholderID", timestamp: "1700000000123", nonce: String(repeating: "0123456789abcdef", count: 4), path: "/v1/ping", agent: "claude", body: "")
        XCTAssertEqual(Crypto.hmac(key: "placeholder-secret", text: canonical), "b5bb5fdcfefa10d9f475291c9a568b2b4a7376a21e48c8741197f26088fa95b5")
        XCTAssertTrue(canonical.hasSuffix("\n10\n"))
    }
    func testGatewayResponseVector() {
        let canonical = Crypto.responseCanonical(nonce: String(repeating: "0123456789abcdef", count: 4), status: 200, body: #"{"ok":true}"#)
        XCTAssertEqual(Crypto.hmac(key: "placeholder-secret", text: canonical), "3ee59b615b3806a6541cab0e99076052efc544e50f5b01620fa482fb03eb4a57")
    }
    func testPushVectorUsesHexTextKey() {
        let body = Data(("ping:" + String(repeating: "0123456789abcdef", count: 2)).utf8)
        let canonical = Crypto.pushCanonical(timestamp: "1700000000", body: body)
        XCTAssertEqual(Crypto.sha256(body), "12103d0cc81cb8f902598d2a81faed2886ce966116ab977dd031ebfa37fff7a7")
        XCTAssertEqual(Crypto.hmac(key: String(repeating: "a", count: 64), text: canonical), "ac394af3b0a961b659494e256f81f2d8cca63ce411a275bd4a947cb916920832")
    }
    func testSHAAndComparison() {
        XCTAssertEqual(Crypto.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(Crypto.constantEqual("abc", "abc"))
        XCTAssertFalse(Crypto.constantEqual("abc", "abd"))
        XCTAssertFalse(Crypto.constantEqual("abc", "ab"))
    }
}
