package dev.mnemo.push

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

object StealthLauncher {
    // AndroidManifest.xml 中两个秘密代码过滤器的 host 必须与此值一致。
    const val SECRET_CODE = "66366"
    const val DIAL_CODE = "*#*#$SECRET_CODE#*#*"

    fun markVerified(ctx: Context) {
        ctx.getSharedPreferences("mnemo_stealth", Context.MODE_PRIVATE)
            .edit().putBoolean("verified", true).apply()
    }

    fun isVerified(ctx: Context): Boolean =
        ctx.getSharedPreferences("mnemo_stealth", Context.MODE_PRIVATE).getBoolean("verified", false)

    fun apply(ctx: Context, hide: Boolean) {
        ctx.packageManager.setComponentEnabledSetting(
            ComponentName(ctx, "${ctx.packageName}.Launcher"),
            if (hide) PackageManager.COMPONENT_ENABLED_STATE_DISABLED else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
    }
}

/** 系统拨号盘输入完整秘密代码后，可在应用未运行时唤起主界面。 */
class SecretCodeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "android.provider.Telephony.SECRET_CODE" &&
            intent.action != "android.telephony.action.SECRET_CODE") return
        val uri = intent.data ?: return
        if (uri.scheme != "android_secret_code" || uri.host != StealthLauncher.SECRET_CODE) return
        StealthLauncher.markVerified(context)
        // 兼容过渡期重复广播，复用已有主界面，避免连续打开两个实例。
        context.startActivity(Intent(context, MainActivity::class.java).addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
        ))
    }
}
