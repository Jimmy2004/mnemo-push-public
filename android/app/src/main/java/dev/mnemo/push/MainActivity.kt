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
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.color.MaterialColors
import com.google.android.material.textfield.MaterialAutoCompleteTextView
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
    private lateinit var interval: TextInputEditText
    private lateinit var intervalUnit: MaterialAutoCompleteTextView
    private lateinit var device: TextInputEditText
    private lateinit var logs: TextView
    private lateinit var statusTitle: TextView
    private lateinit var statusDetail: TextView
    private lateinit var battery: MaterialButton
    private val units = arrayOf("分钟", "小时")
    private var syncing = false

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
        if (!resources.getBoolean(R.bool.show_logs)) findViewById<android.view.View>(R.id.logCard).visibility = android.view.View.GONE
        intervalUnit = findViewById(R.id.intervalUnit); device = findViewById(R.id.device)
        intervalUnit.setSimpleItems(units)
        intervalUnit.setOnItemClickListener { _, _, _, _ -> validateInterval() }
        interval.doAfterTextChanged { validateInterval() }

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
        findViewById<MaterialButton>(R.id.testPush).setOnClickListener { testPush(it as MaterialButton) }
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
        autoSync.setOnCheckedChangeListener { _, on -> setIntervalEnabled(on) }
        save.setOnClickListener { save(save) }

        WorkManager.getInstance(this).getWorkInfosForUniqueWorkLiveData("mnemo-sync-now").observe(this) { infos ->
            val state = infos.firstOrNull()?.state
            syncing = state == WorkInfo.State.RUNNING || state == WorkInfo.State.ENQUEUED
            if (syncing) statusDetail.text = "同步中…"
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
        val hours = c.intervalInHours && c.intervalMinutes % 60 == 0
        interval.setText((if (hours) c.intervalMinutes / 60 else c.intervalMinutes).toString())
        intervalUnit.setText(units[if (hours) 1 else 0], false)
        device.setText(c.device)
        setIntervalEnabled(c.autoSync)
    }

    private fun currentConfig() = Config(
        token = token.text.toString().trim(),
        agent = agent.text.toString().trim().ifBlank { "claude" },
        pushUrl = pushUrl.text.toString().trim(),
        pushKey = pushKey.text.toString().trim(),
        autoSync = autoSync.isChecked,
        intervalMinutes = intervalMinutes() ?: 15,
        intervalInHours = inHours(),
        days = days.text.toString().toIntOrNull()?.coerceIn(0, Syncer.ALL_DAYS) ?: 2,
        device = device.text.toString().trim(),
        gatewayPort = port.text.toString().toIntOrNull()?.takeIf { it in 1..65535 } ?: 8723,
        autoStart = autoStart.isChecked,
    )

    private fun inHours() = intervalUnit.text.toString() == units[1]

    /** 输入框中的间隔换算为分钟；非整数或为空时返回 null。 */
    private fun intervalMinutes(): Int? {
        val n = interval.text.toString().toIntOrNull() ?: return null
        return if (inHours()) n.toLong().times(60).coerceAtMost(Int.MAX_VALUE.toLong()).toInt() else n
    }

    /** 返回错误文字；合法时为 null。上限 1440 分钟（24 小时），下限 1 分钟；低于 15 分钟走自续任务链。 */
    private fun validateInterval(): String? {
        val m = intervalMinutes()
        val error = when {
            m == null -> "请输入整数"
            m > 1440 -> if (inHours()) "最多 24 小时" else "最多 1440 分钟（24 小时）"
            m < Scheduler.MIN_MINUTES -> "最少 1 分钟"
            else -> null
        }
        findViewById<TextInputLayout>(R.id.intervalLayout).error = error
        return error
    }

    private fun setIntervalEnabled(on: Boolean) {
        interval.isEnabled = on; intervalUnit.isEnabled = on
        findViewById<TextInputLayout>(R.id.intervalLayout).isEnabled = on
        findViewById<TextInputLayout>(R.id.unitLayout).isEnabled = on
    }

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

    private fun testPush(button: MaterialButton) {
        val config = currentConfig()
        val layout = findViewById<TextInputLayout>(R.id.pushUrlLayout)
        button.isEnabled = false
        button.text = "测试中…"
        lifecycleScope.launch {
            try {
                val ms = withContext(Dispatchers.IO) { Syncer(config, filesDir).pingPush() }
                layout.error = null
                button.text = "✓ 已连接 · $ms ms"
                snack("✓ VPS 推送可用，延迟 $ms ms")
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) {
                button.text = "测试连接"
                layout.error = RecentLog.safe(e.message ?: e.javaClass.simpleName, config).take(120)
            } finally { button.isEnabled = true }
        }
    }

    private fun save(button: ExtendedFloatingActionButton) {
        if (autoSync.isChecked && validateInterval() != null) { snack("请先修正同步间隔"); return }
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
                snack(if (config.autoSync) "已保存，每 ${intervalLabel(config)}自动同步" else "已保存")
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

    private fun intervalLabel(c: Config) =
        if (c.intervalInHours && c.intervalMinutes % 60 == 0) "${c.intervalMinutes / 60} 小时" else "${c.intervalMinutes} 分钟"

    private fun refresh() {
        val text = RecentLog.read(this)
        logs.text = text.lines().filter { it.isNotBlank() }.reversed().joinToString("\n").ifBlank { "暂无同步日志" }
        val last = RecentLog.last(this)
        val card = findViewById<MaterialCardView>(R.id.statusCard)
        val (bg, fg) = if (last == null || last.ok)
            com.google.android.material.R.attr.colorPrimaryContainer to com.google.android.material.R.attr.colorOnPrimaryContainer
        else com.google.android.material.R.attr.colorErrorContainer to com.google.android.material.R.attr.colorOnErrorContainer
        card.setCardBackgroundColor(MaterialColors.getColor(card, bg))
        MaterialColors.getColor(card, fg).let { statusTitle.setTextColor(it); statusDetail.setTextColor(it) }
        if (last != null && !syncing) {
            val time = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.CHINA).format(java.util.Date(last.atMs))
            if (last.ok) {
                statusTitle.text = "同步正常"
                statusDetail.text = "上次同步：$time，共 ${last.count} 条"
            } else {
                statusTitle.text = "同步失败"
                statusDetail.text = "上次同步：$time\n${last.error.take(120)}"
            }
        }
        val ignoring = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        battery.text = if (ignoring) "① 已忽略电池优化 ✓" else "① 忽略电池优化"
    }

    private fun snack(message: String) =
        Snackbar.make(findViewById(R.id.root), message, Snackbar.LENGTH_LONG).setAnchorView(R.id.save).show()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
