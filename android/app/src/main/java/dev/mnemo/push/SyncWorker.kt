package dev.mnemo.push

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException

internal object RecentLog {
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("mnemo_logs", Context.MODE_PRIVATE)

    fun safe(message: String, config: Config): String {
        var text = message
        val secrets = listOf(config.token, config.pushKey) + config.token.split('.')
        for (secret in secrets.filter { it.isNotEmpty() }.sortedByDescending { it.length }) {
            text = text.replace(secret, "[已隐藏]")
        }
        return text.replace('\n', ' ').replace('\r', ' ').take(1000)
    }

    @Synchronized
    fun append(ctx: Context, message: String, config: Config = Config()) {
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.CHINA).format(Date())
        val lines = read(ctx).lines().filter { it.isNotBlank() }.takeLast(49) + "$stamp ${safe(message, config)}"
        prefs(ctx).edit().putString("recent", lines.joinToString("\n")).apply()
    }

    @Synchronized
    fun read(ctx: Context): String = prefs(ctx).getString("recent", "") ?: ""
}

class SyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        syncMutex.withLock {
            var config = Config()
            try {
                config = SecureStore.load(applicationContext)
                if (!config.autoStart && BootGuard.rebootedSinceOpened(applicationContext)) {
                    RecentLog.append(applicationContext, "手机已重启且未开启自启动，跳过；打开应用后恢复", config)
                    return@withLock Result.success()
                }
                val result = Syncer(config, applicationContext.filesDir) {
                    RecentLog.append(applicationContext, it, config)
                }.run()
                RecentLog.append(applicationContext,
                    "同步成功：拉取 ${result.pulled}，推送 ${result.pushed}，待推送 ${result.pending}，sinceId=${result.sinceId}", config)
                Result.success()
            } catch (e: CancellationException) {
                throw e
            } catch (e: SyncException) {
                RecentLog.append(applicationContext, "同步失败：${e.message ?: "同步错误"}", config)
                Result.failure()
            } catch (e: Exception) {
                // SyncCore also does file I/O: only recognizable network errors are retried.
                val network = generateSequence<Throwable>(e) { it.cause }.any {
                    it is SocketException || it is SocketTimeoutException || it is UnknownHostException ||
                        it is SSLException || (it is IOException && it.stackTrace.any { frame ->
                            frame.className.startsWith("com.android.okhttp.") || frame.className.startsWith("java.net.")
                        })
                }
                RecentLog.append(applicationContext,
                    "同步${if (network) "网络异常，将重试" else "失败"}：${e.message ?: e.javaClass.simpleName}", config)
                if (network) Result.retry() else Result.failure()
            }
        }
    }

    companion object { private val syncMutex = Mutex() }
}

object Scheduler {
    fun apply(ctx: Context, config: Config) {
        val manager = WorkManager.getInstance(ctx)
        if (config.autoSync) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(config.intervalMinutes.coerceAtLeast(15).toLong(), TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
            manager.enqueueUniquePeriodicWork("mnemo-sync", ExistingPeriodicWorkPolicy.UPDATE, request)
        } else manager.cancelUniqueWork("mnemo-sync")
    }

    fun runNow(ctx: Context) {
        WorkManager.getInstance(ctx).enqueueUniqueWork("mnemo-sync-now", ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
    }
}
