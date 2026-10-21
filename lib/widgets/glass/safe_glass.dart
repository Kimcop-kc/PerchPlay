import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

/// 安全的玻璃模糊背景组件
///
/// Android 上某些 GPU（Mali/老款 Adreno）的 BackdropFilter
/// 会在合成阶段失败，导致整个渲染树变黑。
/// 本组件在 Android 上自动降级为半透明纯色叠加，
/// iOS 上保留完整 BackdropFilter 效果。
class SafeBackdropFilter extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final Color fallbackBackground;
  final BorderRadiusGeometry? borderRadius;

  const SafeBackdropFilter({
    super.key,
    required this.child,
    this.blurSigma = 20,
    this.fallbackBackground = const Color(0x0D000000),
    this.borderRadius,
  });

  /// 是否可使用原生 BackdropFilter
  static bool get supportsBackdropBlur => !Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    if (supportsBackdropBlur) {
      return ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: _buildBackdrop(child),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: Container(color: fallbackBackground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackdrop(Widget child) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: child,
    );
  }
}

/// 安全的玻璃面板 — GlassPanel 的替代品，Android 自动降级
class SafeGlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color? tint;
  final double opacity;
  final bool showBorder;
  final bool showShadow;
  final double? width;
  final double? height;

  const SafeGlassPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = const EdgeInsets.all(16),
    this.tint,
    this.opacity = 0.10,
    this.showBorder = true,
    this.showShadow = false,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final tintColor = tint ?? const Color(0x0AFFFFFF);
    final Color bgColor;
    if (SafeBackdropFilter.supportsBackdropBlur) {
      bgColor = Colors.transparent;
    } else {
      bgColor = tintColor.withValues(alpha: opacity * 4);
    }

    Widget panel = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: bgColor,
        border: showBorder
            ? Border.all(
                color: Colors.white.withValues(alpha: 0.07),
                width: 0.5,
              )
            : null,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tintColor.withValues(alpha: 0.08),
            tintColor.withValues(alpha: 0.02),
          ],
        ),
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: child,
    );

    if (SafeBackdropFilter.supportsBackdropBlur) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: panel,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: panel,
    );
  }
}
