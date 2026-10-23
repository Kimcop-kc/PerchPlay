import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Brightness, Color, Colors;
import 'package:flutter/services.dart';

import '../../services/native_bridge_service.dart';

/// 系统栏（状态栏 / 导航栏）显示策略。
///
/// 为什么需要按版本分流：
/// `SystemUiMode.edgeToEdge` 是 **Android 10（API 29）** 才支持的模式。
/// 在 Android 8/9 上调用它，系统会退回默认行为——导航栏变成不透明黑条，
/// 而 Flutter 布局仍按「内容延伸到系统栏下方」计算，导致页面底部
/// 被导航栏盖住（用户反馈「安卓8上导航栏会被遮住」）。
///
/// 策略：
/// - Android 10+：edgeToEdge，内容延伸到系统栏下，配合透明系统栏
/// - Android 9 及以下：manual，明确保留状态栏与导航栏，内容不延伸
/// - 非 Android：edgeToEdge（iOS 本来就是这种表现）
class SystemUiPolicy {
  SystemUiPolicy._();

  /// 缓存的 SDK 等级（0 = 未知/非 Android）。
  static int _sdkInt = -1;

  /// 是否支持 edgeToEdge（Android 10+ 或非 Android）。
  static bool get supportsEdgeToEdge {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;
    // 未知时保守按支持处理（真机一般都能读到）
    if (_sdkInt < 0) return true;
    return _sdkInt >= 29;
  }

  /// 读取并缓存 Android SDK 等级（启动时调用一次）。
  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) {
      _sdkInt = 0;
      return;
    }
    try {
      _sdkInt = await NativeBridgeService.instance.getAndroidSdkInt();
    } catch (_) {
      _sdkInt = -1;
    }
  }

  /// 应用「空闲态」（非播放页）的系统栏模式。
  ///
  /// [navigationBarColor] 是导航栏底色，低版本必须给实色，
  /// 否则会显示系统默认黑条。
  static Future<void> applyIdle({
    required Color navigationBarColor,
    required Brightness navigationIconBrightness,
    required Brightness statusBarIconBrightness,
  }) async {
    // 先设样式：低版本靠这个给导航栏上色
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: statusBarIconBrightness,
      systemNavigationBarColor: navigationBarColor,
      systemNavigationBarIconBrightness: navigationIconBrightness,
      systemNavigationBarDividerColor: Colors.transparent,
    ));

    if (supportsEdgeToEdge) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      // Android 9 及以下：明确保留两栏，内容不延伸到导航栏下方，
      // 这样底部不会被遮住。
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  /// 播放页进入沉浸式（全屏播放）。
  ///
  /// 只负责「隐藏系统栏」，**不要**在这里设 overlay style ——
  /// `setSystemUIOverlayStyle` 在部分 Android 版本（尤其 MIUI / EMUI）
  /// 会重新把状态栏拉出来，表现为「设了沉浸但状态栏还在」。样式由调用方
  /// 单独处理，且要在 immersive 之前设好。
  static Future<void> applyImmersive() async {
    // 先确保两栏都不显示，再切模式。
    // 某些 ROM 上单独调 setEnabledSystemUIMode 会被前一次 manual 状态干扰，
    // 先用 manual + 空 overlays 清一次是更稳的写法。
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: const [],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// 播放页退出沉浸式、恢复两栏。
  static Future<void> applyPlayerExit() async {
    if (supportsEdgeToEdge) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }
}
