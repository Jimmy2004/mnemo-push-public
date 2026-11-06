import XCTest
import MnemoCore

final class PromptParserTests: XCTestCase {
    private let token = "abcDEF123456.ZZ_placeholder-secret-0123456789abcdefXYZ"
    private var installPrompt: String {
        """
        请安装只读记忆访问。
        AGENT="claude"
        USB_LOCAL_PORT="${MNEMOSYNE_USB_LOCAL_PORT:-18723}"
        {"gatewayUrl":"http://gateway.invalid:8723","fallbackUrls":["http://fallback.invalid:8723"]}
        {"env":{"MNEMOSYNE_GATEWAY_URL":"http://gateway.invalid:9123","MNEMOSYNE_TOKEN":"\(token)","MNEMOSYNE_AGENT":"claude"}}
        """
    }
    func testExtractsTokenAgentAndPortFromInstallPrompt() {
        let p = PromptParser.parse(installPrompt)
        XCTAssertEqual(p.token, token); XCTAssertEqual(p.agent, "claude"); XCTAssertEqual(p.gatewayPort, 9123)
        XCTAssertNil(p.pushUrl); XCTAssertNil(p.pushKey)
    }
    func testExtractsPushConfigFromEnvLines() {
        let key = String(repeating: "a", count: 64)
        let p = PromptParser.parse("PUSH_URL=https://push.invalid/placeholder\nPUSH_KEY=\(key)\n")
        XCTAssertEqual(p.pushUrl, "https://push.invalid/placeholder"); XCTAssertEqual(p.pushKey, key); XCTAssertNil(p.token)
    }
    func testMergeKeepsExistingValues() {
        var c = Config(); c.token = "old.placeholder-secret"; c.pushUrl = "https://push.invalid/placeholder"; c.pushKey = "placeholder"
        let key = String(repeating: "b", count: 64)
        let merged = PromptParser.parse("PUSH_KEY=\(key)").apply(to: c)
        XCTAssertEqual(merged.token, c.token); XCTAssertEqual(merged.pushUrl, c.pushUrl); XCTAssertEqual(merged.pushKey, key)
    }
    func testUnrelatedTextIsEmptyAndSummaryHasNoSecrets() {
        XCTAssertTrue(PromptParser.parse("hello world").isEmpty)
        XCTAssertFalse(PromptParser.parse(installPrompt).summary().contains("placeholder-secret"))
    }
    func testScopeAndBoundaries() {
        let p = PromptParser.parse(installPrompt + "\nPUSH_URL=https://push.invalid/placeholder\nPUSH_KEY=" + String(repeating: "a", count: 64))
        XCTAssertFalse(p.gatewayOnly().hasPush); XCTAssertFalse(p.pushOnly().hasGateway)
        XCTAssertEqual(p.gatewayOnly().token, token); XCTAssertEqual(p.pushOnly().pushKey, p.pushKey)
        XCTAssertNil(PromptParser.parse("PUSH_URL=http://push.invalid/placeholder").pushUrl)
        XCTAssertNil(PromptParser.parse("PUSH_KEY=" + String(repeating: "a", count: 31)).pushKey)
        XCTAssertNil(PromptParser.parse("PUSH_KEY=" + String(repeating: "a", count: 129)).pushKey)
        XCTAssertNil(PromptParser.parse("MNEMOSYNE_GATEWAY_URL=http://gateway.invalid:65536").gatewayPort)
        XCTAssertEqual(PromptParser.parse("MNEMOSYNE_GATEWAY_URL=http://gateway.invalid:65535").gatewayPort, 65535)
        XCTAssertEqual(PromptParser.parse("AGENT=Other\nMNEMOSYNE_AGENT=Claude").agent, "claude")
        XCTAssertNil(PromptParser.parse("XAGENT=other").agent)
    }
    func testRedaction() {
        var c = Config(); c.token = token; c.pushKey = String(repeating: "a", count: 64)
        let parts = token.components(separatedBy: ".")
        let text = [token, parts[0], parts[1], c.pushKey].joined(separator: "\n")
        XCTAssertEqual(RecentLog.safe(text, config: c), Array(repeating: "[已隐藏]", count: 4).joined(separator: " "))
        XCTAssertEqual(RecentLog.safe(String(repeating: "x", count: 1100), config: c).count, 1000)
        XCTAssertEqual(RecentLog.safe("a\nb\rc", config: Config()), "a b c")
    }
}
