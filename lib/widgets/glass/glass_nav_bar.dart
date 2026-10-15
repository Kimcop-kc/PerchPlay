import 'dart:math' as math;
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

  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentRoute,
    this.height = 64,
  });

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  int _currentIndex = 0;
  int _prevIndex = 0;

  // 气泡尺寸
  static const _bubbleW = 72.0;
  static const _bubbleH = 48.0;

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
          final slotW = trackW / widget.items.length;
          final startCx = _slotCenterX(_prevIndex, slotW);
          final endCx = _slotCenterX(_currentIndex, slotW);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // ── 轨道：毛玻璃底板 ──
              _GlassTrack(),

              // ── 浮起透镜气泡 ──
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: _slideCtrl,
                  builder: (context, _) {
                    final t = _springEval(_slideCtrl.value);
                    final cx = startCx + (endCx - startCx) * t;
                    return Positioned(
                      left: cx - _bubbleW / 2,
                      top: (widget.height - _bubbleH) / 2,
                      child: const _LensBubble(
                        width: _bubbleW,
                        height: _bubbleH,
                      ),
                    );
                  },
                ),
              ),

              // ── 图标文字层 ──
              Row(
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

  /// 弹簧曲线（阻尼回弹）
  double _springEval(double t) {
    const beta = 18.0 / 2; // damping/2mass
    const omega = 14.0; // sqrt(stiffness/mass - beta^2)
    final envelope = math.exp(-beta * t);
    return 1 - envelope * (math.cos(omega * t) + beta / omega * math.sin(omega * t));
  }
}

// ═══════════════ 毛玻璃轨道 ═══════════════
//
// Android 不用 BackdropFilter（GPU 兼容问题），
// 改用多层半透明白色渐变 + 彩色光斑模拟毛玻璃折射。

class _GlassTrack extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            // 多层半透明白色 → 模拟毛玻璃折射
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.72),
                Colors.white.withOpacity(0.48),
                Colors.white.withOpacity(0.35),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            border: Border.all(
              color: Colors.white.withOpacity(0.55),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.10),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
              // 底部微光
              BoxShadow(
                color: Colors.white.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Stack(
            children: [
              // 顶部高光带
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 18,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withOpacity(0.50),
                        Colors.white.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
              // 底部微反光
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 10,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(28)),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.white.withOpacity(0.18),
                        Colors.white.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
              // 左侧彩色光斑（模拟折射）
              Positioned(
                top: -20,
                left: -30,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        GlassTheme.accentPurple.withOpacity(0.08),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              // 右侧彩色光斑
              Positioned(
                bottom: -20,
                right: -30,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        GlassTheme.accentTeal.withOpacity(0.06),
                        Colors.transparent,
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
// 浮起凸透镜：白色半透主体 + 彩虹折射色散边缘 + 投影 + 内高光

class _LensBubble extends StatelessWidget {
  final double width;
  final double height;
  const _LensBubble({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    const r = 20.0; // 气泡圆角

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r),
        // 透镜主体：上亮下暗 → 玻璃厚度
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(0.78),
            Colors.white.withOpacity(0.45),
            Colors.white.withOpacity(0.20),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
        // 外框：白色半透
        border: Border.all(
          width: 1.0,
          color: Colors.white.withOpacity(0.60),
        ),
        boxShadow: [
          // 投影 — 玻璃厚度浮起感
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
          // 上方内发光 — 透镜中心亮
          BoxShadow(
            color: Colors.white.withOpacity(0.70),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
          // 微扩散光晕
          BoxShadow(
            color: GlassTheme.accentPurple.withOpacity(0.10),
            blurRadius: 16,
            offset: Offset.zero,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: Stack(
          children: [
            // ── 彩虹色散边缘（chromatic aberration） ──
            // 上边缘
            Positioned(
              top: 0,
              left: 4,
              right: 4,
              height: 2.0,
              child: _chromaticBar(
                [Color(0xCC00E5FF), Color(0xCCB388FF), Color(0xCCFF80AB)],
              ),
            ),
            // 下边缘
            Positioned(
              bottom: 0,
              left: 4,
              right: 4,
              height: 2.0,
              child: _chromaticBar(
                [Color(0xCCFF80AB), Color(0xCCFFD740), Color(0xCC00E5FF)],
              ),
            ),
            // 左边缘
            Positioned(
              top: 4,
              bottom: 4,
              left: 0,
              width: 2.0,
              child: _chromaticBarV(
                [Color(0xCCB388FF), Color(0xCCFF80AB)],
              ),
            ),
            // 右边缘
            Positioned(
              top: 4,
              bottom: 4,
              right: 0,
              width: 2.0,
              child: _chromaticBarV(
                [Color(0xCC00E5FF), Color(0xCCFFD740)],
              ),
            ),

            // ── 气泡内部高光（透镜凸起质感） ──
            Positioned(
              top: 3,
              left: 12,
              right: 12,
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
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
              bottom: 2,
              left: 16,
              right: 16,
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
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

  static Widget _chromaticBar(List<Color> colors) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
      ),
    );
  }

  static Widget _chromaticBarV(List<Color> colors) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
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
      duration: const Duration(milliseconds: 380),
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
          final t = Curves.easeOutBack.transform(_animCtrl.value);
          return Transform.scale(
            scale: 0.88 + 0.12 * t,
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
