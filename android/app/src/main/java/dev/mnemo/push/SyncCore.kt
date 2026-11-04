package dev.mnemo.push

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** 用户配置。token = "tokenId.secret"（极米记得通行证），pushKey 为 VPS 接收端密钥（hex 文本）。 */
data class Config(
    val token: String = "",
    val agent: String = "claude",
    val pushUrl: String = "",
    val pushKey: String = "",
    val autoSync: Boolean = false,
    val intervalMinutes: Int = 15,
    val days: Int = 2,
    val gatewayPort: Int = 8723,
    val autoStart: Boolean = true,
    /** 设备标识：为空表示不标（与旧版数据同一组）；多台设备推到同一 VPS 时用来区分。 */
    val device: String = "",
    /** 界面上以小时显示间隔（实际仍按分钟存储与调度）。 */
    val intervalInHours: Boolean = false,
) {
    val hasGateway get() = token.indexOf('.') in 1 until token.length - 1
    val hasPush get() = pushUrl.startsWith("https://") && pushKey.isNotBlank()
}

open class SyncException(message: String) : Exception(message)

/** 本机 mnemosyne gateway 客户端，签名方式与官方 bridge v10 一致，并校验响应签名。 */
class Gateway(config: Config, private val base: String = "http://127.0.0.1:${config.gatewayPort}") {
    private val tokenId: String
    private val secret: ByteArray
    private val agent = config.agent.trim().lowercase()

    init {
        val i = config.token.indexOf('.')
        if (i <= 0 || i == config.token.length - 1) throw SyncException("通行证格式应为 tokenId.secret")
        tokenId = config.token.substring(0, i)
        secret = config.token.substring(i + 1).toByteArray()
    }

    fun call(name: String, args: JSONObject? = null, timeoutMs: Int = 60_000): JSONObject {
        val path = "/v1/$name"
        val body = args?.toString() ?: ""
        val ts = System.currentTimeMillis().toString()
        val nonce = randomHex(32)
        val canonical = listOf("mnemosyne-request-v1", tokenId, ts, nonce, "POST", path, agent, BRIDGE_VERSION, body)
            .joinToString("\n")
        val sig = hmacHex(secret, canonical)

        val conn = URL(base + path).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = 5_000
        conn.readTimeout = timeoutMs
        conn.instanceFollowRedirects = false
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        conn.setRequestProperty("X-Mnemosyne-Agent", agent)
        conn.setRequestProperty("X-Mnemosyne-Bridge", BRIDGE_VERSION)
        conn.setRequestProperty("X-Mnemosyne-Request-Auth", listOf("v1", tokenId, ts, nonce, sig).joinToString(":"))
        try {
            conn.outputStream.use { it.write(body.toByteArray()) }
            val status = conn.responseCode
            val text = (if (status < 400) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use { it.readText() } ?: ""
            val got = conn.getHeaderField("X-Mnemosyne-Response-Auth") ?: ""
            val expect = hmacHex(secret, listOf("mnemosyne-response-v1", nonce, status.toString(), text).joinToString("\n"))
            if (!MessageDigest.isEqual(expect.toByteArray(), got.toByteArray())) {
                throw SyncException("$name：响应签名校验失败（HTTP $status），请检查通行证和 agent")
            }
            if (status != 200) throw SyncException("$name：HTTP $status ${text.take(200)}")
            return JSONObject(text)
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val BRIDGE_VERSION = "10"
    }
}

/** 拉取 + 本地队列 + 推送。state 只保存 transcriptSinceId。 */
class Syncer(private val config: Config, private val dir: File, private val log: (String) -> Unit = {}) {
    private val queue = File(dir, "queue").apply { mkdirs() }
    private val stateFile = File(dir, "state.json")

    data class Result(val pulled: Int, val pushed: Int, val pending: Int, val sinceId: Long)

    /** days = 0 表示全部：首次拉取全部历史，之后会议/记忆等按最近 2 天窗口增量。 */
    private fun windowDays(firstRun: Boolean) = when {
        config.days > 0 -> config.days
        firstRun -> ALL_DAYS
        else -> 2
    }

    fun run(): Result {
        // 拉取失败（如 gateway 未运行）时，仍先把已排队的数据推出去，再抛出原错误
        val pullResult = if (config.hasGateway) runCatching { pull() } else kotlin.Result.success(0)
        val pushed = if (config.hasPush) push() else 0
        val pulled = pullResult.getOrThrow()
        val pending = queue.listFiles { x -> x.name.endsWith(".ndjson") }?.size ?: 0
        return Result(pulled, pushed, pending, loadSinceId())
    }

    /** 只测试网关连通和签名。 */
    fun ping() { Gateway(config).call("ping", timeoutMs = 5_000) }

    /** 测试 VPS 推送地址与密钥，返回往返延迟（毫秒）。 */
    fun pingPush(): Long {
        if (!config.hasPush) throw SyncException("请填写 https:// 开头的 PUSH_URL 和 PUSH_KEY")
        val body = "ping:${randomHex(16)}".toByteArray()
        val start = System.nanoTime()
        val code = post(body, 10_000)
        val ms = (System.nanoTime() - start) / 1_000_000
        if (code != 200) throw SyncException("HTTP $code${hint(code)}")
        return ms
    }

    private fun loadSinceId(): Long =
        runCatching { JSONObject(stateFile.readText()).optLong("transcript_since_id", 0) }.getOrDefault(0)

    private fun saveSinceId(id: Long) = stateFile.writeText(JSONObject().put("transcript_since_id", id).toString())

    private fun pull(): Int {
        val gw = Gateway(config)
        val items = mutableListOf<JSONObject>()
        gw.call("ping", timeoutMs = 5_000)

        var since = loadSinceId()
        val days = windowDays(firstRun = since == 0L)
        while (true) {
            val args = JSONObject().put("fullText", true).put("limit", 200).put("maxChars", 200_000)
            if (since > 0) args.put("sinceId", since) else args.put("days", days)
            val page = results(gw.call("get_transcripts", args, 180_000))
            if (page.isEmpty()) break
            items += page
            val newest = page.maxOf { it.optLong("id", 0) }
            if (newest <= since) break
            since = newest
        }

        for (src in listOf("meetings", "memories", "timeline_cards")) {
            var offset = 0
            while (true) {
                val args = JSONObject().put("sources", JSONArray().put(src)).put("days", days)
                    .put("limit", 100).put("offset", offset).put("maxChars", 100_000)
                val page = results(gw.call("search_evidence", args, 90_000))
                items += page
                if (page.size < 100) break
                offset += 100
            }
        }
        items += results(gw.call("get_open_loops", JSONObject().put("days", days).put("limit", 200), 15_000))

        val device = config.device.trim()
        if (device.isNotEmpty()) items.forEach { it.put("device", device) }
        if (items.isNotEmpty()) {
            // 毫秒时间戳（定长，保证排序）+ UUID，永不覆盖；先写 .tmp 再原子改名，成功后才推进游标
            val name = "%013d-%s".format(System.currentTimeMillis(), java.util.UUID.randomUUID())
            val tmp = File(queue, "$name.tmp")
            tmp.writeText(items.joinToString("") { it.toString() + "\n" })
            if (!tmp.renameTo(File(queue, "$name.ndjson"))) { tmp.delete(); throw java.io.IOException("队列写入失败") }
        }
        saveSinceId(since)
        log("拉取 ${items.size} 条，transcript_since_id=$since")
        return items.size
    }

    private fun push(): Int {
        var n = 0
        for (f in queue.listFiles { x -> x.name.endsWith(".ndjson") }.orEmpty().sortedBy { it.name }) {
            val code = post(f.readBytes(), 60_000)
            if (code != 200) throw SyncException("推送 ${f.name} 失败：HTTP $code${hint(code)}")
            f.delete()
            n++
            log("已推送 ${f.name}")
        }
        return n
    }

    private fun post(body: ByteArray, readTimeout: Int): Int {
        val ts = (System.currentTimeMillis() / 1000).toString()
        val sig = hmacHex(config.pushKey.trim().toByteArray(), ts + "\n" + sha256Hex(body))
        val conn = URL(config.pushUrl.trim()).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 15_000
            conn.readTimeout = readTimeout
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/x-ndjson")
            conn.setRequestProperty("User-Agent", "mnemo-push/1.0")
            conn.setRequestProperty("X-Push-Ts", ts)
            conn.setRequestProperty("X-Push-Sig", sig)
            conn.outputStream.use { it.write(body) }
            return conn.responseCode
        } finally {
            conn.disconnect()
        }
    }

    companion object { const val ALL_DAYS = 3650 }

    private fun hint(code: Int) = when (code) {
        403 -> "（可能被 Cloudflare 拦截）"
        404 -> "（URL 路径或推送密钥不对，或手机时间不准）"
        409 -> "（重放被拒绝）"
        else -> ""
    }

    private fun results(o: JSONObject): List<JSONObject> {
        val a = o.optJSONArray("results") ?: return emptyList()
        return (0 until a.length()).mapNotNull { a.optJSONObject(it) }
    }
}

private val rng = SecureRandom()
private fun randomHex(bytes: Int) = ByteArray(bytes).also { rng.nextBytes(it) }.toHex()
private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
private fun sha256Hex(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).toHex()
private fun hmacHex(key: ByteArray, text: String): String {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    return mac.doFinal(text.toByteArray()).toHex()
}
