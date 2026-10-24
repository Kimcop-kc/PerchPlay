import 'package:flutter/material.dart';

import '../../core/system/system_ui_policy.dart';
import '../../core/theme/glass_theme.dart';

/// 统一的底部弹窗外壳
///
/// 解决的实际问题：应用是 edge-to-edge 渲染（内容画到系统栏下面），
/// 横屏时底部会有系统导航栏 / 平板任务栏盖住弹窗的下沿 ——
/// 之前「长按视频」菜单的最后一个按钮（从影库移除）就是这么被挡掉的。
///
/// 这里统一做三件事：
///  1. 底部内边距加上**真实**系统栏高度，内容不再被盖住
///  2. 内容可滚动：按钮多 / 字体放大时也能全部够到
///  3. 限高，避免超高内容顶到屏幕最上面
///
/// ⚠ 第 1 点不能用 `viewPadding` / `SafeArea`：
/// Android 8/9 走 manual 模式时它们的 bottom 都是 0，而弹窗仍覆盖整个
/// 物理屏幕，结果就是最后几个按钮被导航栏压住且点不到。
/// 必须用 [SystemUiPolicy.bottomSheetInset]（优先取原生实测值）。
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
      // 真实系统栏高度（含 Android 8 的原生实测兜底）
      final systemBottom = SystemUiPolicy.bottomSheetInset(media);
      return Container(
        constraints: BoxConstraints(
          maxHeight: media.size.height * maxHeightFactor,
        ),
        decoration: const BoxDecoration(
          color: GlassTheme.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // 不用 SafeArea：它在 manual 模式下不给 bottom 留白，
        // 直接用 padding 把系统栏高度补上，行为最可控
        child: Padding(
          padding: EdgeInsets.only(bottom: systemBottom),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: builder(ctx),
          ),
        ),
      );
    },
  );
}
