import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';

/// 玻璃质感按钮
///
/// 支持：
///   - filled: 实心紫青色渐变
///   - outlined: 毛玻璃边框
///   - ghost: 纯透明 + 悬停玻璃
class GlassButton extends StatefulWidget {
  final Widget? child;
  final VoidCallback? onTap;
  final double? width;
  final double height;
  final double radius;
  final EdgeInsets padding;
  final Color? foregroundColor;
  final Color? backgroundColor;
  final bool filled;
  final bool outlined;
  final bool ghost;
  final IconData? icon;
  final String? label;
  final bool compact;

  const GlassButton({
    super.key,
    this.child,
    this.onTap,
    this.width,
    this.height = 48,
    this.radius = GlassTheme.radiusSm,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.foregroundColor,
    this.backgroundColor,
    this.filled = false,
    this.outlined = false,
    this.ghost = false,
    this.icon,
    this.label,
    this.compact = false,
  }) : assert(child != null || (icon != null && label != null),
            'Provide either child or icon+label');

  const GlassButton.filled({
    super.key,
    this.child,
    this.onTap,
    this.width,
    this.height = 48,
    this.radius = GlassTheme.radiusSm,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.foregroundColor = Colors.white,
    this.backgroundColor,
    this.icon,
    this.label,
    this.compact = false,
  }) : ghost = false, outlined = false, filled = true;

  const GlassButton.outlined({
    super.key,
    this.child,
    this.onTap,
    this.width,
    this.height = 48,
    this.radius = GlassTheme.radiusSm,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.foregroundColor,
    this.backgroundColor,
    this.icon,
    this.label,
    this.compact = false,
  }) : ghost = false, filled = false, outlined = true;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.foregroundColor ?? GlassTheme.accentPurple;

    // 构建内容
    Widget content;
    if (widget.child != null) {
      content = widget.child!;
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: widget.compact ? 16 : 20, color: fg),
            const SizedBox(width: 6),
          ],
          if (widget.label != null)
            Flexible(
              child: Text(
                widget.label!,
                style: TextStyle(
                  color: fg,
                  fontSize: widget.compact ? 13 : 14,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
    }

    return GestureDetector(
      onTapDown: widget.onTap != null ? (_) => setState(() => _pressed = true) : null,
      onTapUp: widget.onTap != null
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            }
          : null,
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 150),
        scale: _pressed ? 0.96 : 1.0,
        curve: GlassCurves.iosDecelerate,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: GlassCurves.iosDecelerate,
          width: widget.width,
          height: widget.height,
          padding: widget.padding,
          decoration: _buildDecoration(fg),
          child: Center(child: content),
        ),
      ),
    );
  }

  BoxDecoration _buildDecoration(Color fg) {
    if (widget.filled) {
      // 七彩渐变：紫 → 青
      return BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF9B7EF0),
            Color(0xFF6C5CE7),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF9B7EF0).withOpacity(_pressed ? 0.2 : 0.35),
            blurRadius: _pressed ? 10 : 18,
            offset: Offset(0, (_pressed ? 2.0 : 6.0)),
          ),
        ],
      );
    }

    if (widget.outlined) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(
          color: fg.withOpacity(_pressed ? 0.3 : 0.15),
          width: 0.8,
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            fg.withOpacity(_pressed ? 0.12 : 0.04),
            fg.withOpacity(_pressed ? 0.06 : 0.01),
          ],
        ),
      );
    }

    // ghost
    return BoxDecoration(
      borderRadius: BorderRadius.circular(widget.radius),
      color: _pressed ? Colors.white.withOpacity(0.06) : Colors.transparent,
    );
  }
}
