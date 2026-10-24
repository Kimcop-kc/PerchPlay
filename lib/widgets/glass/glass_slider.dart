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
  double _cachedWidth = 0;

  @override
  Widget build(BuildContext context) {
    // 拖动时**完全**用内部值。
    //
    // 这是避免「滑条发涩」的关键：外层可能在 onChanged 里把值再回灌回来
    // （典型场景：播放页把预览值写进 ValueNotifier，再经
    // ValueListenableBuilder 推回 value）。只要拖动中我们忽略 widget.value，
    // 就不会形成「外部更新 → 重建 → 又 setState」的循环。
    final effectiveValue = _dragging
        ? (_dragValue ?? widget.value)
        : widget.value;
    final fraction = ((effectiveValue - widget.min) / (widget.max - widget.min))
        .clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (details) {
        _cachedWidth = _sliderWidth(context);
        setState(() => _dragging = true);
        _dragValue = _valueAt(details.localPosition.dx);
        widget.onDragStart?.call();
      },
      onPanUpdate: (details) {
        _dragValue = _valueAt(details.localPosition.dx);
        // 仅 rebuild slider 本身（不触发父级 rebuild）。
        setState(() {});
        widget.onChanged?.call(_dragValue!);
      },
      onPanEnd: (_) {
        setState(() => _dragging = false);
        widget.onChangeEnd?.call(_dragValue ?? widget.value);
        _dragValue = null;
        widget.onDragEnd?.call();
      },
      onPanCancel: () {
        setState(() => _dragging = false);
        widget.onDragEnd?.call();
        _dragValue = null;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final activeWidth = width * fraction;

          return SizedBox(
            // 高度 = 轨道 + 圆点直径 + 少量余量，**正好容下控件**。
            //
            // 原来这里额外 +24（注释说"命中区加大到 32px"），导致进度条
            // 上下有大片空白、视觉上"太高"（用户反馈）。触摸命中区已经由
            // GestureDetector 的 behavior 覆盖整个 SizedBox，不需要靠撑高
            // 来实现可点性，所以留 4px 余量足够。
            height: widget.height +
                (widget.showThumb ? widget.thumbRadius * 2 : 0) +
                4,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 轨道背景
                //
                // 拖动过程中**不要**再套 SafeBackdropFilter：
                // 它内部是 ClipRRect + Stack（Android 上还叠一层渐变 Container），
                // 每次 setState 都要重建这一小段渲染子树。虽然 Android 已把
                // BackdropFilter 降级成纯色，但反复创建/销毁 RectClipLayer
                // 仍会带来可感知的掉帧，表现为「滑条拉起来一顿一顿」。
                //
                // 静止时保留原来的玻璃质感，拖动时换成一个等价的静态渐变，
                // 视觉差异极小，但少一层合成。
                Positioned(
                  top: widget.showThumb ? widget.thumbRadius + 2 : 0,
                  left: 0,
                  right: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(widget.height / 2),
                    child: _dragging
                        ? _buildTrackStatic()
                        : SafeBackdropFilter(
                            blurSigma: 2,
                            child: _buildTrackStatic(),
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
                          // 拖动中**不要**投影发光。
                          // boxShadow 每帧都要按新宽度生成一张模糊蒙版，
                          // 而拖动时宽度每帧都变 —— 这是「拉动滑条发涩」
                          // 的主要来源之一。静止时保留发光，观感不受影响。
                          boxShadow: _dragging
                              ? null
                              : [
                                  BoxShadow(
                                    color: widget.activeColor
                                        .withValues(alpha: 0.5),
                                    blurRadius: 6,
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
                      // 拖动中位置每帧都变，AnimatedContainer 的隐式补间
                      // 只会让 thumb「追不上手指」且白白多一层动画运算。
                      // 因此拖动期间把时长压到 0（等价于瞬时跟随），
                      // 松手后再恢复 200ms 的柔和过渡。
                      duration: _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      width: widget.thumbRadius * 2,
                      height: widget.thumbRadius * 2 + widget.height + 8,
                      child: Center(
                        child: AnimatedContainer(
                          duration: _dragging
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
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
                                // 拖动中缩小模糊半径：BoxShadow 的 blur 需要
                                // 每帧重新生成蒙版，半径越大越贵。
                                // 14 → 8 视觉上差异很小，但省下明显开销。
                                blurRadius: _dragging ? 8 : 8,
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

  double _sliderWidth(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.size.width;
  }

  /// 轨道背景的静态绘制（拖动与静止共用，避免两套代码走样）。
  Widget _buildTrackStatic() {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.height / 2),
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
    );
  }

  double _valueAt(double dx) {
    final width = _cachedWidth;
    if (width <= 0) return widget.value;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return widget.min + fraction * (widget.max - widget.min);
  }
}
