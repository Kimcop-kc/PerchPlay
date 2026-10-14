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