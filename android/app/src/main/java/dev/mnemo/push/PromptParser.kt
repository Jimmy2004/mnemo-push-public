package dev.mnemo.push

/**
 * 从「极米记得」安装提示词（或任意粘贴文本）里提取配置。只做文本匹配，不执行任何内容。
 *
 * 识别：
 *  - MNEMOSYNE_TOKEN："MNEMOSYNE_TOKEN":"id.secret" / MNEMOSYNE_TOKEN=id.secret
 *  - MNEMOSYNE_AGENT 或 AGENT="..."
 *  - 网关端口：MNEMOSYNE_GATEWAY_URL / gatewayUrl 里的端口（手机本机始终用 127.0.0.1）
 *  - PUSH_URL / PUSH_KEY（例如从 VPS 输出整段粘贴）
 * 未识别到的字段为 null，调用方保留原值。
 */
data class ParsedPrompt(
    val token: String? = null,
    val agent: String? = null,
    val gatewayPort: Int? = null,
    val pushUrl: String? = null,
    val pushKey: String? = null,
) {
    val isEmpty get() = listOf(token, agent, gatewayPort, pushUrl, pushKey).all { it == null }

    /** 给用户看的摘要，不含任何密钥内容。 */
    fun summary(): String = buildList {
        if (token != null) add("通行证")
        if (agent != null) add("agent=$agent")
        if (gatewayPort != null) add("端口=$gatewayPort")
        if (pushUrl != null) add("PUSH_URL")
        if (pushKey != null) add("PUSH_KEY")
    }.joinToString("、")

    val hasGateway get() = token != null || agent != null || gatewayPort != null
    val hasPush get() = pushUrl != null || pushKey != null
    fun gatewayOnly() = copy(pushUrl = null, pushKey = null)
    fun pushOnly() = ParsedPrompt(pushUrl = pushUrl, pushKey = pushKey)

    fun applyTo(c: Config) = c.copy(
        token = token ?: c.token,
        agent = agent ?: c.agent,
        gatewayPort = gatewayPort ?: c.gatewayPort,
        pushUrl = pushUrl ?: c.pushUrl,
        pushKey = pushKey ?: c.pushKey,
    )
}

object PromptParser {
    // "KEY":"value"  或  KEY=value / KEY="value"
    private fun field(text: String, key: String, value: String): String? {
        val k = Regex.escape(key)
        val json = Regex("\"$k\"\\s*:\\s*\"($value)\"")
        val env = Regex("(?<![A-Za-z0-9_])$k\\s*=\\s*[\"']?($value)[\"']?(?=[\\s;\"']|$)", RegexOption.MULTILINE)
        return json.find(text)?.groupValues?.get(1) ?: env.find(text)?.groupValues?.get(1)
    }

    private const val TOKEN = "[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{8,}"
    private const val AGENT = "[A-Za-z0-9_-]{1,32}"
    private const val URL = "https?://[^\\s\"']+"

    fun parse(text: String): ParsedPrompt {
        val token = field(text, "MNEMOSYNE_TOKEN", TOKEN)
        val agent = (field(text, "MNEMOSYNE_AGENT", AGENT) ?: field(text, "AGENT", AGENT))?.lowercase()
        val gatewayUrl = field(text, "MNEMOSYNE_GATEWAY_URL", URL) ?: field(text, "gatewayUrl", URL)
        val port = gatewayUrl?.let { Regex("^https?://[^/:]+:(\\d{1,5})").find(it)?.groupValues?.get(1)?.toIntOrNull() }
            ?.takeIf { it in 1..65535 }
        val pushUrl = field(text, "PUSH_URL", "https://[^\\s\"']+")
        val pushKey = field(text, "PUSH_KEY", "[A-Fa-f0-9]{32,128}")
        return ParsedPrompt(token, agent, port, pushUrl, pushKey)
    }
}
