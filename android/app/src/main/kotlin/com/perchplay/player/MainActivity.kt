package com.perchplay.player

import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vidflow/native"
    private val PIP_CHANNEL = "com.vidflow/pip"

    /// 从「文件管理器 / 相册」等外部 App 打开视频时带进来的 URI。
    ///
    /// 时序问题：`configureFlutterEngine` 早于 `onNewIntent`，而 Dart 侧要等
    /// 引擎起来才能收消息。所以这里先缓存，等 Dart 主动来取（`getLaunchUri`），
    /// 之后再用 `openVideoUri` 反向推送后续的 Intent。
    private var pendingVideoUri: String? = null

    /// Flutter 侧准备好的通道（Dart 调 `readyForLaunchUri` 后才有值）
    private var pendingChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 冷启动：从外部 App「用其他应用打开」进来的视频
        pendingVideoUri = extractVideoUri(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 热启动：App 已在后台，又被外部 App 唤起
        val uri = extractVideoUri(intent)
        if (uri != null) {
            pendingVideoUri = uri
            // Dart 侧已经就绪就直接推过去
            pendingChannel?.invokeMethod("openVideoUri", uri)
        }
    }

    /**
     * 从 Intent 中取出视频 URI。
     *
     * 只接受 `ACTION_VIEW` 且 data 是 content:// 或 file:// 的情况，
     * 避免把普通启动（MAIN/LAUNCHER）误判成打开文件。
     */
    private fun extractVideoUri(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val scheme = data.scheme ?: return null
        if (scheme != "content" && scheme != "file") return null
        return data.toString()
    }

    /**
     * content:// → 可播放的路径。
     *
     * MediaStore 的 content URI 直接交给 mpv 是不能播的，需要：
     *  1. 先尝试从 MediaStore 的 _DATA 列拿真实文件路径（最快，零拷贝）
     *  2. 拿不到（Android 10+ 分区存储常见）就把内容复制到应用缓存目录
     *     再返回缓存文件路径
     */
    private fun resolveUriToPath(uriString: String): String? {
        return try {
            val uri = Uri.parse(uriString)
            if (uri.scheme == "file") return uri.path

            // 1) 直接查 _DATA
            try {
                val proj = arrayOf(MediaStore.MediaColumns.DATA)
                contentResolver.query(uri, proj, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val idx = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                        if (idx >= 0) {
                            val p = c.getString(idx)
                            if (!p.isNullOrEmpty() && File(p).exists()) return p
                        }
                    }
                }
            } catch (_: Exception) {
            }

            // 2) 复制到缓存
            val name = queryDisplayName(uri) ?: "imported_${System.currentTimeMillis()}.mp4"
            val safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fff]"), "_")
            val outDir = File(cacheDir, "opened").apply { mkdirs() }
            // 每次复制前顺手清理旧文件：从文件管理器打开的视频会被整份复制
            // 到缓存（几百 MB ~ 几 GB），不清理会迅速吃满存储。
            cleanOldOpened(outDir)
            val outFile = File(outDir, safe)
            // 同名且大小一致就复用，避免重复拷贝几百 MB
            contentResolver.openInputStream(uri)?.use { input ->
                val expect = querySize(uri)
                if (outFile.exists() && expect > 0 && outFile.length() == expect) {
                    return outFile.absolutePath
                }
                outFile.outputStream().use { output -> input.copyTo(output, 1024 * 256) }
            } ?: return null
            outFile.absolutePath
        } catch (e: Exception) {
            Log.w("PerchPlay", "resolveUriToPath failed: $e")
            null
        }
    }

    /**
     * 清理「从外部 App 打开」产生的缓存副本。
     *
     * 策略：
     *  - 删除 3 天前的文件（用户早就不会再用）
     *  - 若目录总大小超过 2GB，按最后修改时间从旧到新删到低于上限
     *
     * 不能立刻删刚复制的那份 —— 播放器可能正在读它。
     */
    private fun cleanOldOpened(dir: File) {
        try {
            val files = dir.listFiles()?.filter { it.isFile } ?: return
            if (files.isEmpty()) return

            val now = System.currentTimeMillis()
            val maxAge = 3L * 24 * 60 * 60 * 1000
            val maxTotal = 2L * 1024 * 1024 * 1024 // 2GB

            // 1) 太旧的直接删
            var alive = ArrayList<File>()
            for (f in files) {
                if (now - f.lastModified() > maxAge) {
                    f.delete()
                } else {
                    alive.add(f)
                }
            }

            // 2) 总量超限 → 由旧到新删
            var total = alive.sumOf { it.length() }
            if (total <= maxTotal) return
            alive.sortBy { it.lastModified() }
            for (f in alive) {
                if (total <= maxTotal) break
                val len = f.length()
                if (f.delete()) total -= len
            }
        } catch (_: Exception) {
        }
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) c.getString(idx) else null
            } else null
        }
    } catch (_: Exception) {
        null
    }

    private fun querySize(uri: Uri): Long = try {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0) c.getLong(idx) else 0L
            } else 0L
        } ?: 0L
    } catch (_: Exception) {
        0L
    }

    override fun onPostResume() {
        super.onPostResume()
        // 高刷新率适配：请求当前分辨率下刷新率最高的显示模式
        applyHighRefreshRate()
    }

    /**
     * 在 60/90/120/144Hz 屏幕上以最高可用刷新率渲染。
     *
     * 只在刷新率确实更高时才切换，避免不必要的模式切换与耗电。
     */
    private fun applyHighRefreshRate() {
        try {
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            } ?: return

            val current = display.mode ?: return
            val best = display.supportedModes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                        it.physicalHeight == current.physicalHeight
                }
                .maxByOrNull { it.refreshRate } ?: return

            if (best.refreshRate > current.refreshRate + 0.1f) {
                window.attributes = window.attributes.apply {
                    preferredDisplayModeId = best.modeId
                }
            }
        } catch (_: Exception) {
            // 部分 ROM 不支持，忽略
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ────────── 通用 Native 方法 ──────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ── 电池优化白名单 ──
                    "requestBatteryOptimization" -> {
                        requestBatteryOptimization()
                        result.success(true)
                    }

                    // ── 悬浮窗权限 ──
                    "requestOverlayPermission" -> {
                        requestOverlayPermission()
                        result.success(true)
                    }

                    // ── 自启动引导 ──
                    "requestAutoStart" -> {
                        openAutoStartSettings()
                        result.success(true)
                    }

                    // ── 外部 App 打开视频（文件管理器 / 相册「用其他应用打开」）──
                    //
                    // Dart 启动后调用一次：拿到冷启动时挂着的 URI（并清空）。
                    // 返回 null 表示这次是正常启动（桌面图标点进来的）。
                    "getLaunchVideoUri" -> {
                        val u = pendingVideoUri
                        pendingVideoUri = null
                        result.success(u)
                    }

                    // Dart 侧注册回调通道，之后热启动的 Intent 会通过
                    // channel.invokeMethod("openVideoUri", ...) 主动推过来。
                    //
                    // 时序兜底：如果 onNewIntent 在 Dart 注册之前就触发了，
                    // 那时 pendingChannel 还是 null、URI 只存在 pendingVideoUri 里；
                    // 而冷启动路径的 getLaunchVideoUri 已经取过一次（可能为空）。
                    // 这里补推一次，避免"热启动打开视频没反应"。
                    "readyForLaunchUri" -> {
                        pendingChannel =
                            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                        val u = pendingVideoUri
                        if (u != null) {
                            pendingVideoUri = null
                            pendingChannel?.invokeMethod("openVideoUri", u)
                        }
                        result.success(true)
                    }

                    // 把 content:// 解析成可播放的本地路径（必要时拷贝到缓存）
                    "resolveVideoUri" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.success(null)
                        } else {
                            Thread {
                                val path = resolveUriToPath(uri)
                                runOnUiThread { result.success(path) }
                            }.start()
                        }
                    }

                    // ── 打开应用设置 ──
                    "openAppSettings" -> {
                        openAppSettings()
                        result.success(true)
                    }

                    // ── 检测 ROM 品牌 ──
                    "getRomBrand" -> {
                        result.success(detectRomBrand())
                    }

                    // ── 检测是否 MIUI ──
                    "isMiui" -> {
                        result.success(isMiui())
                    }

                    // ── 检测是否 EMUI ──
                    "isEmui" -> {
                        result.success(isEmui())
                    }

                    // ── 检测是否 ColorOS ──
                    "isColorOS" -> {
                        result.success(isColorOS())
                    }

                    // ── 检查悬浮窗权限状态 ──
                    "canDrawOverlays" -> {
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Settings.canDrawOverlays(this)
                            } else {
                                true
                            }
                        )
                    }

                    // ── 检查电池优化状态 ──
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }

                    // ── 所有文件访问权限（Android 11+ 的 MANAGE_EXTERNAL_STORAGE）──
                    "hasAllFilesAccess" -> {
                        result.success(hasAllFilesAccess())
                    }

                    // ── 设备型号 / 系统（Dart 侧品牌识别用，缺了会导致
                    //    「系统优化」整块功能不显示）──
                    "getDeviceModel" -> {
                        result.success(
                            "${Build.MANUFACTURER} ${Build.MODEL}".trim()
                        )
                    }
                    "getSystemName" -> {
                        result.success("Android ${Build.VERSION.RELEASE}")
                    }

                    // ── 后台播放前台服务 ──
                    // 之前 Dart 侧从未启动过这个服务，「后台播放」开关等于空转；
                    // 现在按设置真正启停（持前台服务才能在息屏/内存回收下继续播）
                    "startBackgroundService" -> {
                        result.success(startBackgroundService())
                    }
                    "stopBackgroundService" -> {
                        result.success(stopBackgroundService())
                    }

                    // ── SSDP 组播锁 ──
                    // Android 默认会丢弃未持有 MulticastLock 的组播包，
                    // 没有它投屏搜设备永远搜不到
                    "acquireMulticastLock" -> {
                        result.success(acquireMulticast())
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticast()
                        result.success(true)
                    }

                    // ── 直接跳到「所有文件访问」授权开关页 ──
                    "requestAllFilesAccess" -> {
                        openAllFilesAccessSettings()
                        result.success(true)
                    }

                    // ── 用 MediaStore 索引取全部视频（毫秒级，带时长/分辨率）──
                    "queryMediaStoreVideos" -> {
                        result.success(queryMediaStoreVideos())
                    }

                    // ── 文件被删除后让媒体库索引收敛（相册/其他播放器别再看到）──
                    "notifyMediaDeleted" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(notifyMediaDeleted(path))
                    }

                    else -> result.notImplemented()
                }
            }

        // ────────── 画中画 ──────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPip" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val params = android.app.PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(16, 9))
                                .setAutoEnterEnabled(true)
                                .setSeamlessResizeEnabled(true)
                                .build()
                            enterPictureInPictureMode(params)
                        }
                        result.success(true)
                    }
                    "isPipSupported" -> {
                        result.success(
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            packageManager.hasSystemFeature(
                                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ──────────────────────────────
    // 后台播放前台服务
    // ──────────────────────────────

    private fun startBackgroundService(): Boolean {
        return try {
            val intent = Intent(this, BackgroundAudioService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "start background service failed", e)
            false
        }
    }

    private fun stopBackgroundService(): Boolean {
        return try {
            stopService(Intent(this, BackgroundAudioService::class.java))
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "stop background service failed", e)
            false
        }
    }

    // ──────────────────────────────
    // SSDP 组播锁
    // ──────────────────────────────

    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticast(): Boolean {
        return try {
            if (multicastLock?.isHeld == true) return true
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("perchplay_cast").apply {
                setReferenceCounted(false)
                acquire()
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "acquire multicast lock failed", e)
            false
        }
    }

    private fun releaseMulticast() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticast()
        super.onDestroy()
    }

    // ──────────────────────────────
    // 所有文件访问权限 + MediaStore 扫描
    // ──────────────────────────────

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    /**
     * 跳到系统「所有文件访问权限」开关页（其他播放器也是这么做的）。
     * 部分 ROM 没有应用级页面，退回总列表页。
     */
    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            openAppSettings()
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
                openAppSettings()
            }
        }
    }

    /**
     * 用系统媒体库索引查询视频。
     *
     * 比逐个目录遍历快几个数量级，而且自带时长/分辨率/修改时间，
     * 不用再为每个文件单独 stat 和探测。
     */
    private fun queryMediaStoreVideos(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.WIDTH,
            MediaStore.Video.Media.HEIGHT,
            MediaStore.Video.Media.BUCKET_DISPLAY_NAME
        )
        try {
            contentResolver.query(
                collection, projection, null, null,
                "${MediaStore.Video.Media.DATE_MODIFIED} DESC"
            )?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val dataCol = c.getColumnIndex(MediaStore.Video.Media.DATA)
                val nameCol = c.getColumnIndex(MediaStore.Video.Media.DISPLAY_NAME)
                val sizeCol = c.getColumnIndex(MediaStore.Video.Media.SIZE)
                val durCol = c.getColumnIndex(MediaStore.Video.Media.DURATION)
                val dateCol = c.getColumnIndex(MediaStore.Video.Media.DATE_MODIFIED)
                val wCol = c.getColumnIndex(MediaStore.Video.Media.WIDTH)
                val hCol = c.getColumnIndex(MediaStore.Video.Media.HEIGHT)
                val bucketCol =
                    c.getColumnIndex(MediaStore.Video.Media.BUCKET_DISPLAY_NAME)

                while (c.moveToNext()) {
                    // 真实路径：授予「所有文件访问」后 DATA 才有值
                    val path = if (dataCol >= 0 && !c.isNull(dataCol)) {
                        c.getString(dataCol)
                    } else {
                        null
                    } ?: continue
                    val name = if (nameCol >= 0 && !c.isNull(nameCol)) {
                        c.getString(nameCol)
                    } else {
                        path.substringAfterLast('/')
                    }
                    out.add(
                        mapOf(
                            "id" to c.getLong(idCol),
                            "path" to path,
                            "name" to name,
                            "size" to if (sizeCol >= 0) c.getLong(sizeCol) else 0L,
                            "duration" to if (durCol >= 0) c.getLong(durCol) else 0L,
                            "dateModified" to
                                (if (dateCol >= 0) c.getLong(dateCol) * 1000L else 0L),
                            "width" to if (wCol >= 0) c.getInt(wCol) else 0,
                            "height" to if (hCol >= 0) c.getInt(hCol) else 0,
                            "bucket" to
                                (if (bucketCol >= 0 && !c.isNull(bucketCol))
                                    c.getString(bucketCol) else null)
                        )
                    )
                }
            }
        } catch (e: Exception) {
            return emptyList()
        }
        return out
    }

    // ──────────────────────────────
    // 媒体库索引收敛
    // ──────────────────────────────

    /**
     * 通知系统媒体库「这个路径的文件已经不在了」。
     *
     * 直接在应用内删文件不会同步更新 MediaStore：相册和其它播放器还能看到
     * 一条指向不存在文件的记录。MediaScannerConnection.scanFile 会让系统重新
     * 扫这个路径，文件不存在时系统自己把索引记录删掉 —— 这正是删除文件后
     * 应该走的通道（不需要额外依赖，也不需要媒体写入权限）。
     *
     * 再补发一次旧的 ACTION_MEDIA_SCANNER_SCAN_FILE 广播：个别老 ROM 的媒体
     * 库只响应广播。Android 10+ 对该广播已废弃且可能抛异常，这里整段吞掉，
     * 主通道（scanFile）不受影响。
     */
    @Suppress("DEPRECATION")
    private fun notifyMediaDeleted(path: String): Boolean {
        if (path.isEmpty()) return false
        return try {
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(path),
                null
            ) { _, _ -> }
            try {
                sendBroadcast(
                    Intent(
                        Intent.ACTION_MEDIA_SCANNER_SCAN_FILE,
                        Uri.fromFile(java.io.File(path))
                    )
                )
            } catch (_: Exception) {
                // 新系统上该广播已不可用，忽略：scanFile 已经通知过了
            }
            true
        } catch (e: Exception) {
            Log.w("PerchPlay", "notify media deleted failed", e)
            false
        }
    }

    // ──────────────────────────────
    // 中国 ROM 适配方法
    // ──────────────────────────────

    private fun requestBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    // 部分 ROM 不支持 → 打开应用设置
                    openAppSettings()
                }
            }
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    ).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    openAppSettings()
                }
            }
        }
    }

    /**
     * 引导用户打开自启动设置
     * MIUI/EMUI/ColorOS/OriginOS 路径各不相同
     */
    private fun openAutoStartSettings() {
        try {
            when {
                isMiui() -> {
                    // MIUI 自启动管理
                    val intent = Intent().apply {
                        setClassName(
                            "com.miui.securitycenter",
                            "com.miui.permcenter.autostart.AutoStartManagementActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
                isEmui() -> {
                    // 华为手机管家启动管理
                    val intent = Intent().apply {
                        setClassName(
                            "com.huawei.systemmanager",
                            "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
                isColorOS() -> {
                    // OPPO/一加 自启动
                    val intent = Intent().apply {
                        setClassName(
                            "com.coloros.safecenter",
                            "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                        )
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(intent)
                        return
                    } catch (_: Exception) { }
                }
            }
            // fallback
            openAppSettings()
        } catch (_: Exception) {
            openAppSettings()
        }
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        } catch (_: Exception) { }
    }

    // ──────────────────────────────
    // ROM 检测
    // ──────────────────────────────

    private fun detectRomBrand(): String {
        return when {
            isMiui() -> "MIUI"
            isEmui() -> "EMUI"
            isColorOS() -> "ColorOS"
            Build.MANUFACTURER.equals("vivo", ignoreCase = true) -> "OriginOS"
            else -> Build.MANUFACTURER ?: "Unknown"
        }
    }

    private fun isMiui(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val miuiVersion = get.invoke(c, "ro.miui.ui.version.name") as? String
            miuiVersion != null && miuiVersion.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }

    private fun isEmui(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val emuiVersion = get.invoke(c, "ro.build.version.emui") as? String
            emuiVersion != null && emuiVersion.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }

    private fun isColorOS(): Boolean {
        return try {
            val c = Class.forName("android.os.SystemProperties")
            val get = c.getMethod("get", String::class.java)
            val version = get.invoke(c, "ro.build.version.opporom") as? String
            version != null && version.isNotBlank()
        } catch (_: Exception) {
            false
        }
    }
}