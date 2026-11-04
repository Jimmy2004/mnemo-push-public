package dev.mnemo.push

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.lifecycle.lifecycleScope
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.android.material.button.MaterialButton
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.floatingactionbutton.ExtendedFloatingActionButton
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.snackbar.Snackbar
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {
    private lateinit var token: TextInputEditText
    private lateinit var agent: TextInputEditText
    private lateinit var port: TextInputEditText
    private lateinit var pushUrl: TextInputEditText
    private lateinit var pushKey: TextInputEditText
    private lateinit var days: TextInputEditText
    private lateinit var autoSync: MaterialSwitch
    private lateinit var autoStart: MaterialSwitch
    private lateinit var interval: MaterialButtonToggleGroup
    private lateinit var logs: TextView
    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var battery: MaterialButton
    private val intervalIds = mapOf(15 to R.id.i15, 30 to R.id.i30, 60 to R.id.i60)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContentView(R.layout.activity_main)

        token = findViewById(R.id.token); agent = findViewById(R.id.agent); port = findViewById(R.id.port)
        pushUrl = findViewById(R.id.pushUrl); pushKey = findViewById(R.id.pushKey); days = findViewById(R.id.days)
        autoSync = findViewById(R.id.autoSync); autoStart = findViewById(R.id.autoStart)
        interval = findViewById(R.id.interval); logs = findViewById(R.id.logs)
        statusTitle = findViewById(R.id.statusTitle); statusDetail = findViewById(R.id.statusDetail)
        battery = findViewById(R.id.battery)

        val save = findViewById<ExtendedFloatingActionButton>(R.id.save)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.root)) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime()
                or WindowInsetsCompat.Type.displayCutout())
            findViewById<android.view.View>(R.id.scroll)
                .updatePadding(left = bars.left, right = bars.right, bottom = bars.bottom + dp(96))
            findViewById<android.view.View>(R.id.appBar).updatePadding(left = bars.left, right = bars.right)
            (save.layoutParams as android.view.ViewGroup.MarginLayoutParams).apply {
                bottomMargin = bars.bottom + dp(16); rightMargin = bars.right + dp(16)
            }
            save.requestLayout()
            insets
        }

        findViewById<TextView>(R.id.keepAliveHint).text =
            "国产系统会清理后台应用，自动同步需要完成以下三步（${Build.MANUFACTURER}）"

        findViewById<MaterialButton>(R.id.pastePrompt).setOnClickListener { pasteInto(gateway = true) }
        findViewById<MaterialButton>(R.id.pastePush).setOnClickListener { pasteInto(gateway = false) }
        findViewById<MaterialButton>(R.id.testGateway).setOnClickListener { testGateway(it as MaterialButton) }
        findViewById<MaterialButton>(R.id.syncNow).setOnClickListener {
            runCatching { Scheduler.runNow(this) }
                .onSuccess { statusDetail.text = "同步中…"; snack("已开始同步（使用已保存的配置）") }
                .onFailure { snack("无法开始同步") }
        }
        battery.setOnClickListener { requestBattery() }
        findViewById<MaterialButton>(R.id.autostartSettings).setOnClickListener { showAutostartGuide() }
        findViewById<MaterialButton>(R.id.lockGuide).setOnClickListener {
            MaterialAlertDialogBuilder(this)
                .setTitle("在最近任务中上锁")
                .setMessage(Oem.lockSteps() + "\n\n上锁后，一键清理后台时不会关闭 Mnemo Push。")
                .setPositiveButton("知道了", null)
                .show()
        }
        autoSync.setOnCheckedChangeListener { _, on -> interval.isEnabled = on; for (i in 0 until interval.childCount) interval.getChildAt(i).isEnabled = on }
        save.setOnClickListener { save(save) }

        WorkManager.getInstance(this).getWorkInfosForUniqueWorkLiveData("mnemo-sync-now").observe(this) { infos ->
            val state = infos.firstOrNull()?.state
            if (state == WorkInfo.State.RUNNING) statusDetail.text = "同步中…"
            refresh()
        }

        BootGuard.markOpened(this)   // 用户打开过应用：关闭自启动时也恢复同步
        fill(Config())
        lifecycleScope.launch {
            val (config, error) = withContext(Dispatchers.IO) { SecureStore.loadForUi(applicationContext) }
            fill(config)
            if (error != null) {
                statusTitle.text = "需要重新配置"; statusDetail.text = error
                MaterialAlertDialogBuilder(this@MainActivity).setTitle("需要重新填写密钥").setMessage(error)
                    .setPositiveButton("知道了", null).show()
            }
        }
    }

    override fun onResume() { super.onResume(); refresh() }

    private fun fill(c: Config) {
        token.setText(c.token); agent.setText(c.agent); port.setText(c.gatewayPort.toString())
        pushUrl.setText(c.pushUrl); pushKey.setText(c.pushKey); days.setText(c.days.toString())
        autoSync.isChecked = c.autoSync; autoStart.isChecked = c.autoStart
        interval.check(intervalIds[c.intervalMinutes] ?: R.id.i15)
        interval.isEnabled = c.autoSync
        for (i in 0 until interval.childCount) interval.getChildAt(i).isEnabled = c.autoSync
    }

    private fun currentConfig() = Config(
        token = token.text.toString().trim(),
        agent = agent.text.toString().trim().ifBlank { "claude" },
        pushUrl = pushUrl.text.toString().trim(),
        pushKey = pushKey.text.toString().trim(),
        autoSync = autoSync.isChecked,
        intervalMinutes = intervalIds.entries.firstOrNull { it.value == interval.checkedButtonId }?.key ?: 15,
        days = days.text.toString().toIntOrNull()?.coerceIn(1, 30) ?: 2,
        gatewayPort = port.text.toString().toIntOrNull()?.takeIf { it in 1..65535 } ?: 8723,
        autoStart = autoStart.isChecked,
    )

    /** 两个粘贴按钮各管各的：本机只取通行证/agent/端口，云端只取 PUSH_URL/PUSH_KEY。 */
    private fun pasteInto(gateway: Boolean) {
        val clipboard = getSystemService(ClipboardManager::class.java)
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        val all = PromptParser.parse(text)
        val parsed = if (gateway) all.gatewayOnly() else all.pushOnly()
        if (parsed.isEmpty) {
            snack(if (gateway) "剪贴板里没有找到极米记得通行证" else "剪贴板里没有找到 PUSH_URL / PUSH_KEY")
            return
        }
        // 只写入解析到的字段，不触碰其它未保存的输入
        parsed.token?.let { token.setText(it) }
        parsed.agent?.let { agent.setText(it) }
        parsed.gatewayPort?.let { port.setText(it.toString()) }
        parsed.pushUrl?.let { pushUrl.setText(it) }
        parsed.pushKey?.let { pushKey.setText(it) }
        if (parsed.token != null || parsed.pushKey != null) {
            if (Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
            else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
        snack("已填入：${parsed.summary()}，确认后点「保存」")
    }

    private fun testGateway(button: MaterialButton) {
        val config = currentConfig()
        button.isEnabled = false
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { Syncer(config, filesDir).ping() }
                findViewById<TextInputLayout>(R.id.tokenLayout).error = null
                snack("✓ 已连接极米记得网关")
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) {
                findViewById<TextInputLayout>(R.id.tokenLayout).error =
                    RecentLog.safe(e.message ?: e.javaClass.simpleName, config).take(120)
            } finally { button.isEnabled = true }
        }
    }

    private fun save(button: ExtendedFloatingActionButton) {
        val config = currentConfig()
        val urlLayout = findViewById<TextInputLayout>(R.id.pushUrlLayout)
        if (config.pushUrl.isNotEmpty() && !config.pushUrl.startsWith("https://")) {
            urlLayout.error = "必须以 https:// 开头"; return
        }
        urlLayout.error = null
        button.isEnabled = false
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    SecureStore.save(applicationContext, config)
                    BootGuard.setReceiverEnabled(applicationContext, config.autoStart)
                    BootGuard.markOpened(applicationContext)
                    Scheduler.apply(applicationContext, config)
                }
                snack(if (config.autoSync) "已保存，每 ${config.intervalMinutes} 分钟自动同步" else "已保存")
                maybeFirstTimeGuide(config)
            } catch (e: CancellationException) { throw e
            } catch (_: Exception) { snack("保存失败，请重试")
            } finally { button.isEnabled = true; refresh() }
        }
    }

    /** 首次开启自动同步时，主动提醒完成保活设置。 */
    private fun maybeFirstTimeGuide(config: Config) {
        val prefs = getSharedPreferences("mnemo_ui", MODE_PRIVATE)
        if (!config.autoSync || prefs.getBoolean("guided", false)) return
        prefs.edit().putBoolean("guided", true).apply()
        MaterialAlertDialogBuilder(this)
            .setTitle("让自动同步稳定运行")
            .setMessage("国产系统默认会清理后台应用，请依次完成：\n\n① 忽略电池优化\n② 允许自启动\n③ 在最近任务中锁定本应用\n\n入口都在「后台」卡片底部。")
            .setPositiveButton("现在设置") { _, _ -> requestBattery() }
            .setNegativeButton("稍后", null)
            .show()
    }

    private fun requestBattery() {
        val power = getSystemService(PowerManager::class.java)
        if (power.isIgnoringBatteryOptimizations(packageName)) { snack("已忽略电池优化 ✓"); return }
        runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
        }.onFailure { snack("无法打开电池优化设置") }
    }

    private fun showAutostartGuide() {
        MaterialAlertDialogBuilder(this)
            .setTitle("允许自启动")
            .setMessage(Oem.autostartSteps() + "\n\n点「前往设置」将尝试直接打开系统的自启动管理页面。")
            .setPositiveButton("前往设置") { _, _ ->
                when (runCatching { Oem.openAutostart(this) }.getOrDefault(Oem.Opened.NONE)) {
                    Oem.Opened.AUTOSTART_PAGE -> {}
                    Oem.Opened.APP_DETAILS -> snack("未找到自启动页面，已打开应用详情，请按说明手动设置")
                    Oem.Opened.NONE -> snack("无法打开系统设置，请按说明手动设置")
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun refresh() {
        val text = RecentLog.read(this)
        logs.text = text.lines().filter { it.isNotBlank() }.reversed().take(20).joinToString("\n").ifBlank { "暂无同步日志" }
        val last = text.lines().lastOrNull { it.isNotBlank() }
        if (last != null) {
            val ok = "同步成功" in last
            statusTitle.text = if (ok) "同步正常" else if ("失败" in last || "异常" in last) "同步出错" else "最近活动"
            statusDetail.text = last
        }
        val ignoring = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        battery.text = if (ignoring) "① 已忽略电池优化 ✓" else "① 忽略电池优化"
    }

    private fun snack(message: String) =
        Snackbar.make(findViewById(R.id.root), message, Snackbar.LENGTH_LONG).setAnchorView(R.id.save).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
