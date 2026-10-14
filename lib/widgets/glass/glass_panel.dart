import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import 'safe_glass.dart';

/// 玻璃面板（Sheet / 侧边栏 / 列表容器）
///
/// 使用 SafeBackdropFilter — Android 自动降级为半透明纯色背景
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color? tint;
  final double opacity;
  final bool showBorder;
  final bool showShadow;
  final double? width;
  final double? height;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = GlassTheme.radiusMd,
    this.padding = const EdgeInsets.all(16),
    this.tint,
    this.opacity = GlassTheme.glassStandard,
    this.showBorder = true,
    this.showShadow = false,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final tintColor = tint ?? GlassTheme.tintWhite;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SafeBackdropFilter(
        blurSigma: 28,
        child: Container(
          width: width,
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: showBorder
                ? Border.all(
                    color: Colors.white.withOpacity(0.07),
                    width: 0.5,
                  )
                : null,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tintColor.withOpacity(0.08),
                tintColor.withOpacity(0.02),
              ],
            ),
            boxShadow: showShadow ? [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ] : null,
          ),
          child: child,
        ),
      ),
    );
  }
}