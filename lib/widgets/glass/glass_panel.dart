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
    final isColoredTint = tint != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SafeBackdropFilter(
        blurSigma: 30,
        child: Stack(
          children: [
            Container(
              width: width,
              height: height,
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: showBorder
                    ? Border.all(
                        color: isColoredTint
                            ? tintColor.withOpacity(0.35)
                            : Colors.white.withOpacity(0.35),
                        width: 0.8,
                      )
                    : null,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.55),
                    Colors.white.withOpacity(0.22),
                  ],
                ),
                boxShadow: showShadow ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ] : null,
              ),
              child: child,
            ),
            // 液态玻璃高光叠加
            IgnorePointer(
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: isColoredTint
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            tintColor.withOpacity(0.20),
                            Colors.white.withOpacity(0.02),
                          ],
                        )
                      : GlassTheme.liquidSheen,
                ),
              ),
            ),
            // 顶部高光条（液态玻璃强烈折射）
            IgnorePointer(
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [
                      Colors.white.withOpacity(0.55),
                      Colors.white.withOpacity(0.0),
                    ],
                    stops: const [0.0, 0.35],
                  ),
                ),
              ),
            ),
            // 底部反光（玻璃厚度感）
            IgnorePointer(
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.center,
                    colors: [
                      Colors.white.withOpacity(0.18),
                      Colors.white.withOpacity(0.0),
                    ],
                    stops: const [0.0, 0.3],
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