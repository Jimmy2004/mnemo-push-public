package dev.mnemo.push

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object SecureStore {
    private const val ALIAS = "mnemo_push_key"
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("mnemo_config", Context.MODE_PRIVATE)

    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    /** 已保存的密钥无法解密（Keystore 被清除、数据损坏等）。 */
    class DecryptException : SyncException("已保存的通行证或推送密钥无法解密，请重新填写并保存")

    /** 未保存返回 ""；保存过但解密失败抛 DecryptException（不再静默当成“未配置”）。 */
    private fun decrypt(value: String?): String {
        if (value.isNullOrEmpty()) return ""
        return runCatching { decryptOrThrow(value) }.getOrElse { throw DecryptException() }
    }

    private fun decryptOrThrow(value: String): String = run {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        require(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }

    /** 界面用：解密失败时返回去掉密钥的配置和错误提示，让用户重新填写。 */
    fun loadForUi(ctx: Context): Pair<Config, String?> = try {
        load(ctx) to null
    } catch (e: DecryptException) {
        val p = prefs(ctx)
        Config(agent = p.getString("agent", "claude") ?: "claude", pushUrl = p.getString("pushUrl", "") ?: "",
            autoSync = p.getBoolean("autoSync", false), intervalMinutes = p.getInt("intervalMinutes", 15),
            days = p.getInt("days", 2), gatewayPort = p.getInt("gatewayPort", 8723),
            autoStart = p.getBoolean("autoStart", true), device = p.getString("device", "") ?: "",
            intervalInHours = p.getBoolean("intervalInHours", false)) to e.message
    }

    fun load(ctx: Context): Config = prefs(ctx).let {
        Config(decrypt(it.getString("token", null)), it.getString("agent", "claude") ?: "claude",
            it.getString("pushUrl", "") ?: "", decrypt(it.getString("pushKey", null)),
            it.getBoolean("autoSync", false), it.getInt("intervalMinutes", 15), it.getInt("days", 2),
            it.getInt("gatewayPort", 8723), it.getBoolean("autoStart", true), it.getString("device", "") ?: "",
            it.getBoolean("intervalInHours", false))
    }

    fun save(ctx: Context, config: Config) {
        // Encrypt both values before changing any stored configuration.
        val token = encrypt(config.token)
        val pushKey = encrypt(config.pushKey)
        check(prefs(ctx).edit().putString("token", token).putString("pushKey", pushKey)
            .putString("agent", config.agent).putString("pushUrl", config.pushUrl)
            .putBoolean("autoSync", config.autoSync).putInt("intervalMinutes", config.intervalMinutes)
            .putInt("days", config.days).putInt("gatewayPort", config.gatewayPort)
            .putBoolean("autoStart", config.autoStart).putString("device", config.device)
            .putBoolean("intervalInHours", config.intervalInHours).commit()) { "无法保存配置" }
    }
}
