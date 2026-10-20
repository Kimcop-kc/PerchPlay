import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 视频播放器手势层
///
/// 左半屏上下滑动：亮度   右半屏上下滑动：音量
/// 水平滑动：拖动进度（实时预览，松手提交）  单击：显示/隐藏控制栏  双击：播放/暂停
///
/// 数值按「手势起点值 + 累计位移」线性计算（不做逐帧累加），
/// 否则位移会被平方放大，稍微一滑就调到底。
class PlayerGestureLayer extends StatefulWidget {
  final Widget? child;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  /// 绝对亮度 0..1
  final ValueChanged<double> onBrightnessChange;

  /// 绝对音量 0..1
  final ValueChanged<double> onVolumeChange;

  /// 拖动进度中：回报目标位置（毫秒），用于实时带动进度条
  final ValueChanged<int>? onSeekPreview;

  /// 松手提交：真正跳转到该位置（毫秒）
  final ValueChanged<int>? onSeekCommit;

  /// 长按倍速（松手恢复），空则无此手势
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  /// 长按时显示的倍速值，例如 2.0；不为 null 时显示指示器
  final double? longPressSpeed;

  /// 手势开始时的当前亮度/音量，作为滑动基准
  final double initialBrightness;
  final double initialVolume;

  /// 当前播放位置与总时长（毫秒），用于把位移换算成进度
  final int positionMs;
  final int durationMs;

  const PlayerGestureLayer({
    super.key,
    this.child,
    required this.onTap,
    this.onDoubleTap,
    required this.onBrightnessChange,
    required this.onVolumeChange,
    this.onSeekPreview,
    this.onSeekCommit,
    this.onLongPressStart,
    this.onLongPressEnd,
    this.longPressSpeed,
    this.initialBrightness = 0.5,
    this.initialVolume = 0.5,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

enum _GestureAxis { none, vertical, horizontal }

class _PlayerGestureLayerState extends State<PlayerGestureLayer> {
  Offset? _startPosition;
  _GestureAxis _axis = _GestureAxis.none;

  // 手势基准值
  double _baseBrightness = 0.5;
  double _baseVolume = 0.5;
  int _startPositionMs = 0;

  // 指示器状态
  double? _brightnessValue;
  double? _volumeValue;
  int? _previewTargetMs;

  /// 当前是否正在长按（显示倍速指示器用）
  bool _isLongPressing = false;

  /// 纵向：需要滑动「屏幕高度 × 该系数」才走完 100%，避免过于灵敏
  static const double _verticalDamping = 1.25;

  /// 横向：滑过整屏宽度对应的进度跨度 = 时长的 12%，
  /// 并夹在 30s ~ 4min 之间（长片也能较快掠过，短片不会一点就飞）
  static const double _seekWindowRatio = 0.12;
  static const int _seekWindowMinMs = 30 * 1000;
  static const int _seekWindowMaxMs = 4 * 60 * 1000;

  /// 横向拖动的最小位移，避免误触就跳进度
  static const double _seekMinDrag = 22.0;

  /// 判定手势方向的最小位移
  static const double _axisThreshold = 14.0;

  @override
  Widget build(BuildContext context) {
    final preview = _previewTargetMs;
    final hasLongPress = widget.onLongPressStart != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onLongPressStart:
              hasLongPress ? (_) => _onLongPressStart() : null,
          onLongPressEnd:
              hasLongPress ? (_) => _onLongPressEnd() : null,
          child: widget.child ?? const SizedBox.expand(),
        ),

        if (_brightnessValue != null)
          _buildIndicator(
            icon: Icons.brightness_6_rounded,
            value: _brightnessValue!,
            label: '亮度',
          ),

        if (_volumeValue != null)
          _buildIndicator(
            icon: Icons.volume_up_rounded,
            value: _volumeValue!,
            label: '音量',
          ),

        if (preview != null) _buildSeekIndicator(preview),

        // 长按倍速指示器
        if (_isLongPressing && widget.longPressSpeed != null)
          _buildSpeedIndicator(widget.longPressSpeed!),
      ],
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_isLongPressing) return;
    _startPosition = details.localFocalPoint;
    _axis = _GestureAxis.none;
    // 以当前实际值作为基准，避免每次都从 50% 起算
    _baseBrightness = widget.initialBrightness;
    _baseVolume = widget.initialVolume;
    _startPositionMs = widget.positionMs;
    _brightnessValue = null;
    _volumeValue = null;
    _previewTargetMs = null;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_isLongPressing) return;
    // 双指（缩放）不参与亮度/音量/进度调节
    if (details.pointerCount > 1 || _startPosition == null) return;

    final size = MediaQuery.of(context).size;
    final dx = details.localFocalPoint.dx - _startPosition!.dx;
    final dy = details.localFocalPoint.dy - _startPosition!.dy;

    // 锁定手势方向，避免中途在横向/纵向之间来回跳
    if (_axis == _GestureAxis.none) {
      if (dx.abs() < _axisThreshold && dy.abs() < _axisThreshold) return;
      _axis =
          dx.abs() > dy.abs() ? _GestureAxis.horizontal : _GestureAxis.vertical;
    }

    switch (_axis) {
      case _GestureAxis.horizontal:
        _handleSeekGesture(dx, size.width);
      case _GestureAxis.vertical:
        final isLeftSide = _startPosition!.dx < size.width / 2;
        if (isLeftSide) {
          _handleBrightnessGesture(dy, size.height);
        } else {
          _handleVolumeGesture(dy, size.height);
        }
      case _GestureAxis.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_isLongPressing) return;
    final target = _previewTargetMs;
    if (_axis == _GestureAxis.horizontal && target != null) {
      widget.onSeekCommit?.call(target);
    }
    _startPosition = null;
    _axis = _GestureAxis.none;
    setState(() {
      _brightnessValue = null;
      _volumeValue = null;
      _previewTargetMs = null;
    });
  }

  void _handleBrightnessGesture(double dy, double screenHeight) {
    // 向上滑变亮：位移相对基准值一次性换算，不做累加
    final delta = -dy / (screenHeight * _verticalDamping);
    final value = (_baseBrightness + delta).clamp(0.0, 1.0);
    setState(() => _brightnessValue = value);
    widget.onBrightnessChange(value);
  }

  void _handleVolumeGesture(double dy, double screenHeight) {
    final delta = -dy / (screenHeight * _verticalDamping);
    final value = (_baseVolume + delta).clamp(0.0, 1.0);
    setState(() => _volumeValue = value);
    widget.onVolumeChange(value);
  }

  /// 横向拖动 = 拖动进度：把位移换算成目标位置，实时回报
  void _handleSeekGesture(double dx, double screenWidth) {
    final duration = widget.durationMs;
    if (duration <= 0) return;
    // 位移太小不响应，避免误触
    if (dx.abs() < _seekMinDrag) return;

    final windowMs = (duration * _seekWindowRatio)
        .clamp(_seekWindowMinMs.toDouble(), _seekWindowMaxMs.toDouble());
    final target = (_startPositionMs + dx / screenWidth * windowMs)
        .clamp(0.0, duration.toDouble())
        .round();

    setState(() => _previewTargetMs = target);
    widget.onSeekPreview?.call(target);
  }

  void _onLongPressStart() {
    HapticFeedback.mediumImpact();
    setState(() => _isLongPressing = true);
    widget.onLongPressStart?.call();
  }

  void _onLongPressEnd() {
    HapticFeedback.lightImpact();
    setState(() => _isLongPressing = false);
    widget.onLongPressEnd?.call();
  }

  Widget _buildSpeedIndicator(double speed) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.only(top: 60),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.25), width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fast_forward_rounded,
                color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(
              '${speed}x 倍速',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIndicator({
    required IconData icon,
    required double value,
    required String label,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 36),
            const SizedBox(height: 8),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 进度指示：显示目标时间 + 相对当前的变化量
  Widget _buildSeekIndicator(int targetMs) {
    final deltaMs = targetMs - _startPositionMs;
    final sign = deltaMs >= 0 ? '+' : '-';
    final deltaText = _fmtDelta(deltaMs.abs());
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  deltaMs >= 0
                      ? Icons.fast_forward_rounded
                      : Icons.fast_rewind_rounded,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(
                  '$sign$deltaText',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${_fmtClock(targetMs)} / ${_fmtClock(widget.durationMs)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtClock(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _fmtDelta(int ms) {
    final total = (ms / 1000).round();
    if (total >= 60) {
      final m = total ~/ 60;
      final s = total % 60;
      return '${m}m${s.toString().padLeft(2, '0')}s';
    }
    return '${total}s';
  }
}
