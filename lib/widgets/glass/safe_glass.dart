import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';

/// ???????????
///
/// Android ??? GPU(Mali/?? Adreno)? BackdropFilter
/// ????????,??????????
/// ???? Android ?????????????,
/// iOS ????? BackdropFilter ???
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

  /// ??????? BackdropFilter
  static bool get supportsBackdropBlur => !Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    if (supportsBackdropBlur) {
      return ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: _buildBackdrop(child),
      );
    }
    // Android ??:??????????
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

/// ??????? - GlassPanel ????,Android ????
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
      // Android: use visible tinted background
      bgColor = tintColor.withOpacity(opacity * 4);
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
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
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