package dev.mnemo.push

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.View
import android.view.WindowInsets
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.lifecycle.LiveData
import androidx.lifecycle.Observer
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var token: EditText
    private lateinit var agent: EditText
    private lateinit var port: EditText
    private lateinit var pushUrl: EditText
    private lateinit var pushKey: EditText
    private lateinit var days: EditText
    private lateinit var autoSync: Switch
    private lateinit var interval: Spinner
    private lateinit var logs: TextView
    private lateinit var work: LiveData<List<WorkInfo>>
    private val observer = Observer<List<WorkInfo>> { refreshLogs() }
    private val intervals = listOf(15, 30, 60)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(24))
        }
        val scroll = ScrollView(this).apply { addView(content) }
        setContentView(scroll)
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            scroll.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
        }
        fun label(text: String) { content.addView(TextView(this).apply { this.text = text; textSize = 18f }) }
        fun input(title: String, password: Boolean = false, numeric: Boolean = false): EditText {
            label(title)
            return EditText(this).apply {
                isSingleLine = true
                inputType = when {
                    password -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                    numeric -> InputType.TYPE_CLASS_NUMBER
                    else -> InputType.TYPE_CLASS_TEXT
                }
                if (password) {
                    transformationMethod = PasswordTransformationMethod.getInstance()
                    importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
                    isSaveEnabled = false
                }
                content.addView(this)
            }
        }
        fun button(text: String, action: (Button) -> Unit) {
            content.addView(Button(this).apply { this.text = text; setOnClickListener { action(this) } })
        }
        button("粘贴安装提示词") { importFromClipboard() }
        content.addView(TextView(this).apply {
            text = "复制极米记得给出的整段安装提示词（或 VPS 输出的 PUSH_URL / PUSH_KEY）后点上面按钮，自动填写。"
            textSize = 13f
        })
        label("【网关】")
        token = input("通行证 token", password = true)
        button("显示") { button ->
            val reveal = token.transformationMethod != null
            token.transformationMethod = if (reveal) null else PasswordTransformationMethod.getInstance()
            token.setSelection(token.text.length)
            button.text = if (reveal) "隐藏" else "显示"
            refreshLogs()
        }
        agent = input("agent")
        port = input("网关端口", numeric = true)
        button("测试连接") { button ->
            val config = currentConfig()
            button.isEnabled = false
            scope.launch {
                try {
                    withContext(Dispatchers.IO) { Syncer(config, filesDir).ping() }
                    toast("连接成功")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    toast(RecentLog.safe("连接失败：${e.message ?: e.javaClass.simpleName}", config))
                } finally {
                    button.isEnabled = true
                    refreshLogs()
                }
            }
        }
        label("【推送】")
        pushUrl = input("PUSH_URL（https://）")
        pushUrl.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        pushKey = input("PUSH_KEY", password = true)
        label("【自动同步】")
        autoSync = Switch(this).apply { text = "开启自动同步"; content.addView(this) }
        label("同步间隔")
        interval = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item,
                intervals.map { "$it 分钟" })
            content.addView(this)
        }
        days = input("拉取天数", numeric = true)
        button("请求忽略电池优化") {
            try {
                val power = getSystemService(PowerManager::class.java)
                if (power.isIgnoringBatteryOptimizations(packageName)) toast("已开启忽略电池优化")
                else startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")))
            } catch (_: Exception) { toast("无法打开电池优化设置") }
            refreshLogs()
        }
        button("保存") { button ->
            val config = currentConfig()
            if (!config.pushUrl.startsWith("https://")) {
                toast("PUSH_URL 必须以 https:// 开头")
                refreshLogs()
            } else if (config.days <= 0) {
                toast("拉取天数请输入正整数")
                refreshLogs()
            } else {
                button.isEnabled = false
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            SecureStore.save(applicationContext, config)
                            Scheduler.apply(applicationContext, config)
                        }
                        toast("已保存并应用同步设置")
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) { toast("保存或应用设置失败，请重试") }
                    finally { button.isEnabled = true; refreshLogs() }
                }
            }
        }
        button("立即同步") {
            try { Scheduler.runNow(this); toast("已加入同步队列，使用已保存配置") }
            catch (_: Exception) { toast("无法加入同步队列") }
            refreshLogs()
        }
        label("最近日志")
        logs = TextView(this).apply { setTextIsSelectable(true); textSize = 14f; content.addView(this) }
        work = WorkManager.getInstance(this).getWorkInfosForUniqueWorkLiveData("mnemo-sync-now")
        scope.launch {
            fill(withContext(Dispatchers.IO) { SecureStore.load(applicationContext) })
        }
        fill(Config())
    }

    private fun fill(config: Config) {
        token.setText(config.token)
        agent.setText(config.agent)
        port.setText(config.gatewayPort.toString())
        pushUrl.setText(config.pushUrl)
        pushKey.setText(config.pushKey)
        days.setText(config.days.toString())
        autoSync.isChecked = config.autoSync
        interval.setSelection(intervals.indexOf(config.intervalMinutes).coerceAtLeast(0))
    }

    private fun importFromClipboard() {
        val clipboard = getSystemService(ClipboardManager::class.java)
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        val parsed = PromptParser.parse(text)
        if (parsed.isEmpty) { toast("剪贴板里没有识别到通行证或推送配置"); return }
        fill(parsed.applyTo(currentConfig()))
        // 剪贴板里有通行证，导入后立即清空，避免被其他 App 读取
        if (parsed.token != null || parsed.pushKey != null) {
            if (android.os.Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
        }
        toast("已填入：${parsed.summary()}。确认无误后点「保存」")
    }

    private fun currentConfig() = Config(token.text.toString().trim(),
        agent.text.toString().trim().ifBlank { "claude" }, pushUrl.text.toString().trim(),
        pushKey.text.toString().trim(), autoSync.isChecked, intervals[interval.selectedItemPosition],
        days.text.toString().toIntOrNull() ?: 0,
        port.text.toString().toIntOrNull()?.takeIf { it in 1..65535 } ?: 8723)

    override fun onStart() { super.onStart(); work.observeForever(observer) }
    override fun onStop() { work.removeObserver(observer); super.onStop() }
    override fun onResume() { super.onResume(); refreshLogs() }
    override fun onDestroy() { work.removeObserver(observer); scope.cancel(); super.onDestroy() }
    private fun refreshLogs() {
        if (::logs.isInitialized) logs.text = RecentLog.read(this).ifBlank { "暂无同步日志" }
    }
    private fun toast(message: String) { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
