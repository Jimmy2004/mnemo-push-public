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

    fun markOpened(ctx: Context) = prefs(ctx).edit().putInt("boot", bootCount(ctx)).apply()

    fun rebootedSinceOpened(ctx: Context): Boolean {
        val now = bootCount(ctx)
        val saved = prefs(ctx).getInt("boot", -1)
        return now >= 0 && saved >= 0 && now != saved
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
        val config = SecureStore.load(ctx)
        if (!config.autoStart) return
        Scheduler.apply(ctx, config)
        RecentLog.append(ctx, "开机自启：已恢复定时同步", config)
    }
}

/** 各厂商“自启动 / 后台上锁”入口与说明。 */
object Oem {
    val brand: String = Build.MANUFACTURER.lowercase()

    private val autostart = listOf(
        // OPPO / 一加 / realme（ColorOS）
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        // 小米 / 红米（MIUI / HyperOS）
        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        // 华为 / 荣耀
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        // vivo / iQOO
        ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        // 三星
        ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
    )

    /** 打开厂商自启动页面；都不可用时退回应用详情页。返回是否命中厂商页面。 */
    fun openAutostart(ctx: Context): Boolean {
        for (c in autostart) {
            val i = Intent().setComponent(c).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { ctx.startActivity(i) }.isSuccess) return true
        }
        ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return false
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
