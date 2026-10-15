import 'package:flutter/material.dart';

/// 视频播放器手势层
///
/// 左半屏上下滑动：亮度   右半屏上下滑动：音量
/// 水平滑动：快进/快退     单击：显示/隐藏控制栏   双击：播放/暂停
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

  /// 相对快进秒数（可为负）
  final void Function(int seconds) onSeek;

  /// 手势开始时的当前亮度/音量，作为滑动基准
  final double initialBrightness;
  final double initialVolume;

  const PlayerGestureLayer({
    super.key,
    this.child,
    required this.onTap,
    this.onDoubleTap,
    required this.onBrightnessChange,
    required this.onVolumeChange,
    required this.onSeek,
    this.initialBrightness = 0.5,
    this.initialVolume = 0.5,
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

  // 指示器状态
  double? _brightnessValue;
  double? _volumeValue;
  int? _seekSeconds;
  bool _seekForward = true;

  /// 纵向：需要滑动「屏幕高度 × 该系数」才走完 100%，避免过于灵敏
  static const double _verticalDamping = 1.25;

  /// 横向：滑过整屏宽度对应 180 秒
  static const double _seekSecondsPerScreen = 180.0;

  /// 判定手势方向的最小位移
  static const double _axisThreshold = 12.0;

  @override
  Widget build(BuildContext context) {
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

        if (_seekSeconds != null && _seekSeconds != 0) _buildSeekIndicator(),
      ],
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startPosition = details.localFocalPoint;
    _axis = _GestureAxis.none;
    // 以当前实际值作为基准，避免每次都从 50% 起算
    _baseBrightness = widget.initialBrightness;
    _baseVolume = widget.initialVolume;
    _brightnessValue = null;
    _volumeValue = null;
    _seekSeconds = null;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // 双指（缩放）不参与亮度/音量/进度调节
    if (details.pointerCount > 1 || _startPosition == null) return;

    final size = MediaQuery.of(context).size;
    final dx = details.localFocalPoint.dx - _startPosition!.dx;
    final dy = details.localFocalPoint.dy - _startPosition!.dy;

    // 锁定手势方向，避免中途在横向/纵向之间来回跳
    if (_axis == _GestureAxis.none) {
      if (dx.abs() < _axisThreshold && dy.abs() < _axisThreshold) return;
      _axis = dx.abs() > dy.abs() ? _GestureAxis.horizontal : _GestureAxis.vertical;
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
    if (_axis == _GestureAxis.horizontal &&
        _seekSeconds != null &&
        _seekSeconds != 0) {
      widget.onSeek(_seekSeconds!);
    }
    _startPosition = null;
    _axis = _GestureAxis.none;
    setState(() {
      _brightnessValue = null;
      _volumeValue = null;
      _seekSeconds = null;
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

  void _handleSeekGesture(double dx, double screenWidth) {
    _seekForward = dx > 0;
    final seconds = (dx / screenWidth * _seekSecondsPerScreen).round();
    setState(() => _seekSeconds = seconds);
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

  Widget _buildSeekIndicator() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _seekForward
                  ? Icons.fast_forward_rounded
                  : Icons.fast_rewind_rounded,
              color: Colors.white,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              '${_seekSeconds?.abs() ?? 0}s',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
