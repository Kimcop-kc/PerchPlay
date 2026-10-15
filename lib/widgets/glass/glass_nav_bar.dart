import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';

/// 液态玻璃导航底栏
///
/// 毛玻璃轨道 + 浮起透镜气泡（tab 间平滑滑动）+ 彩虹折射边缘 + 投影。
/// Android 不依赖 BackdropFilter（GPU 兼容），改用多层半透明渐变模拟毛玻璃。
class GlassNavBar extends StatefulWidget {
  final List<NavBarItem> items;
  final String currentRoute;
  final double height;

  /// 是否让内容透过玻璃显示（首页用 true）。
  /// 其他页面用 false：加厚磨砂，避免内容从导航栏下方透出来，
  /// 看起来像「导航栏下面还有一层界面」。
  final bool translucent;

  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentRoute,
    this.height = 64,
    this.translucent = false,
  });

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
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
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 440),
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
    for (int i = 0; i < widget.items.length; i++) {
      if (widget.items[i].route == widget.currentRoute) return i;
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
              _GlassTrack(translucent: widget.translucent),

              // ── 浮起透镜气泡 ──
              // Positioned 必须是 Stack 直接子级才能生效；
              // 动画在内部用 Transform.translate 做水平滑动。
              Positioned(
                left: 0,
                top: (trackH - _bubbleH) / 2,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _slideCtrl,
                    builder: (context, _) {
                      final raw = _slideCtrl.value;
                      final t = _springEval(raw);
                      final cx = startCx + (endCx - startCx) * t;
                      // 行进中轻微收缩再回弹，液态感更顺（正弦一次起落，无抖动）
                      final breathe = 1 - 0.045 * math.sin(math.pi * raw);
                      return Transform.translate(
                        offset: Offset(cx - _bubbleW / 2, 0),
                        child: Transform.scale(
                          scale: breathe,
                          child: _LensBubble(
                            width: _bubbleW,
                            height: _bubbleH,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // ── 图标文字层 ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(widget.items.length, (i) {
                  return Expanded(
                    child: _NavLabel(
                      item: widget.items[i],
                      isActive: i == _currentIndex,
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
    );
  }

  /// 平滑减速曲线（临界阻尼，无回弹过冲）
  ///
  /// 之前的弹簧会明显过冲，滑动时看着「跳」；这里用单调收敛的
  /// 临界阻尼响应，并在末端归一化，保证精确停在目标位置。
  double _springEval(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const k = 9.0;
    double raw(double x) => 1 - (1 + k * x) * math.exp(-k * x);
    return (raw(t) / raw(1)).clamp(0.0, 1.0);
  }
}

// ═══════════════ 毛玻璃轨道 ═══════════════
//
// BackdropFilter 毛玻璃模糊 + 白色叠加。
// translucent=true（首页）：白色叠加轻薄，背后滚动的内容透过模糊可见；
// translucent=false（其他页）：叠加加厚，背后内容不再显形，
// 否则会像「导航栏下面还有一层界面」。

class _GlassTrack extends StatelessWidget {
  final bool translucent;
  const _GlassTrack({required this.translucent});

  @override
  Widget build(BuildContext context) {
    final topWhite = translucent ? 0.55 : 0.90;
    final bottomWhite = translucent ? 0.35 : 0.80;
    final blur = translucent ? 22.0 : 32.0;
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(topWhite),
                  Colors.white.withOpacity(bottomWhite),
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
        // 白色玻璃主体：上亮下暗 → 玻璃厚度
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(0.85),
            Colors.white.withOpacity(0.55),
            Colors.white.withOpacity(0.30),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
        // 白色描边：玻璃边缘高光
        border: Border.all(
          width: 1.0,
          color: Colors.white.withOpacity(0.85),
        ),
        boxShadow: [
          // 投影 — 玻璃浮起
          BoxShadow(
            color: Colors.black.withOpacity(0.16),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
          // 顶部内发光
          BoxShadow(
            color: Colors.white.withOpacity(0.6),
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
                      Colors.white.withOpacity(0.85),
                      Colors.white.withOpacity(0.0),
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
                      Colors.white.withOpacity(0.30),
                      Colors.white.withOpacity(0.0),
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

class _NavLabel extends StatefulWidget {
  final NavBarItem item;
  final bool isActive;
  final VoidCallback onTap;

  const _NavLabel({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_NavLabel> createState() => _NavLabelState();
}

class _NavLabelState extends State<_NavLabel>
    with SingleTickerProviderStateMixin {
  late AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
      value: widget.isActive ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_NavLabel old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      if (widget.isActive) {
        _animCtrl.forward();
      } else {
        _animCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _animCtrl,
        builder: (context, child) {
          // 平滑减速（无过冲），与气泡滑动同一条曲线语言
          final t = Curves.easeOutCubic.transform(_animCtrl.value);
          return Transform.scale(
            scale: 0.90 + 0.10 * t,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.item.icon,
                  color: Color.lerp(
                    GlassTheme.textTertiary,
                    GlassTheme.accentPurple,
                    t,
                  ),
                  size: 18 + 4 * t,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 9 + 1.5 * t,
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
          );
        },
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
