package com.vidflow.player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vidflow/native"
    private val PIP_CHANNEL = "com.vidflow/pip"

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
