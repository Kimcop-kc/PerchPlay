package com.perchplay.player

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File
import java.io.InputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 崩溃日志收集（Android 原生侧）。
 *
 * ## 为什么要原生参与
 *
 * Dart 侧的 `runZonedGuarded` / `FlutterError.onError` 只能接住 **Dart 层**
 * 的异常。这个 App 真正的闪退绝大多数发生在原生：
 *
 *  - **libmpv 段错误**（SIGSEGV）—— 播放器内核是 C 代码，一崩就是整个进程
 *    直接消失，Dart 一行都来不及执行；
 *  - **mediacodec / Vulkan 驱动崩溃** —— 同样是原生信号；
 *  - **ANR** —— 主线程卡死被系统强杀。
 *
 * 这三种情况 Dart 侧完全无感知，内存里的日志跟着进程一起没了。
 * 所以必须由原生把证据**留在磁盘上**，下次启动再取出来。
 *
 * ## 两条证据链
 *
 * ### 1. 未捕获异常处理器（全版本可用）
 *
 * `Thread.setDefaultUncaughtExceptionHandler` 能兜住 Java/Kotlin 层任何线程
 * 上未捕获的异常。触发时把堆栈写进 `filesDir/crashlog/uncaught.txt`。
 *
 * 局限：**接不住原生信号**。SIGSEGV 不经过 Java 异常机制。
 *
 * ### 2. ApplicationExitInfo（Android 11 / API 30+）
 *
 * 这是系统自己记录的进程死亡原因。`getHistoricalProcessExitReasons()`
 * 读**自己这个包**无需任何权限，而且 `traceInputStream` 在
 * `REASON_CRASH_NATIVE` 时给出的正是 **tombstone（完整原生崩溃堆栈）**
 * —— 也就是解决「libmpv 崩了但什么都看不到」这个问题的关键。
 *
 * 比「上次没留退出标记」这种猜法准确得多：用户从任务管理器划掉 App
 * 不会留标记，但那不是崩溃，不该报警。
 *
 * ## 不做什么
 *
 * 不读 `logcat -b crash`：Android 4.1 起普通 App 只能看到自己 UID 的日志，
 * 原生崩溃的 tombstone 由 debuggerd 写入，拿不到。
 * `ApplicationExitInfo` 才是正规通道。
 */
object CrashLog {
    private const val TAG = "PerchPlayCrash"
    private const val DIR_NAME = "crashlog"
    private const val FILE_UNCAUGHT = "uncaught.txt"

    private const val PREF = "perchplay_crashlog"
    private const val KEY_LAST_REPORTED_TS = "last_reported_ts"

    /** 写进报告的堆栈上限（够看清调用栈，又不至于塞爆诊断报告）。 */
    private const val MAX_READ_CHARS = 24 * 1024

    @Volatile
    private var installed = false

    private fun dir(ctx: Context): File =
        File(ctx.applicationContext.filesDir, DIR_NAME).apply {
            if (!exists()) mkdirs()
        }

    private fun ts(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())

    private fun fmtMillis(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(ms))

    // ══════════════ 安装 ══════════════

    /**
     * 装上未捕获异常处理器。
     *
     * 必须在 `MainActivity.onCreate` 尽早调用 —— 越早越能覆盖启动期崩溃。
     * 重复调用安全（内部有 [installed] 保护）。
     */
    fun install(ctx: Context) {
        if (installed) return
        installed = true
        val app = ctx.applicationContext

        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            // 先写盘 —— 这可能是进程死前的最后一次机会
            try {
                writeUncaught(app, thread, error)
            } catch (t: Throwable) {
                Log.w(TAG, "写入未捕获异常失败", t)
            }
            // 交还给原处理器（让系统弹「应用已停止」并生成 tombstone）
            previous?.uncaughtException(thread, error)
        }
    }

    private fun writeUncaught(ctx: Context, thread: Thread, error: Throwable) {
        val sw = StringWriter()
        PrintWriter(sw).use { pw ->
            pw.println("===== 未捕获异常 =====")
            pw.println("时间: ${ts()}")
            pw.println("线程: ${thread.name} (id=${thread.id})")
            pw.println("进程: ${ctx.packageName} (pid=${Process.myPid()})")
            pw.println(
                "设备: ${Build.MANUFACTURER} ${Build.MODEL} / " +
                    "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"
            )
            pw.println("异常: ${error.javaClass.name}: ${error.message}")
            pw.println("---------- 堆栈 ----------")
            error.printStackTrace(pw)
        }
        var text = sw.toString()
        if (text.length > MAX_READ_CHARS) {
            text = text.substring(0, MAX_READ_CHARS) + "\n...（堆栈过长已截断）"
        }
        File(dir(ctx), FILE_UNCAUGHT).writeText(text)
    }

    // ══════════════ 读取 ══════════════

    /**
     * 取走上次运行留下的崩溃记录（读完即删，避免重复上报）。
     *
     * @return 组装好的报告；没有崩溃记录时返回 null。
     */
    fun takeReport(ctx: Context): String? {
        val blocks = mutableListOf<String>()

        // ── 证据 1：未捕获异常文件 ──
        try {
            val f = File(dir(ctx), FILE_UNCAUGHT)
            if (f.exists() && f.length() > 0) {
                var text = f.readText()
                if (text.length > MAX_READ_CHARS) {
                    text = text.takeLast(MAX_READ_CHARS)
                }
                blocks += text.trim()
                // 立刻删掉：这是「上次」的记录，重复报会让用户以为又崩了
                f.delete()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "读取未捕获异常文件失败", t)
        }

        // ── 证据 2：系统记录的进程死亡原因（API 30+）──
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val info = readExitInfo(ctx)
                if (!info.isNullOrBlank()) blocks += info
            } catch (t: Throwable) {
                Log.w(TAG, "读取 ApplicationExitInfo 失败", t)
            }
        }

        if (blocks.isEmpty()) return null
        return blocks.joinToString("\n\n")
    }

    /**
     * 从系统的进程退出历史里挑出**未被上报过**的异常退出。
     *
     * 只关心真正的崩溃类原因；用户从任务管理器划掉
     * （`REASON_USER_REQUESTED`）、正常退出都不算，否则每次开 App 都会误报。
     */
    private fun readExitInfo(ctx: Context): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null

        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null

        val prefs = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val lastReported = prefs.getLong(KEY_LAST_REPORTED_TS, 0L)

        // 自己这个包最近 10 次进程退出
        val list = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 10)
        if (list.isNullOrEmpty()) return null

        val sb = StringBuilder()
        var newest = lastReported

        for (info in list) {
            val stamp = info.timestamp
            // 已上报过 / 比上次上报还早 → 跳过
            if (stamp <= lastReported) continue

            val reason = info.reason
            // 只报崩溃类原因
            val isCrash = when (reason) {
                ApplicationExitInfo.REASON_CRASH,
                ApplicationExitInfo.REASON_CRASH_NATIVE,
                ApplicationExitInfo.REASON_ANR,
                ApplicationExitInfo.REASON_LOW_MEMORY,
                ApplicationExitInfo.REASON_SIGNALED,
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> true

                else -> false
            }
            if (!isCrash) continue

            sb.appendLine("===== 系统记录的异常退出 =====")
            sb.appendLine("时间: ${fmtMillis(stamp)}")
            sb.appendLine("原因: ${reasonLabel(reason)}")
            sb.appendLine("进程: ${info.processName}")
            val desc = info.description
            if (!desc.isNullOrBlank()) {
                sb.appendLine("描述: $desc")
            }
            // 原生崩溃时这里就是 tombstone
            try {
                val trace = readStream(info.traceInputStream)
                if (trace.isNotBlank()) {
                    sb.appendLine("---------- 系统堆栈 / tombstone ----------")
                    sb.appendLine(trace)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "读取 trace 失败", t)
            }
            sb.appendLine()

            if (stamp > newest) newest = stamp
        }

        // 记住已上报的时间点，下次不再重复
        if (newest > lastReported) {
            prefs.edit().putLong(KEY_LAST_REPORTED_TS, newest).apply()
        }

        return sb.toString().ifBlank { null }
    }

    private fun readStream(input: InputStream?): String {
        if (input == null) return ""
        return try {
            input.bufferedReader().use { r ->
                var text = r.readText()
                if (text.length > MAX_READ_CHARS) {
                    // tombstone 的头尾都有用，中间截断
                    val head = text.take(MAX_READ_CHARS * 2 / 3)
                    val tail = text.takeLast(MAX_READ_CHARS / 3)
                    text = "$head\n...（中间省略 ${text.length - MAX_READ_CHARS} 字符）...\n$tail"
                }
                text.trim()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "读取流失败", t)
            ""
        }
    }

    /** 原因码 → 中文说明（让用户/我一眼看出是崩了还是被系统回收）。 */
    private fun reasonLabel(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH ->
            "Java / Kotlin 未捕获异常（REASON_CRASH）"

        ApplicationExitInfo.REASON_CRASH_NATIVE ->
            "原生崩溃（REASON_CRASH_NATIVE，如 libmpv 段错误）"

        ApplicationExitInfo.REASON_ANR ->
            "ANR 无响应被系统杀死（REASON_ANR）"

        ApplicationExitInfo.REASON_LOW_MEMORY ->
            "内存不足被系统回收（REASON_LOW_MEMORY）"

        ApplicationExitInfo.REASON_SIGNALED ->
            "被信号杀死（REASON_SIGNALED）"

        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE ->
            "进程初始化失败（REASON_INITIALIZATION_FAILURE）"

        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
            "资源占用过高被系统杀死（REASON_EXCESSIVE_RESOURCE_USAGE）"

        else -> "其他原因（$reason）"
    }
}
