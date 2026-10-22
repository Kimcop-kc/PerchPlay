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

    // 订阅实时模糊开关：变更后导航栏整体重建（默认开启）
    final blur = ref.watch(glassBlurProvider);

    return Container(
      height: navH,
      padding: EdgeInsets.fromLTRB(12, 6, 12, bottomSafe > 0 ? bottomSafe : 6),
      // 平板限宽居中：底栏最大 560px，避免在宽屏上 5 个 tab 分散太开
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
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
                  // 注意：Positioned 必须是 Stack 的直接子级，不能再包一层
                  // 别的组件（包了定位会静默失效，轨道会变成全宽直角条）。
                  // RepaintBoundary 放在 Positioned 里面，效果一样：
                  // 气泡每帧移动不会强制重算背后的模糊。
                  Positioned.fill(
                    child: RepaintBoundary(child: _GlassTrack(blur: blur)),
                  ),

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
                                  // 行进中轻微横向拉伸 + 纵向收缩，液态感；
                                  // t 与位移同相，不会出现呼吸和位移错拍
                                  child: Transform(
                                    alignment: Alignment.center,
                                    transform: Matrix4.identity()
                                      // scale() 已弃用，改用 scaleByDouble(x, y, z, w)
                                      ..scaleByDouble(
                                        1.0 + 0.05 * math.sin(math.pi * t),
                                        1.0 - 0.04 * math.sin(math.pi * t),
                                        1.0,
                                        1.0,
                                      ),
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
        ),
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

class _GlassTrack extends StatelessWidget {
  /// 是否做实时模糊（由导航栏顶层 watch 后传入，避免深层订阅漏重绘）
  final bool blur;
  const _GlassTrack({required this.blur});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: _withOptionalBlur(
        blur: blur,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              // 外观与开关无关：关闭只去掉实时模糊，白色叠加/描边/投影
              // 保持一致，避免"关掉就换了个样子"
              colors: [
                Colors.white.withValues(alpha: 0.55),
                Colors.white.withValues(alpha: 0.35),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.60),
              width: 0.7,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
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
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(28)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.40),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ],
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
        // 白色玻璃主体：上亮下暗 → 玻璃厚度
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.85),
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.30),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        // 白色描边：玻璃边缘高光
        border: Border.all(
          width: 1.0,
          color: Colors.white.withValues(alpha: 0.85),
        ),
        boxShadow: [
          // 投影 — 玻璃浮起
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
          // 顶部内发光
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.6),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r - 1),
        child: Stack(
          children: [
            // ── 顶部高光带（凸透镜反光） ──
            Positioned(
              top: 2,
              left: 8,
              right: 8,
              height: 6,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.85),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),

            // ── 底部微反光 ──
            Positioned(
              bottom: 1,
              left: 10,
              right: 10,
              height: 3,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.30),
                      Colors.white.withValues(alpha: 0.0),
                    ],
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
