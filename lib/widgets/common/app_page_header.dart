import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/glass_theme.dart';

/// 统一的页面头部。
///
/// ## 为什么需要它
/// 审计发现各 tab 页各写各的顶部：首页/文件夹用「`padding.top + 16` +
/// 自适应左右留白 + 36px 大标题」，而列表/历史/设置/NAS/投屏用
/// 「`padding.top + 24` + 固定 20 左右 + 28px 标题」——
/// 于是在底栏切换 tab 时，标题的**位置和字号都会跳一下**，视觉上很割裂。
///
/// 这个组件把所有页面收敛到同一套规格：
///  - 顶部留白：`padding.top + 16`（首页/文件夹沿用既有观感）
///  - 左右留白：统一用 [AppBreakpoints.horizontalPadding]
///  - 标题：36px / w800 / 字距 -1.2（与首页一致）
///  - 副标题：可选，14px 紫色半透明
///
/// 支持两种插入方式：
///  - [asSliver] = true  → 返回 Sliver，用于 CustomScrollView
///  - [asSliver] = false → 返回普通 Widget，用于 Column
class AppPageHeader extends StatelessWidget {
  /// 主标题（如「播放列表」「历史」「设置」）。
  final String title;

  /// 副标题。null = 不显示。
  final String? subtitle;

  /// 标题行右侧的控件（按钮/筛选等）。
  final Widget? trailing;

  /// 标题行左侧的控件（独立页面用返回箭头；tab 页留空）。
  final Widget? leading;

  /// 标题行下方的整行内容（如搜索框）。
  final Widget? child;

  /// 是否返回 Sliver（用于 CustomScrollView）。
  final bool asSliver;

  /// 内容与标题行之间的间距。
  final double childGap;

  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leading,
    this.child,
    this.asSliver = true,
    this.childGap = 10,
  });

  @override
  Widget build(BuildContext context) {
    final hp = AppBreakpoints.horizontalPadding(context);
    final topPad = MediaQuery.of(context).padding.top + 16;

    final body = Padding(
      padding: EdgeInsets.fromLTRB(hp, topPad, hp, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: GlassTheme.textPrimary,
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                        height: 1.1,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GlassTheme.accentPurple.withValues(alpha: 0.6),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          if (child != null) ...[
            SizedBox(height: childGap),
            child!,
          ],
        ],
      ),
    );

    return asSliver ? SliverToBoxAdapter(child: body) : body;
  }
}
