import 'package:flutter/material.dart';

/// 视频播放器手势层
/// 左侧上下滑动: 调节亮度
/// 右侧上下滑动: 调节音量
/// 水平滑动: 快进/快退
/// 单击: 显示/隐藏控制栏
/// 双击: 播放/暂停
class PlayerGestureLayer extends StatefulWidget {
  final Widget? child;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final void Function(double delta) onBrightnessChange;
  final void Function(double delta) onVolumeChange;
  final void Function(int seconds) onSeek;

  const PlayerGestureLayer({
    super.key,
    this.child,
    required this.onTap,
    this.onDoubleTap,
    required this.onBrightnessChange,
    required this.onVolumeChange,
    required this.onSeek,
  });

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

class _PlayerGestureLayerState extends State<PlayerGestureLayer> {
  // 手势追踪
  int _activePointers = 0;
  Offset? _startPosition;

  // 显示状态
  double? _brightnessValue;
  double? _volumeValue;
  int? _seekSeconds;
  bool _showSeekIndicator = false;
  bool _seekForward = true;

  // 常量
  static const double _seekSensitivity = 2.0; // 像素/秒

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 手势检测
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: widget.child ?? const SizedBox.expand(),
        ),

        // 亮度指示器
        if (_brightnessValue != null)
          _buildIndicator(
            icon: Icons.brightness_6_rounded,
            value: _brightnessValue!,
            label: '亮度',
          ),

        // 音量指示器
        if (_volumeValue != null)
          _buildIndicator(
            icon: Icons.volume_up_rounded,
            value: _volumeValue!,
            label: '音量',
          ),

        // 快进/快退指示器
        if (_showSeekIndicator && _seekSeconds != null)
          _buildSeekIndicator(),
      ],
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    _activePointers++;
    if (_activePointers == 1) {
      _startPosition = details.localFocalPoint;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_startPosition == null) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isLeftSide = _startPosition!.dx < screenWidth / 2;
    final dx = details.localFocalPoint.dx - _startPosition!.dx;
    final dy = details.localFocalPoint.dy - _startPosition!.dy;

    // 判断手势方向
    if (dx.abs() > dy.abs() && dx.abs() > 8) {
      // 水平滑动 -> 快进/快退
      _handleSeekGesture(dx);
    } else if (dy.abs() > 8) {
      // 垂直滑动
      if (isLeftSide) {
        _handleBrightnessGesture(dy, screenHeight);
      } else {
        _handleVolumeGesture(dy, screenHeight);
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _activePointers = 0;

    // 执行实际的 seek
    if (_seekSeconds != null && _seekSeconds != 0) {
      widget.onSeek(_seekSeconds!);
    }

    _startPosition = null;
    _brightnessValue = null;
    _volumeValue = null;
    _seekSeconds = null;
    _showSeekIndicator = false;
  }

  void _handleBrightnessGesture(double dy, double screenHeight) {
    final delta = -dy / screenHeight;
    _brightnessValue = ((_brightnessValue ?? 0.5) + delta).clamp(0.0, 1.0);
    widget.onBrightnessChange(delta);
  }

  void _handleVolumeGesture(double dy, double screenHeight) {
    final delta = -dy / screenHeight;
    _volumeValue = ((_volumeValue ?? 0.5) + delta).clamp(0.0, 1.0);
    widget.onVolumeChange(delta);
  }

  void _handleSeekGesture(double dx) {
    _showSeekIndicator = true;
    _seekForward = dx > 0;
    final seconds = (dx * _seekSensitivity).round();
    _seekSeconds = seconds;
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
              style: TextStyle(color: Colors.white54, fontSize: 12),
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
              _seekForward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
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
