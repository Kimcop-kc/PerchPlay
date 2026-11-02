import 'package:flutter/material.dart';

import '../../core/theme/glass_theme.dart';

/// 统一的居中对话框外壳 —— 全 App 所有 AlertDialog 都应该走这里。
///
/// 统一了容易写得不一致的点：
///  1. 背景色统一 GlassTheme.bg
///  2. insetPadding 统一 20/24（小屏/键盘弹出时内容不被顶出屏幕）
///  3. 圆角统一 radiusXl
///  4. title/content 默认文字样式
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required Widget title,
  required Widget content,
  List<Widget>? actions,
  bool scrollable = false,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: GlassTheme.bg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassTheme.radiusXl),
      ),
      title: DefaultTextStyle.merge(
        style: const TextStyle(
          color: GlassTheme.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        child: title,
      ),
      content: scrollable
          ? SingleChildScrollView(
              child: DefaultTextStyle.merge(
                style: const TextStyle(
                  color: GlassTheme.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
                child: content,
              ),
            )
          : DefaultTextStyle.merge(
              style: const TextStyle(
                color: GlassTheme.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
              child: content,
            ),
      actions: actions,
    ),
  );
}
