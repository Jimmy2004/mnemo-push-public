package dev.mnemo.push

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/** 记录用户最近一次打开应用时的开机次数，用于“关闭自启动”时判断是否重启过。 */
object BootGuard {
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("mnemo_boot", Context.MODE_PRIVATE)
    private fun bootCount(ctx: Context) =
        runCatching { Settings.Global.getInt(ctx.contentResolver, Settings.Global.BOOT_COUNT) }.getOrDefault(-1)

    private fun bootWallMs() = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime()

    fun markOpened(ctx: Context) =
        prefs(ctx).edit().putInt("boot", bootCount(ctx)).putLong("bootWall", bootWallMs()).apply()

    fun rebootedSinceOpened(ctx: Context): Boolean {
        val p = prefs(ctx)
        val now = bootCount(ctx)
        val saved = p.getInt("boot", -1)
        if (now >= 0 && saved >= 0) return now != saved
        // 备用：开机时刻偏差超过 2 分钟视为重启（容忍校时漂移）
        val savedWall = p.getLong("bootWall", -1)
        if (savedWall > 0) return kotlin.math.abs(bootWallMs() - savedWall) > 120_000
        return true   // 无法判断：保守暂停，打开应用后恢复
    }

    /** 开关决定是否接收开机广播。 */
    fun setReceiverEnabled(ctx: Context, enabled: Boolean) {
        ctx.packageManager.setComponentEnabledSetting(
            ComponentName(ctx, BootReceiver::class.java),
            if (enabled) android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            android.content.pm.PackageManager.DONT_KILL_APP)
    }
}

/** 开机或应用更新后重新登记定时同步（开启“自启动”时才会收到）。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val config = runCatching { SecureStore.load(ctx) }.getOrElse {
            RecentLog.append(ctx, "开机自启：${it.message}"); return
        }
        if (!config.autoStart) return
        Scheduler.apply(ctx, config)
        if (config.autoSync) RecentLog.append(ctx, "开机自启：已恢复定时同步", config)
    }
}

/** 各厂商“自启动 / 后台上锁”入口与说明。 */
object Oem {
    val brand: String = Build.MANUFACTURER.lowercase()

    private fun c(pkg: String, cls: String) = ComponentName(pkg, cls)

    /** 仅自启动管理页面，按品牌分组，避免误开其它厂商或无关页面。 */
    private val autostart: Map<Set<String>, List<ComponentName>> = mapOf(
        setOf("oppo", "oneplus", "realme") to listOf(
            c("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            c("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            c("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
            c("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
        setOf("xiaomi", "redmi", "poco") to listOf(
            c("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
        setOf("huawei", "honor") to listOf(
            c("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            c("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
        setOf("vivo", "iqoo") to listOf(
            c("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            c("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager")),
    )

    enum class Opened { AUTOSTART_PAGE, APP_DETAILS, NONE }

    /** 先尝试本品牌的自启动页；失败则打开应用详情页；都失败返回 NONE。 */
    fun openAutostart(ctx: Context): Opened {
        val pm = ctx.packageManager
        val candidates = autostart.entries.firstOrNull { brand in it.key }?.value.orEmpty()
        for (comp in candidates) {
            val i = Intent().setComponent(comp).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (i.resolveActivity(pm) == null) continue
            if (runCatching { ctx.startActivity(i) }.isSuccess) return Opened.AUTOSTART_PAGE
        }
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (runCatching { ctx.startActivity(details) }.isSuccess) Opened.APP_DETAILS else Opened.NONE
    }

    fun autostartSteps(): String = when {
        brand in setOf("oppo", "oneplus", "realme") ->
            "设置 → 应用 → 自启动 → 打开 Mnemo Push；\n另在 设置 → 电池 → 应用耗电管理 → Mnemo Push 中允许「后台运行」和「自启动」。"
        brand in setOf("xiaomi", "redmi", "poco") ->
            "安全中心 → 应用管理 → 权限 → 自启动管理 → 打开 Mnemo Push；\n应用详情 → 省电策略 → 选择「无限制」。"
        brand in setOf("huawei", "honor") ->
            "设置 → 电池 → 应用启动管理 → Mnemo Push 关闭「自动管理」，并打开「允许自启动」「允许后台活动」。"
        brand in setOf("vivo", "iqoo") ->
            "i 管家 → 应用管理 → 权限管理 → 自启动 → 打开 Mnemo Push；\n设置 → 电池 → 后台耗电管理 → 允许后台高耗电。"
        brand == "samsung" ->
            "设置 → 电池 → 后台使用限制 → 将 Mnemo Push 加入「从不休眠的应用」。"
        else -> "在系统设置中找到 Mnemo Push，允许自启动 / 后台运行，并将电池设为不受限制。"
    }

    fun lockSteps(): String = when {
        brand in setOf("oppo", "oneplus", "realme") -> "打开最近任务，长按 Mnemo Push 卡片（或点卡片右上角 ⋮），选择「锁定」。"
        brand in setOf("xiaomi", "redmi", "poco") -> "打开最近任务，长按 Mnemo Push 卡片，点小锁图标。"
        brand in setOf("huawei", "honor") -> "打开最近任务，将 Mnemo Push 卡片向下拖动，出现锁图标即锁定。"
        brand in setOf("vivo", "iqoo") -> "打开最近任务，长按或下拉 Mnemo Push 卡片，选择「锁定」。"
        brand == "samsung" -> "打开最近任务，点 Mnemo Push 图标，选择「保持打开」。"
        else -> "打开最近任务，长按 Mnemo Push 卡片，找到「锁定」或小锁图标。"
    }
}
