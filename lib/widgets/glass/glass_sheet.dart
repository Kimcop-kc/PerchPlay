import 'package:flutter/material.dart';

import '../../core/system/system_ui_policy.dart';
import '../../core/theme/glass_theme.dart';

/// 统一的底部弹窗外壳 —— 全 App 所有底部弹窗都应该走这里。
///
/// 统一收口了全 App 底部弹窗的视觉与行为，避免各页面裸写导致的不一致：
///  1. 纯色背景 [GlassTheme.bg]，圆角 [GlassTheme.radiusXl]
///  2. [useRootNavigator] 弹到根 Navigator，不被应用内底栏（GlassNavBar）遮挡
///  3. 底部安全区用 [SystemUiPolicy.bottomSheetInset]（原生实测值）
///  4. 内容可滚动 + 限高
///  5. 统一的顶部拖拽条、标题、副标题布局
///
/// ## 两种用法
///  - 简单：传 [title]/[subtitle]/[children]，自动生成拖拽条+标题+内容
///  - 自定义：传 [builder]，完全自绘内容（外壳仍统一背景/圆角/安全区/滚动）
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  /// 内容最大高度 = 屏高 × 该系数。默认 0.9。
  double maxHeightFactor = 0.9,
  /// 面板背景色，默认 GlassTheme.bg。
  Color backgroundColor = GlassTheme.bg,
  /// 顶部圆角，默认 radiusXl。
  double topRadius = GlassTheme.radiusXl,
  /// 是否显示顶部拖拽条。默认 true。
  bool showDragHandle = true,
  /// 标题（可选，自动套用统一标题样式）。
  String? title,
  /// 副标题（可选）。
  String? subtitle,
  /// 简单用法下的内容 children。
  List<Widget>? children,
  /// 自定义内容（与 children 二选一）。
  Widget Function(BuildContext ctx)? builder,
  /// 是否弹到根 Navigator。Shell 内页面必须为 true。
  bool useRootNavigator = true,
}) {
  assert((builder != null) != (children != null),
      'showGlassSheet: builder 与 children 只能二选一');
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      final systemBottom = SystemUiPolicy.bottomSheetInset(media);

      final Widget body;
      if (builder != null) {
        body = builder(ctx);
      } else {
        body = _SheetBody(
          showDragHandle: showDragHandle,
          title: title,
          subtitle: subtitle,
          children: children ?? const [],
        );
      }

      return Container(
        constraints: BoxConstraints(
          maxHeight: media.size.height * maxHeightFactor,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(topRadius),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                    20, 16, 20, 20 + systemBottom),
                child: body,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 简单用法下的标准内容布局：拖拽条 + 标题 + 副标题 + children。
class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.showDragHandle,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final bool showDragHandle;
  final String? title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showDragHandle)
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        if (title != null)
          Text(
            title!,
            style: const TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitle!,
              style: const TextStyle(
                color: GlassTheme.textTertiary,
                fontSize: 13,
              ),
            ),
          ),
        if (title != null || subtitle != null) const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}
