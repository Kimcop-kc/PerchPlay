import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';

/// iOS 27 玻璃质感卡片
///
/// 特性：
///   - BackdropFilter 实时模糊
///   - 顶部光泽高光
///   - 1px 白色内边框
///   - 弹性悬浮动画 (Hover / Tap)
class GlassCard extends StatefulWidget {
  final Widget child;
  final double? width;
  final double? height;
  final double radius;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final VoidCallback? onTap;
  final bool enableHover;
  final bool selected;
  final Color? tint;
  final Duration animationDuration;

  const GlassCard({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.radius = GlassTheme.radiusMd,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.onTap,
    this.enableHover = true,
    this.selected = false,
    this.tint,
    this.animationDuration = const Duration(milliseconds: 400),
  });

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
      value: widget.selected ? 1 : 0,
    );
    _scaleAnimation = Tween<double>(begin: 1, end: 1.02).animate(
      CurvedAnimation(parent: _hoverController, curve: GlassCurves.iosDecelerate),
    );
  }

  @override
  void didUpdateWidget(GlassCard old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      if (widget.selected) {
        _hoverController.forward();
      } else {
        _hoverController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.tint ?? GlassTheme.tintWhite;

    return MouseRegion(
      onEnter: widget.enableHover ? (_) => _hoverController.forward() : null,
      onExit: widget.enableHover ? (_) => _hoverController.reverse() : null,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: GlassAnimatedBuilder(
          listenable: _scaleAnimation,
          builder: (context, child) {
            final scale = _scaleAnimation.value;

            return Transform.scale(
              scale: scale,
              child: Container(
                width: widget.width,
                height: widget.height,
                margin: widget.margin,
                child: Stack(
                  children: [
                    // 基础模糊层
                    ClipRRect(
                      borderRadius: BorderRadius.circular(widget.radius),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: 20,
                          sigmaY: 20,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(widget.radius),
                            border: Border.all(
                              color: widget.selected
                                  ? GlassTheme.accentPurple.withOpacity(0.4)
                                  : Colors.white.withOpacity(
                                      0.06 + _hoverController.value * 0.06),
                              width: widget.selected ? 1.2 : 0.6,
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                tint.withOpacity(
                                    0.06 + _hoverController.value * 0.04),
                                Colors.white.withOpacity(
                                    0.02 + _hoverController.value * 0.02),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: widget.selected
                                    ? GlassTheme.accentPurple
                                        .withOpacity(0.12)
                                    : Colors.black.withOpacity(0.2),
                                blurRadius: widget.selected ? 24 : 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // 顶部光泽高光
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: widget.radius,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(widget.radius),
                        ),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: GlassTheme.topGlare,
                          ),
                        ),
                      ),
                    ),

                    // 内容
                    Padding(
                      padding: widget.padding,
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(widget.radius - 2),
                        child: child!,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}
