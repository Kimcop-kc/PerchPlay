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

  /// 拖动开始时回调（父页面可借此告知手势层"滑块正在操作，抑制画面 seek"）。
  final VoidCallback? onDragStart;

  /// 拖动结束时回调（包括取消）。
  final VoidCallback? onDragEnd;

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
    this.onDragStart,
    this.onDragEnd,
    this.showThumb = true,
    this.thumbRadius = 7,
  });

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider> {
  bool _dragging = false;
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    // 拖动时用内部值（跟手），否则用外部 value（反映真实进度）
    final effectiveValue = _dragValue ?? widget.value;
    final fraction = ((effectiveValue - widget.min) / (widget.max - widget.min))
        .clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (details) {
        setState(() => _dragging = true);
        _dragValue = _valueAt(details.localPosition.dx, context);
        widget.onDragStart?.call();
      },
      onPanUpdate: (details) {
        setState(() {
          _dragValue = _valueAt(details.localPosition.dx, context);
        });
        // 拖动过程中实时回调（用于进度预览）
        widget.onChanged?.call(_dragValue!);
      },
      onPanEnd: (_) {
        setState(() => _dragging = false);
        // 松手时提交最终值
        widget.onChangeEnd?.call(_dragValue ?? widget.value);
        _dragValue = null;
        widget.onDragEnd?.call();
      },
      onPanCancel: () {
        setState(() => _dragging = false);
        // 拖动被取消（系统手势/通知栏下拉等）。
        // 通知父页面清除预览并恢复真实进度，但**不提交跳转**。
        widget.onDragEnd?.call();
        _dragValue = null;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final activeWidth = width * fraction;

          return SizedBox(
            // 命中区高度加大到 32px，保证手指容易点中进度条
            height: widget.height +
                (widget.showThumb ? widget.thumbRadius * 2 : 0) +
                24,
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
                              Colors.black.withValues(alpha: 0.10),
                              Colors.white.withValues(alpha: 0.30),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.35),
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
                              widget.activeColor.withValues(alpha: 0.7),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: widget.activeColor.withValues(alpha: 0.5),
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
                    left: (activeWidth - widget.thumbRadius * 2)
                        .clamp(0, width - widget.thumbRadius * 2),
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
                                    .withValues(alpha: _dragging ? 0.6 : 0.35),
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

  double _valueAt(double dx, BuildContext context) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final width = box.size.width;
    if (width <= 0) return widget.value;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return widget.min + fraction * (widget.max - widget.min);
  }
}
