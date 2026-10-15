import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import 'safe_glass.dart';

/// iOS 27 风格玻璃导航底栏
///
/// 毛玻璃背景 + 选中项弹性动画 + 图标着色
class GlassNavBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Container(
      // 悬浮胶囊：底部留出安全区，两侧留白
      padding: EdgeInsets.fromLTRB(12, 8, 12, bottomSafe > 0 ? bottomSafe : 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassTheme.radius2xl),
        child: SafeBackdropFilter(
          blurSigma: 30,
          child: Stack(
            children: [
              Container(
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(GlassTheme.radius2xl),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.68),
                      Colors.white.withOpacity(0.32),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.65),
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.10),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: items.map((item) {
                    final isActive = currentRoute == item.route;
                    return Expanded(
                      child: _NavItem(item: item, isActive: isActive),
                    );
                  }).toList(),
                ),
              ),
              // 液态玻璃顶部高光
              IgnorePointer(
                child: Container(
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(GlassTheme.radius2xl),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.center,
                      colors: [
                        Colors.white.withOpacity(0.55),
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
    );
  }
}

class _NavItem extends StatefulWidget {
  final NavBarItem item;
  final bool isActive;

  const _NavItem({required this.item, required this.isActive});

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
      value: widget.isActive ? 1 : 0,
    );
    _bounce = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const SpringCurve(
          mass: 1,
          stiffness: 180,
          damping: 14,
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(_NavItem old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      if (widget.isActive) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isActive
        ? GlassTheme.accentPurple
        : GlassTheme.textTertiary;

    return GestureDetector(
      onTap: () {
        if (!widget.isActive) {
          widget.item.onTap?.call();
        }
      },
      behavior: HitTestBehavior.opaque,
      child: GlassAnimatedBuilder(
        listenable: _bounce,
        builder: (context, child) => Transform.scale(
          scale: _bounce.value,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            decoration: widget.isActive
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.75),
                        Colors.white.withOpacity(0.35),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.7),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: GlassTheme.accentPurple.withOpacity(0.18),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 图标 + 液态玻璃衬底（选中时）
                Container(
                  width: 34,
                  height: 28,
                  decoration: widget.isActive
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withOpacity(0.5),
                              Colors.white.withOpacity(0.0),
                            ],
                          ),
                        )
                      : null,
                  child: Icon(
                    widget.item.icon,
                    color: color,
                    size: 21,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.item.label,
                    style: TextStyle(
                      fontSize: 10,
                      color: color,
                      fontWeight: widget.isActive
                          ? FontWeight.w700
                          : FontWeight.w400,
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

/// 弹簧曲线包装器
class SpringCurve extends Curve {
  final double mass, stiffness, damping;
  const SpringCurve({
    this.mass = 1,
    this.stiffness = 200,
    this.damping = 22,
  });

  @override
  double transform(double t) {
    // 简单弹性映射: 使用阻尼弹簧公式
    final beta = damping / (2 * mass);
    final omega = math.sqrt(stiffness / mass - beta * beta);
    final envelope = math.exp(-beta * t);
    final oscillation = math.cos(omega * t);
    return 1 - envelope * (oscillation + beta / omega * math.sin(omega * t));
  }
}
