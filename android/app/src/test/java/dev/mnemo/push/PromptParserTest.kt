package dev.mnemo.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// 全部使用伪造的通行证，结构与极米记得安装提示词一致
class PromptParserTest {
    private val fakeToken = "abcDEF123456.ZZ_fake-secret-0123456789abcdefXYZ"

    private val installPrompt = """
        请为这张 Claude 记忆通行证安装 极米记得 原生记忆访问（只读、本地局域网）。
        ```bash
        set -eu
        AGENT="claude"
        USB_LOCAL_PORT="${'$'}{MNEMOSYNE_USB_LOCAL_PORT:-18723}"
        if ! curl --noproxy "*" -fsS --max-time 8 "http://192.168.1.57:8723/v1/bridge.mjs" -o x; then :; fi
        printf '{"gatewayUrl":"http://192.168.1.57:8723","fallbackUrls":["http://127.0.0.1:8723"]}\n' > g.json
        cat > "${'$'}TMP/mcp-config.json" <<EOF
        {"mcpServers":{"mnemosyne-memory":{"command":"node","args":["index.mjs"],"env":{"MNEMOSYNE_GATEWAY_URL":"http://192.168.1.57:9123","MNEMOSYNE_TOKEN":"$fakeToken","MNEMOSYNE_AGENT":"claude"}}}}
        EOF
        ```
        这张通行证只绑定 Claude。
    """.trimIndent()

    @Test fun extractsTokenAgentAndPortFromInstallPrompt() {
        val p = PromptParser.parse(installPrompt)
        assertEquals(fakeToken, p.token)
        assertEquals("claude", p.agent)
        assertEquals(9123, p.gatewayPort)   // 来自 MNEMOSYNE_GATEWAY_URL，而不是 USB 的 18723
        assertNull(p.pushUrl)
        assertNull(p.pushKey)
    }

    @Test fun extractsPushConfigFromEnvLines() {
        val key = "a".repeat(64)
        val p = PromptParser.parse("PUSH_URL=https://example.org/abc_DEF-123\nPUSH_KEY=$key\n")
        assertEquals("https://example.org/abc_DEF-123", p.pushUrl)
        assertEquals(key, p.pushKey)
        assertNull(p.token)
    }

    @Test fun mergeKeepsExistingValues() {
        val old = Config(token = "old.tokenvalue1", pushUrl = "https://x.org/p", pushKey = "k")
        val merged = PromptParser.parse("PUSH_KEY=${"b".repeat(64)}").applyTo(old)
        assertEquals("old.tokenvalue1", merged.token)
        assertEquals("https://x.org/p", merged.pushUrl)
        assertEquals("b".repeat(64), merged.pushKey)
    }

    @Test fun unrelatedTextIsEmptyAndSummaryHasNoSecrets() {
        assertTrue(PromptParser.parse("hello world").isEmpty)
        assertTrue(!PromptParser.parse(installPrompt).summary().contains("fake-secret"))
    }
}
