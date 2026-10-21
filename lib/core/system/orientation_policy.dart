import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 屏幕方向策略 —— 全应用唯一入口
///
/// 踩过的坑：`SystemChrome.setPreferredOrientations` 只是设置
/// 「允许的方向列表」。如果列表里已经包含设备**当前**的方向，
/// 系统不会触发旋转。所以在平板上想强制横屏，必须只写横屏；
/// 写四个方向等于没限制（这就是之前平板横放却仍是竖屏界面的原因）。
///
/// 设备类型用**物理屏幕**判断（`physicalSize` 不随当前旋转变化）：
///   - 手机：1080×2400 → 宽 < 高 → 竖屏设备
///   - 平板：2560×1600 → 宽 > 高 → 横屏设备
///
/// 策略：
///   - 手机：非播放页锁竖屏（首页/文件夹/列表/历史/NAS/设置都是竖屏设计）
///   - 平板：跟随物理方向，让横屏真正铺满屏幕
class OrientationPolicy {
  OrientationPolicy._();

  /// 是否为「物理横屏」设备（平板）。物理尺寸不受当前旋转影响。
  static bool get isLandscapeDevice {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width > view.physicalSize.height;
  }

  /// 非播放页（首页/文件夹/列表/历史/NAS/设置）
  ///
  /// 手机 → 锁竖屏：这些页面都是竖屏设计的，横过来控件会错乱；
  /// 平板 → 不加限制：锁竖屏会让平板横放时被系统加黑边，
  ///        画面缩成竖条、导航栏挤到侧边（就是之前的 bug）。
  static Future<void> applyIdle() {
    if (isLandscapeDevice) {
      return SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    return SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  /// 进入播放页
  ///
  /// 按用户设置的方向偏好（auto/landscape/portrait）决定：
  ///  - auto：平板只横屏（只写横屏才会触发旋转），手机四方向全开
  ///  - landscape：强制横屏进入
  ///  - portrait：强制竖屏进入
  static Future<void> applyPlayer({String orientation = 'auto'}) {
    switch (orientation) {
      case 'landscape':
        return SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      case 'portrait':
        return SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      case 'auto':
      default:
        if (isLandscapeDevice) {
          return SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
        return SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
    }
  }

  /// 播放页全屏（沉浸横屏）
  static Future<void> applyFullscreen() {
    return SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
}
