import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/glass_theme.dart';
import '../../providers/ui_settings_provider.dart';

/// 按设置决定是否做实时模糊
///
/// 默认开启（液态玻璃观感的主要来源）。关掉只是给低端机省电的选项，
/// 性能优化本身不依赖关闭它。
Widget _withOptionalBlur({required bool blur, required Widget child}) {
  if (!blur) return child;
  return BackdropFilter(
    filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
    child: child,
  );
}

/// 液态玻璃导航底栏
///
/// 毛玻璃轨道 + 浮起透镜气泡（tab 间平滑滑动）+ 彩虹折射边缘 + 投影。
/// Android 不依赖 BackdropFilter（GPU 兼容），改用多层半透明渐变模拟毛玻璃。
class GlassNavBar extends ConsumerStatefulWidget {
  final List<NavBarItem> items;
  final String currentRoute;
  final double height;

  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentRoute,
    this.height = 64,
  });

  @override
  ConsumerState<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends ConsumerState<GlassNavBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  int _currentIndex = 0;
  int _prevIndex = 0;

  // 气泡尺寸（随 slotW 动态计算，见 build）
  double _bubbleW = 56.0;
  double _bubbleH = 40.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = _resolveIndex();
    _prevIndex = _currentIndex;
    // 单一动画源：气泡位移、伸缩、图标缩放、文字变色全部由它驱动，
    // 曲线与时长完全一致，避免「气泡到了、图标还在变」的脱节感。
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant GlassNavBar old) {
    super.didUpdateWidget(old);
    final newIdx = _resolveIndex();
    if (newIdx != _currentIndex) {
      _prevIndex = _currentIndex;
      _currentIndex = newIdx;
      _slideCtrl.forward(from: 0.0);
    }
  }

  int _resolveIndex() {
    // 精确匹配
    for (int i = 0; i < widget.items.length; i++) {
      if (widget.items[i].route == widget.currentRoute) return i;
    }
    // 子页面（如 /playlist/xxx）仍高亮对应标签
    for (int i = 0; i < widget.items.length; i++) {
      final r = widget.items[i].route;
      if (r != '/' && widget.currentRoute.startsWith('$r/')) return i;
    }
    return 0;
  }

  double _slotCenterX(int index, double slotW) {
    return slotW * index + slotW / 2;
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final navH = widget.height + bottomSafe + 8.0;

    return Container(
      height: navH,
      padding: EdgeInsets.fromLTRB(12, 6, 12, bottomSafe > 0 ? bottomSafe : 6),
      child: LayoutBuilder(
        builder: (context, box) {
          final trackW = box.maxWidth;
          final trackH = box.maxHeight;
          final slotW = trackW / widget.items.length;
          // 气泡宽度 = slot 的 72%（留出 tab 间距），高度 = 宽 × 0.72
          _bubbleW = (slotW * 0.72).clamp(40.0, 72.0);
          _bubbleH = (_bubbleW * 0.72).clamp(32.0, 52.0);
          final startCx = _slotCenterX(_prevIndex, slotW);
          final endCx = _slotCenterX(_currentIndex, slotW);

          // fit: expand 让轨道填满完整高度（否则 Stack 高度被 Row 的
          // 32px 图标文字撑起，轨道会塌缩成一条细线）
          return Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              // ── 轨道：毛玻璃底板 ──
              // RepaintBoundary：气泡每帧移动时不会强制重算背后的模糊，
              // 否则每帧都要重新做一次 BackdropFilter，掉帧明显
              const RepaintBoundary(child: _GlassTrack()),

              // 气泡 + 图标文字统一由同一条动画驱动
              AnimatedBuilder(
                animation: _slideCtrl,
                builder: (context, _) {
                  final t = _navCurve.transform(_slideCtrl.value);
                  final cx = startCx + (endCx - startCx) * t;

                  return Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: [
                      // ── 浮起透镜气泡 ──
                      Positioned(
                        left: 0,
                        top: (trackH - _bubbleH) / 2,
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: Transform.translate(
                              offset: Offset(cx - _bubbleW / 2, 0),
                              // 液滴形变：沿运动方向拉伸、垂直方向压缩，
                              // 与位移同一条曲线（sin 一次起落，回位无抖动）
                              child: Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..scale(
                                      1.0 + 0.075 * math.sin(math.pi * t),
                                      1.0 - 0.055 * math.sin(math.pi * t)),
                                child: _LensBubble(
                                  width: _bubbleW,
                                  height: _bubbleH,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // ── 图标文字层（进度来自同一条动画） ──
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List.generate(widget.items.length, (i) {
                          final progress = i == _currentIndex
                              ? t
                              : (i == _prevIndex ? 1 - t : 0.0);
                          return Expanded(
                            child: _NavLabel(
                              item: widget.items[i],
                              progress: progress.clamp(0.0, 1.0),
                              onTap: () {
                                if (i != _currentIndex) {
                                  widget.items[i].onTap?.call();
                                }
                              },
                            ),
                          );
                        }),
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  /// 统一曲线：两端都平滑（无冲刺、无拖尾），中段接近匀速。
  static const _navCurve = Curves.easeInOutCubic;
}

// ═══════════════ 毛玻璃轨道 ═══════════════
//
// BackdropFilter 毛玻璃模糊 + 轻薄白色叠加。
// 所有页面统一这一套参数（首页与其他页一致，避免 UI 割裂感）。

class _GlassTrack extends ConsumerWidget {
  const _GlassTrack();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 实时模糊默认开启（液态玻璃观感核心），低端机可在设置里关闭
    final blur = ref.watch(glassBlurProvider);

    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: _withOptionalBlur(
          blur: blur,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(blur ? 0.55 : 0.72),
                  Colors.white.withOpacity(blur ? 0.35 : 0.55),
                ],
              ),
              border: Border.all(
                color: Colors.white.withOpacity(0.60),
                width: 0.7,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              children: [
                // 顶部高光带（玻璃反光）
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 16,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(28)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withOpacity(0.40),
                          Colors.white.withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                ),

                // 顶部棱线：一道细亮线 + 两端淡出（光打在玻璃上沿）
                Positioned(
                  top: 0,
                  left: 34,
                  right: 34,
                  height: 1.2,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.white.withOpacity(0.0),
                            Colors.white.withOpacity(0.85),
                            Colors.white.withOpacity(0.0),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),

                // 底部内侧阴影：玻璃厚度（Flutter 无 inset shadow，用渐变模拟）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 18,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(28)),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withOpacity(0.07),
                            Colors.black.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // 色散边缘：极淡暖/冷分离，提示"折射"而非单纯模糊
                Positioned(
                  top: 0,
                  left: 60,
                  right: 150,
                  height: 1.0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            const Color(0xFFFFC46B).withOpacity(0.22),
                            const Color(0xFFFFC46B).withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 150,
                  right: 60,
                  height: 1.0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            const Color(0x7B6CF6).withOpacity(0.0),
                            const Color(0x7B6CF6).withOpacity(0.24),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════ 透镜气泡 ═══════════════
//
// 干净的白色液态玻璃气泡（参考 iOS Liquid Glass 选中态）：
// 白色半透主体（上亮下暗的玻璃厚度）+ 白色描边 + 顶部高光 + 投影。
// 无彩虹色，靠白色高光和投影塑造「凸起透镜」质感。

class _LensBubble extends StatelessWidget {
  final double width;
  final double height;
  const _LensBubble({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    final r = height * 0.5;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        // 玻璃主体：左上受光偏亮、右下偏暗 → 体积感
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.88),
            Colors.white.withOpacity(0.60),
            Colors.white.withOpacity(0.34),
          ],
          stops: const [0.0, 0.42, 1.0],
        ),
        boxShadow: [
          // 投影：玻璃浮在内容之上
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
          // 下方近距离接触阴影，压出"贴合"感
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Stack(
          children: [
            // ── 边缘镜面高光：顶部一道细亮弧（两端淡出，像光打在玻璃棱上）──
            Positioned(
              top: 0,
              left: r * 0.55,
              right: r * 0.55,
              height: 1.4,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.white.withOpacity(0.0),
                      Colors.white.withOpacity(0.95),
                      Colors.white.withOpacity(0.0),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),

            // ── 高光晕（棱线下方柔和扩散）──
            Positioned(
              top: 1,
              left: r * 0.4,
              right: r * 0.4,
              height: height * 0.34,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withOpacity(0.55),
                        Colors.white.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── 厚度：底部内侧阴影（Flutter 没有 inset shadow，用渐变模拟）──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: height * 0.42,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.10),
                        Colors.black.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── 色散：边缘极淡的冷/暖色分离，模拟玻璃折射边缘 ──
            Positioned(
              top: 0,
              left: r * 0.3,
              right: r * 0.9,
              height: 1.0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        const Color(0xFFFFC46B).withOpacity(0.30), // 暖（琥珀）
                        const Color(0xFFFFC46B).withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: r * 0.9,
              right: r * 0.3,
              height: 1.0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        const Color(0x7B6CF6).withOpacity(0.0), // 冷（蓝紫）
                        const Color(0x7B6CF6).withOpacity(0.32),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── 左上角聚光斑（caustic）：玻璃厚处的亮点 ──
            Positioned(
              left: r * 0.18,
              top: -height * 0.22,
              child: Container(
                width: width * 0.42,
                height: height * 0.62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withOpacity(0.42),
                      Colors.white.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),

            // ── 底部微反光（内容透过玻璃后的回光）──
            Positioned(
              bottom: 1,
              left: 10,
              right: 10,
              height: 2.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.white.withOpacity(0.28),
                      Colors.white.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),

            // 内描边（贴边一圈极淡白线，闭合并强化边缘）
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(r),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.55),
                      width: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════ 图标文字标签 ═══════════════

/// 纯展示组件：进度由父级那条统一动画传入（0=未选中，1=选中），
/// 自己不持动画控制器，因此与气泡位移天然同步。
class _NavLabel extends StatelessWidget {
  final NavBarItem item;
  final double progress;
  final VoidCallback onTap;

  const _NavLabel({
    required this.item,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = progress.clamp(0.0, 1.0);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Transform.scale(
        scale: 0.90 + 0.10 * t,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              item.icon,
              color: Color.lerp(
                GlassTheme.textTertiary,
                GlassTheme.accentPurple,
                t,
              ),
              size: 18 + 4 * t,
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 9 + 1.5 * t,
                // 字重渐变用 Color.lerp 之外的方式会跳变，这里保留阈值但
                // 只在过半时切换一次，视觉上被缩放/颜色过渡盖住
                fontWeight: t > 0.5 ? FontWeight.w700 : FontWeight.w400,
                color: Color.lerp(
                  GlassTheme.textTertiary,
                  GlassTheme.accentPurple,
                  t,
                ),
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════ 数据模型 ═══════════════

class NavBarItem {
  final IconData icon;
  final String label;
  final String route;
  final VoidCallback? onTap;

  const NavBarItem({
    required this.icon,
    required this.label,
    required this.route,
    this.onTap,
  });
}
