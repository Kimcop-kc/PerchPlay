import 'package:flutter/material.dart';

/// 统一响应式断点管理
class AppBreakpoints {
  AppBreakpoints._();

  /// 手机竖屏上限
  static const double mobileMaxWidth = 600;

  /// 平板竖屏上限 / 小屏平板
  static const double tabletMaxWidth = 900;

  /// 平板横屏 / 大屏桌面
  static const double desktopMinWidth = 1200;

  // ────────── 便捷检测 ──────────

  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < mobileMaxWidth;

  static bool isTablet(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= mobileMaxWidth && w < desktopMinWidth;
  }

  static bool isDesktopOrLandscape(BuildContext context) =>
      MediaQuery.of(context).size.width >= desktopMinWidth;

  static bool isLandscape(BuildContext context) =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  static bool isLargeScreen(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletMaxWidth;

  // ────────── 网格列数 ──────────

  static int gridColumns(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= desktopMinWidth) return 5;
    if (w >= tabletMaxWidth) return 4;
    if (w >= mobileMaxWidth) return 3;
    return 2;
  }

  // ────────── 内容水平内边距 ──────────

  static double horizontalPadding(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= desktopMinWidth) return w * 0.12;
    if (w >= tabletMaxWidth) return 32;
    if (w >= mobileMaxWidth) return 24;
    return 12;
  }

  // ────────── 详情面板比例 ──────────

  static double detailPaneRatio(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= desktopMinWidth) return 0.55;
    if (w >= tabletMaxWidth) return 0.50;
    return 0.45;
  }

  // ────────── 卡片宽高比 ──────────

  static double cardAspectRatio(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w >= tabletMaxWidth) return 0.62;
    if (w >= mobileMaxWidth) return 0.65;
    return 0.68;
  }
}

/// 封装 MediaQuery -> Size + Orientation 的轻量 widget
class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, Size size, Orientation orientation)
      builder;

  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return builder(context, media.size, media.orientation);
  }
}