import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import 'safe_glass.dart';

/// iOS 27 风格玻璃进度条 / 滑块
///
/// 带光泽流动动画 + 玻璃拖拽 thumb
class GlassSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double height;
  final Color activeColor;
  final bool showThumb;
  final double thumbRadius;

  const GlassSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.onChanged,
    this.onChangeEnd,
    this.height = 4,
    this.activeColor = GlassTheme.accentPurple,
    this.showThumb = true,
    this.thumbRadius = 7,
  });

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final fraction = ((widget.value - widget.min) /
            (widget.max - widget.min))
        .clamp(0.0, 1.0);

    return GestureDetector(
      onPanDown: (details) {
        setState(() => _dragging = true);
        _updateValue(details.localPosition.dx, context);
      },
      onPanUpdate: (details) {
        _updateValue(details.localPosition.dx, context);
      },
      onPanEnd: (_) {
        setState(() => _dragging = false);
        widget.onChangeEnd?.call(widget.value);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final activeWidth = width * fraction;

          return SizedBox(
            height: widget.height + (widget.showThumb ? widget.thumbRadius * 2 : 0) + 8,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 轨道背景
                Positioned(
                  top: widget.showThumb ? widget.thumbRadius + 2 : 0,
                  left: 0,
                  right: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.height / 2),
                    child: SafeBackdropFilter(
                      blurSigma: 2,
                      child: Container(
                        height: widget.height,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(widget.height / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(0.10),
                              Colors.white.withOpacity(0.30),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.35),
                            width: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 活跃轨道
                if (activeWidth > 0)
                  Positioned(
                    top: widget.showThumb ? widget.thumbRadius + 2 : 0,
                    left: 0,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(widget.height / 2),
                      child: Container(
                        width: activeWidth,
                        height: widget.height,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(widget.height / 2),
                          gradient: LinearGradient(
                            colors: [
                              widget.activeColor,
                              widget.activeColor.withOpacity(0.7),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: widget.activeColor.withOpacity(0.5),
                              blurRadius: _dragging ? 12 : 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Thumb
                if (widget.showThumb)
                  Positioned(
                    left: (activeWidth - widget.thumbRadius * 2).clamp(
                        0, width - widget.thumbRadius * 2),
                    top: 0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: widget.thumbRadius * 2,
                      height: widget.thumbRadius * 2 + widget.height + 8,
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: _dragging
                              ? widget.thumbRadius * 2.8
                              : widget.thumbRadius * 2,
                          height: _dragging
                              ? widget.thumbRadius * 2.8
                              : widget.thumbRadius * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: widget.activeColor
                                    .withOpacity(_dragging ? 0.6 : 0.35),
                                blurRadius: _dragging ? 14 : 8,
                                spreadRadius: _dragging ? 2 : 0,
                              ),
                            ],
                          ),
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

  void _updateValue(double dx, BuildContext context) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final width = box.size.width;
    final fraction = (dx / width).clamp(0.0, 1.0);
    final newValue = widget.min + fraction * (widget.max - widget.min);
    widget.onChanged?.call(newValue);
  }
}