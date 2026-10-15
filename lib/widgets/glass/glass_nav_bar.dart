import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import 'safe_glass.dart';

/// 液态玻璃导航底栏
///
/// 毛玻璃轨道 + 浮起透镜气泡（在 tab 间平滑滑动）+ 彩虹折射边缘 + 投影。
/// 参考图：选中项是一个独立凸起的玻璃透镜，有厚度感，边缘带彩色折射色散。
class GlassNavBar extends StatefulWidget {
  final List<NavBarItem> items;
  final String currentRoute;
  final double height;

  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentRoute,
    this.height = 62,
  });

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  int _activeIndex = 0;
  double _bubbleX = 0;

  // 气泡尺寸
  static const _bubbleW = 68.0;
  static const _bubbleH = 52.0;

  @override
  void initState() {
    super.initState();
    _activeIndex = _resolveIndex();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant GlassNavBar old) {
    super.didUpdateWidget(old);
    final newIdx = _resolveIndex();
    if (newIdx != _activeIndex) {
      _activeIndex = newIdx;
      _slideController.forward(from: 0.0);
    }
  }

  int _resolveIndex() {
    for (int i = 0; i < widget.items.length; i++) {
      if (widget.items[i].route == widget.currentRoute) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final totalW = MediaQuery.of(context).size.width - 24; // 两侧留白 12
    final slotW = totalW / widget.items.length;
    final targetX = slotW * _activeIndex + (slotW - _bubbleW) / 2;

    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomSafe > 0 ? bottomSafe : 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SafeBackdropFilter(
          blurSigma: 28,
          child: SizedBox(
            height: widget.height + 4,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ── 轨道：半透明玻璃底板 ──
                _GlassTrack(height: widget.height),

                // ── 浮起透镜气泡 ──
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _slideController,
                    builder: (context, _) {
                      final eased = Curves.easeOutBack.transform(
                          _slideController.value);
                      final x = _bubbleX + (targetX - _bubbleX) * eased;
                      // 记录当前位置，下次动画起点
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _bubbleX = x;
                      });
                      return Positioned(
                        left: x,
                        top: 4,
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
                        isActive: i == _activeIndex,
                        onTap: () {
                          if (i != _activeIndex) {
                            widget.items[i].onTap?.call();
                          }
                        },
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════ 毛玻璃轨道 ═══════════════

class _GlassTrack extends StatelessWidget {
  final double height;
  const _GlassTrack({required this.height});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.58),
              Colors.white.withOpacity(0.22),
            ],
          ),
          border: Border.all(
            color: Colors.white.withOpacity(0.45),
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        // 顶部高光
        child: Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: 16,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(0.42),
                  Colors.white.withOpacity(0.0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════ 透镜气泡 ═══════════════

class _LensBubble extends StatelessWidget {
  final double width;
  final double height;
  const _LensBubble({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        // 气泡主体：白色半透 → 形成透镜
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(0.62),
            Colors.white.withOpacity(0.18),
          ],
        ),
        // 彩虹折射细边（色散效果）
        border: Border.all(
          width: 1.2,
          color: Colors.white.withOpacity(0.5),
        ),
        boxShadow: [
          // 投影 — 玻璃厚度
          BoxShadow(
            color: Colors.black.withOpacity(0.14),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
          // 内发光 — 透镜中心亮
          const BoxShadow(
            color: Colors.white70,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        children: [
          // ── 彩虹色散边缘（chromatic aberration） ──
          // 上边缘：青色 → 紫色
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 1.5,
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                gradient: LinearGradient(
                  colors: [
                    Color(0x5500E5FF), // 青
                    Color(0x55B388FF), // 紫
                    Color(0x55FF80AB), // 粉
                  ],
                ),
              ),
            ),
          ),
          // 下边缘：粉 → 金
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 1.5,
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)),
                gradient: LinearGradient(
                  colors: [
                    Color(0x55FF80AB), // 粉
                    Color(0x55FFD740), // 金
                    Color(0x5500E5FF), // 青
                  ],
                ),
              ),
            ),
          ),
          // 左边缘
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: 1.5,
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x44B388FF),
                    Color(0x44FF80AB),
                  ],
                ),
              ),
            ),
          ),
          // 右边缘
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 1.5,
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x4400E5FF),
                    Color(0x44FFD740),
                  ],
                ),
              ),
            ),
          ),
          // ── 气泡内部高光（透镜质感） ──
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 14, right: 14),
              child: Container(
                height: 7,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xAAFFFFFF),
                      Color(0x00FFFFFF),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
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
  late AnimationController _scaleCtrl;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      value: widget.isActive ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_NavLabel old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      if (widget.isActive) {
        _scaleCtrl.forward();
      } else {
        _scaleCtrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _scaleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _scaleCtrl,
        builder: (context, child) {
          final t = Curves.easeOutBack.transform(_scaleCtrl.value);
          return Transform.scale(
            scale: 0.92 + 0.08 * t,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 4),
                Icon(
                  widget.item.icon,
                  color: Color.lerp(
                    GlassTheme.textTertiary,
                    GlassTheme.accentPurple,
                    t,
                  ),
                  size: 20 + 2 * t,
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.item.label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight:
                          t > 0.5 ? FontWeight.w700 : FontWeight.w400,
                      color: Color.lerp(
                        GlassTheme.textTertiary,
                        GlassTheme.accentPurple,
                        t,
                      ),
                    ),
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