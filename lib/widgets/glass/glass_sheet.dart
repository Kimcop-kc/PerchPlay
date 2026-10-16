import 'package:flutter/material.dart';

import '../../core/theme/glass_theme.dart';

/// 统一的底部弹窗外壳
///
/// 解决的实际问题：应用是 edge-to-edge 渲染（内容画到系统栏下面），
/// 横屏时底部会有系统导航栏 / 平板任务栏盖住弹窗的下沿 ——
/// 之前「长按视频」菜单的最后一个按钮（从影库移除）就是这么被挡掉的。
///
/// 这里统一做三件事：
///  1. 底部内边距加上系统栏高度（`viewPadding.bottom`），内容不再被盖住
///  2. 内容可滚动：按钮多 / 字体放大时也能全部够到
///  3. 限高，避免超高内容顶到屏幕最上面
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext ctx) builder,
  double maxHeightFactor = 0.9,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    // 必须为 true，否则高度被系统限制在 9/16，超高内容会被裁掉
    isScrollControlled: true,
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      // 系统栏（导航栏 / 任务栏 / 手势条）高度；edge-to-edge 下由它给出
      final systemBottom = media.viewPadding.bottom;
      return Container(
        constraints: BoxConstraints(
          maxHeight: media.size.height * maxHeightFactor,
        ),
        decoration: const BoxDecoration(
          color: GlassTheme.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          // SafeArea 已经吃掉系统栏高度，这里只补一点视觉留白
          minimum: const EdgeInsets.only(bottom: 20),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(20, 16, 20, systemBottom > 0 ? 8 : 12),
            child: builder(ctx),
          ),
        ),
      );
    },
  );
}
