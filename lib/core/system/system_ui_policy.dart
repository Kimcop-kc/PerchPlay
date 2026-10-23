import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart'
    show Brightness, Color, Colors, MediaQuery, MediaQueryData;
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

  /// 底部浮层（bottomSheet / 弹窗）必须避让的系统栏高度。
  ///
  /// ## 为什么不能直接用 `MediaQuery.padding.bottom`
  ///
  /// 这个值只在「内容延伸到系统栏下方」（edgeToEdge）时才等于导航栏高度。
  /// Android 9 及以下走 `manual` 模式 —— 系统把导航栏区域**从布局里扣掉**，
  /// 于是 `padding.bottom` 变成 **0**。
  ///
  /// 但 `showModalBottomSheet` 是**浮在最上层、覆盖整个物理屏幕**的，
  /// 它不参与那个「扣掉导航栏」的布局计算。所以在 Android 8/9 上：
  ///   - `padding.bottom == 0` → 我们算出「不需要留白」
  ///   - 浮层实际仍贴着屏幕物理底边 → 下半截被导航栏盖住
  ///
  /// 表现正是「二级菜单被导航栏挡住，且挡住的区域点不到、也滑不到」。
  ///
  /// 修法：低版本上额外补一个导航栏高度。用 `viewPadding` 而不是 `padding`，
  /// 因为 `viewPadding` 反映的是**系统栏真实占位**，不受「内容是否延伸」影响。
  static double bottomSheetInset(MediaQueryData mq) {
    // viewPadding 在 edgeToEdge 下就是导航栏高度，在 manual 下也是真实占位
    final view = mq.viewPadding.bottom;
    if (view > 0) return view;
    // 极端兜底：某些 ROM 连 viewPadding 都给 0，但导航栏确实存在
    if (!supportsEdgeToEdge && (kIsWeb ? false : Platform.isAndroid)) {
      return _fallbackNavBarHeight;
    }
    return 0;
  }

  /// 无法从系统拿到导航栏高度时的兜底值。
  ///
  /// 三键导航约 48dp，手势导航约 24dp；取 48 偏保守，
  /// 多留一点空白比被挡住好（挡住会导致按钮点不到）。
  static const double _fallbackNavBarHeight = 48;
}
