import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 原生平台桥接服务
/// 调用 Android/iOS 原生方法处理 ROM 特定需求
class NativeBridgeService {
  NativeBridgeService._();
  static final instance = NativeBridgeService._();

  static const _channel = MethodChannel('com.vidflow/native');
  static const _pipChannel = MethodChannel('com.vidflow/pip');

  // ──────────── ROM 检测 ────────────

  Future<String> getRomBrand() async {
    try {
      return await _channel.invokeMethod('getRomBrand') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<bool> isMiui() async {
    try {
      return await _channel.invokeMethod('isMiui') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEmui() async {
    try {
      return await _channel.invokeMethod('isEmui') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isColorOS() async {
    try {
      return await _channel.invokeMethod('isColorOS') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 权限请求 ────────────

  /// 请求忽略电池优化（小米/华为/OPPO/vivo 需要）
  Future<bool> requestBatteryOptimization() async {
    try {
      return await _channel.invokeMethod('requestBatteryOptimization') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求悬浮窗权限（中国 ROM 默认禁止）
  Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod('requestOverlayPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开自启动设置
  Future<bool> requestAutoStart() async {
    try {
      return await _channel.invokeMethod('requestAutoStart') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开应用设置
  Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod('openAppSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 检查悬浮窗权限状态
  Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod('canDrawOverlays') ?? false;
    } catch (_) {
      return true; // iOS 默认 true
    }
  }

  /// 检查电池优化豁免状态
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return true; // iOS 默认 true
    }
  }

  // ──────────── 所有文件访问权限 / MediaStore ────────────

  /// 是否已获得「所有文件访问权限」（Android 11+ 的 MANAGE_EXTERNAL_STORAGE）
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod('hasAllFilesAccess') ?? false;
    } catch (_) {
      return true; // iOS 无需该权限
    }
  }

  /// 直接跳到系统「所有文件访问」授权开关页
  Future<void> requestAllFilesAccess() async {
    try {
      await _channel.invokeMethod('requestAllFilesAccess');
    } catch (_) {}
  }

  /// 用系统媒体库索引查询全部视频（快，且带时长/分辨率）
  Future<List<Map<String, dynamic>>> queryMediaStoreVideos() async {
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('queryMediaStoreVideos');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 告诉系统媒体库：这个路径的文件已经被删除了
  ///
  /// 为什么需要：直接 `File.delete()` 不会更新 MediaStore 索引，相册和其它
  /// 播放器还能看到一条指向不存在文件的记录（点开就是黑屏/报错）。
  /// 原生侧用 MediaScannerConnection 重新扫这个路径，文件不存在时系统会
  /// 自己把索引记录收敛掉 —— 这是系统给的标准通道，不需要额外依赖/权限。
  ///
  /// 失败（非 Android、通道异常、ROM 不响应）时返回 false 并忽略：
  /// 文件已经删掉了，这里只是"顺手通知"，不该让删除操作报错。
  Future<bool> notifyMediaDeleted(String path) async {
    if (kIsWeb) return false;
    if (path.trim().isEmpty) return false;
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'notifyMediaDeleted',
        {'path': path},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 设备信息 ────────────

  Future<String> getDeviceModel() async {
    try {
      return await _channel.invokeMethod('getDeviceModel') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<String> getSystemName() async {
    try {
      return await _channel.invokeMethod('getSystemName') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<bool> isIPad() async {
    try {
      return await _channel.invokeMethod('isIPad') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isIPadPro() async {
    try {
      return await _channel.invokeMethod('isIPadPro') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> supportStageManager() async {
    try {
      return await _channel.invokeMethod('supportStageManager') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> support120Hz() async {
    try {
      return await _channel.invokeMethod('support120Hz') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 后台播放前台服务 ────────────

  /// 启动前台服务（息屏/内存回收下继续播放，并显示通知）
  Future<bool> startBackgroundService() async {
    try {
      return await _channel.invokeMethod('startBackgroundService') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopBackgroundService() async {
    try {
      return await _channel.invokeMethod('stopBackgroundService') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── SSDP 组播锁 ────────────

  /// 获取 Wi-Fi 组播锁（Android 不持锁会丢弃组播包，投屏搜不到设备）
  Future<bool> acquireMulticastLock() async {
    try {
      return await _channel.invokeMethod('acquireMulticastLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> releaseMulticastLock() async {
    try {
      await _channel.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }

  // ──────────── 画中画 ────────────

  Future<bool> enterPiP() async {
    try {
      return await _pipChannel.invokeMethod('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isPipSupported() async {
    try {
      return await _pipChannel.invokeMethod('isPipSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 一键优化（批量请求权限） ────────────

  /// 针对中国品牌 ROM 的一键优化：
  /// 1. 电池优化白名单
  /// 2. 悬浮窗权限
  /// 3. 自启动（华为/OPPO/vivo）
  Future<void> oneClickOptimize() async {
    await requestBatteryOptimization();
    // 延迟以便上一个设置页面打开
    await Future.delayed(const Duration(milliseconds: 500));
    await requestOverlayPermission();
    await Future.delayed(const Duration(milliseconds: 500));
    await requestAutoStart();
  }
}