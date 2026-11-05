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
            // 只报「真正的崩溃类」原因。
            //
            // ⚠ REASON_LOW_MEMORY 特意排除：内存不足被系统回收是 Android 的
            // 正常后台管理行为（LMK），App 退后台后普遍会发生，用户毫无感知。
            // 把它当「原生崩溃」报警是纯噪音 —— 实测日志里「原生崩溃」标题
            // 下面跟着的却是「内存不足被系统回收」，名不副实。
            val isCrash = when (reason) {
                ApplicationExitInfo.REASON_CRASH,
                ApplicationExitInfo.REASON_CRASH_NATIVE,
                ApplicationExitInfo.REASON_ANR,
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
            val bytes = input.readBytes()
            if (bytes.isEmpty()) return ""
            // Android 12+ 的 REASON_CRASH_NATIVE tombstone 是 protobuf 二进制
            // （debuggerd/proto/tombstone.proto），不是纯文本。之前用 readText()
            // 读它，非 ASCII 字节一乱码就中断 —— 用户贴回来的日志里只有设备名
            // 那一行，真正的 signal / fault_address / backtrace 全丢了。
            //
            // 判定：纯文本 tombstone 以 "***"、"Build fingerprint"、"pid:" 等
            // 可读字符开头；protobuf 的第一个字段是 arch(1,varint) 或
            // build_fingerprint(2,len)，首字节往往是不可打印的控制符。
            val looksProto = !isPrintableTombstoneText(bytes)
            if (looksProto) {
                val parsed = parseTombstoneProto(bytes)
                if (parsed.isNotBlank()) parsed else String(bytes, Charsets.UTF_8).trim()
            } else {
                var text = String(bytes, Charsets.UTF_8)
                if (text.length > MAX_READ_CHARS) {
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

    /** 判定字节流是否「可读的纯文本 tombstone」（而不是 protobuf 二进制）。 */
    private fun isPrintableTombstoneText(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        // 取前 64 字节，若绝大多数是可打印 ASCII / UTF-8 中文字节，判定为文本
        var printable = 0
        val n = minOf(bytes.size, 64)
        for (i in 0 until n) {
            val b = bytes[i].toInt() and 0xff
            // 可打印 ASCII + 换行/制表符 + 高位（可能 UTF-8 中文）
            if (b in 0x20..0x7e || b == 0x0a || b == 0x0d || b == 0x09 || b >= 0x80) {
                printable++
            }
        }
        return printable >= n * 0.85
    }

    /**
     * 轻量 protobuf wire-format 解析：从 tombstone.proto 二进制里提取
     * 崩溃信号、出错地址、崩溃线程的 backtrace。
     *
     * 不引入 protobuf-lite 依赖（体积 + 初始化开销），只解析我们关心的字段。
     * 字段号与 wire type 见 AOSP `debuggerd/proto/tombstone.proto`。
     */
    private fun parseTombstoneProto(bytes: ByteArray): String {
        val sb = StringBuilder()
        try {
            var pos = 0
            // 顶层 Tombstone 的字段
            while (pos < bytes.size) {
                val (field, type, nextPos) = readTag(bytes, pos) ?: break
                pos = nextPos
                when (field to type) {
                    // build_fingerprint = 2 (string)
                    2 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; sb.appendLine("指纹: $v") }
                    // revision = 3 (string)
                    3 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; if (v.isNotBlank()) sb.appendLine("修订: $v") }
                    // timestamp = 4 (string)
                    4 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; sb.appendLine("崩溃时间: $v") }
                    // pid = 5 (uint32)
                    5 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; sb.appendLine("PID: $v") }
                    // tid = 6 (uint32)
                    6 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; sb.appendLine("TID: $v") }
                    // signal_info = 10 (message Signal)
                    10 to 2 -> { val (len, np0) = readVarint(bytes, pos); pos = np0; val end = pos + len.toInt(); val (sig, np) = parseSignal(bytes, pos, end); pos = np; sb.append(sig) }
                    // abort_message = 14 (string)
                    14 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; if (v.isNotBlank()) sb.appendLine("abort 消息: $v") }
                    // cause = 15 (message Cause)
                    15 to 2 -> { val (len, np0) = readVarint(bytes, pos); pos = np0; val end = pos + len.toInt(); val (c, np) = parseCause(bytes, pos, end); pos = np; if (c.isNotBlank()) sb.append(c) }
                    // threads = 16 (map<uint32,Thread>)
                    16 to 2 -> { val (len, np0) = readVarint(bytes, pos); pos = np0; val end = pos + len.toInt(); val (t, np) = parseThread(bytes, pos, end); pos = np; sb.append(t) }
                    else -> { skipField(bytes, type, pos).let { pos = it } }
                }
            }
        } catch (_: Throwable) {
            // 解析失败就返回空，调用方会回退到 UTF-8 原文
            return ""
        }
        return sb.toString().trim()
    }

    private fun parseSignal(bytes: ByteArray, start: Int, end: Int): Pair<String, Int> {
        val sb = StringBuilder()
        var number = 0; var name = ""; var code = 0; var codeName = ""; var fault = -1L; var hasFault = false
        var pos = start
        while (pos < end) {
            val (field, type, np0) = readTag(bytes, pos) ?: break
            pos = np0
            when (field to type) {
                1 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; number = v.toInt() }
                2 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; name = v }
                3 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; code = v.toInt() }
                4 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; codeName = v }
                8 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; hasFault = v != 0L }
                // fault_address = 9，proto3 uint64 → varint（不是 fixed64）
                9 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; fault = v }
                else -> pos = skipField(bytes, type, pos)
            }
        }
        sb.appendLine("崩溃信号: ${name.ifBlank { "SIG$number" }} (number=$number, code=${codeName.ifBlank { code.toString() }})")
        if (hasFault && fault >= 0) {
            sb.appendLine("出错地址: 0x${fault.toString(16)}")
        }
        return sb.toString() to pos
    }

    private fun parseCause(bytes: ByteArray, start: Int, end: Int): Pair<String, Int> {
        var human = ""
        var pos = start
        while (pos < end) {
            val (field, type, np0) = readTag(bytes, pos) ?: break
            pos = np0
            when (field to type) {
                1 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; human = v }
                else -> pos = skipField(bytes, type, pos)
            }
        }
        val out = if (human.isNotBlank()) "崩溃原因: $human\n" else ""
        return out to pos
    }

    private fun parseThread(bytes: ByteArray, start: Int, end: Int): Pair<String, Int> {
        // map 的 entry：key=1(uint32), value=2(message Thread)
        var threadId = 0
        var name = ""
        val frames = mutableListOf<String>()
        var pos = start
        while (pos < end) {
            val (field, type, np0) = readTag(bytes, pos) ?: break
            pos = np0
            when (field to type) {
                1 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; threadId = v.toInt() }
                2 to 2 -> {
                    val (len, np1) = readVarint(bytes, pos); pos = np1
                    val threadEnd = pos + len.toInt()
                    // 解析 Thread 内部字段
                    var p2 = pos
                    while (p2 < threadEnd) {
                        val (f2, t2, np2) = readTag(bytes, p2) ?: break
                        p2 = np2
                        when (f2 to t2) {
                            2 to 2 -> { val (v, np3) = readString(bytes, p2); p2 = np3; name = v }
                            4 to 2 -> {
                                val (flen, np3) = readVarint(bytes, p2); p2 = np3
                                val frameEnd = p2 + flen.toInt()
                                val (frameStr, np4) = parseBacktraceFrame(bytes, p2, frameEnd)
                                p2 = np4
                                if (frameStr.isNotBlank()) frames += frameStr
                            }
                            else -> p2 = skipField(bytes, t2, p2)
                        }
                    }
                    pos = threadEnd
                }
                else -> pos = skipField(bytes, type, pos)
            }
        }
        if (name.isBlank() && frames.isEmpty()) return "" to pos
        val sb = StringBuilder()
        sb.appendLine("── 线程 (id=$threadId, name=${name.ifBlank { "?" }}) ──")
        for (f in frames) sb.appendLine(f)
        return sb.toString() to pos
    }

    private fun parseBacktraceFrame(bytes: ByteArray, start: Int, end: Int): Pair<String, Int> {
        var function = ""; var file = ""; var pc = -1L; var relPc = -1L
        var pos = start
        while (pos < end) {
            val (field, type, np0) = readTag(bytes, pos) ?: break
            pos = np0
            when (field to type) {
                1 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; relPc = v }
                // pc = 2，proto3 uint64 → varint（不是 fixed64）
                2 to 0 -> { val (v, np) = readVarint(bytes, pos); pos = np; pc = v }
                4 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; function = v }
                6 to 2 -> { val (v, np) = readString(bytes, pos); pos = np; file = v }
                else -> pos = skipField(bytes, type, pos)
            }
        }
        if (function.isBlank() && file.isBlank()) return "" to pos
        val pcStr = if (pc >= 0) "  pc=0x${pc.toString(16)}" else ""
        val loc = file.ifBlank { "" }
        return "  ${function.ifBlank { "?" }} $loc$pcStr".trimEnd() to pos
    }

    // ── wire-format 原语 ──

    private data class Tag(val field: Int, val type: Int, val nextPos: Int)

    private fun readTag(bytes: ByteArray, pos: Int): Tag? {
        if (pos >= bytes.size) return null
        val (key, np) = readVarint(bytes, pos)
        if (key <= 0) return null
        val field = (key shr 3).toInt()
        val type = (key and 0x7).toInt()
        return Tag(field, type, np)
    }

    private fun readVarint(bytes: ByteArray, pos: Int): Pair<Long, Int> {
        var result = 0L
        var shift = 0
        var p = pos
        while (p < bytes.size) {
            val b = bytes[p].toInt() and 0xff
            result = result or ((b and 0x7f).toLong() shl shift)
            p++
            if ((b and 0x80) == 0) break
            shift += 7
            if (shift >= 64) break
        }
        return result to p
    }

    private fun readString(bytes: ByteArray, pos: Int): Pair<String, Int> {
        val (len, np) = readVarint(bytes, pos)
        if (np >= bytes.size) return "" to np
        val remaining = bytes.size - np
        val l = len.toInt().coerceIn(0, remaining)
        if (l <= 0) return "" to (np + l)
        return String(bytes, np, l, Charsets.UTF_8) to (np + l)
    }

    private fun skipField(bytes: ByteArray, type: Int, pos: Int): Int {
        return when (type) {
            0 -> readVarint(bytes, pos).second
            1 -> pos + 8
            2 -> { val (len, np) = readVarint(bytes, pos); np + len.toInt() }
            5 -> pos + 4
            else -> pos
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
