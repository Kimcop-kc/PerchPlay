import 'package:flutter/material.dart';

/// 统一响应式断点管理
///
/// 只保留**实际被调用**的三个方法。之前还有 isMobile / isTablet /
/// isDesktopOrLandscape / isLandscape / cardAspectRatio / detailPaneRatio
/// 和 ResponsiveBuilder，全项目没有任何引用，已删除 ——
/// 留着会让"改了一处以为生效了"的风险变高。
class AppBreakpoints {
  AppBreakpoints._();

  /// 手机竖屏上限
  static const double mobileMaxWidth = 600;

  /// 平板竖屏上限 / 小屏平板
  static const double tabletMaxWidth = 900;

  /// 平板横屏 / 大屏桌面
  static const double desktopMinWidth = 1200;

  /// 大屏判定（平板及以上）
  static bool isLargeScreen(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletMaxWidth;

  /// 网格列数
  static int gridColumns(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= desktopMinWidth) return 5;
    if (w >= tabletMaxWidth) return 4;
    if (w >= mobileMaxWidth) return 3;
    return 2;
  }

  /// 内容水平内边距
  ///
  /// 原来 ≥1200dp 时返回 `w * 0.12`：1280dp 平板上左右各留 153dp，
  /// 首页网格被挤成中间一小条（5 列时每张卡片只有约 187dp 宽），
  /// 而文件夹页只用 12dp，两个页面观感完全不一致。大屏改为固定值。
  static double horizontalPadding(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= desktopMinWidth) return 40;
    if (w >= tabletMaxWidth) return 32;
    if (w >= mobileMaxWidth) return 24;
    return 12;
  }
}
