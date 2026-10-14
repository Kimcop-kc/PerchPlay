import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import 'safe_glass.dart';

/// iOS 27 ????????
///
/// ????? + ??????? + ????
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
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusLg)),
      child: SafeBackdropFilter(
        blurSigma: 24,
        child: Container(
          height: height + MediaQuery.of(context).padding.bottom,
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.06),
                Colors.white.withOpacity(0.02),
              ],
            ),
            border: const Border(
              top: BorderSide(color: Color(0x10FFFFFF), width: 0.5),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: items.map((item) {
              final isActive = currentRoute == item.route;
              return _NavItem(item: item, isActive: isActive);
            }).toList(),
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
        : Colors.grey[500]!;

    return GestureDetector(
      onTap: () {
        if (!widget.isActive) {
          widget.item.onTap?.call();
        }
      },
      behavior: HitTestBehavior.opaque,
      child: GlassAnimatedBuilder(
        animation: _bounce,
        builder: (context, child) => Transform.scale(
          scale: _bounce.value,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: widget.isActive
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
                    gradient: LinearGradient(
                      colors: [
                        GlassTheme.accentPurple.withOpacity(0.12),
                        GlassTheme.accentPurple.withOpacity(0.04),
                      ],
                    ),
                  )
                : null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.item.icon,
                  color: color,
                  size: 22,
                ),
                const SizedBox(height: 3),
                Text(
                  widget.item.label,
                  style: TextStyle(
                    fontSize: 10,
                    color: color,
                    fontWeight: widget.isActive
                        ? FontWeight.w600
                        : FontWeight.w400,
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

/// ???????
class SpringCurve extends Curve {
  final double mass, stiffness, damping;
  const SpringCurve({
    this.mass = 1,
    this.stiffness = 200,
    this.damping = 22,
  });

  @override
  double transform(double t) {
    // ??????: ????????
    final beta = damping / (2 * mass);
    final omega = math.sqrt(stiffness / mass - beta * beta);
    final envelope = math.exp(-beta * t);
    final oscillation = math.cos(omega * t);
    return 1 - envelope * (oscillation + beta / omega * math.sin(omega * t));
  }
}