package com.vidflow.player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vidflow/native"
    private val PIP_CHANNEL = "com.vidflow/pip"

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

                    // ── 直接跳到「所有文件访问」授权开关页 ──
                    "requestAllFilesAccess" -> {
                        openAllFilesAccessSettings()
                        result.success(true)
                    }

                    // ── 用 MediaStore 索引取全部视频（毫秒级，带时长/分辨率）──
                    "queryMediaStoreVideos" -> {
                        result.success(queryMediaStoreVideos())
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