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

  /// 为 true 时屏蔽手势层的 seek 手势（给 GlassSlider 拖动时用）。
  final bool blockSeek;

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
    this.blockSeek = false,
  });

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

enum _GestureAxis { none, vertical, horizontal }

// ────────────────────────────────────────────────────────────────
// 横向手势 → 进度跳转的分段映射
//
// 历史教训（两次都调歪过，别再改回去）：
//  1. 「12% 时长 + 30s~4min 夹取」：短片划满屏只走几秒、长片划不动；
//  2. 「整屏 = 整个时长」：短片正常，但长片**完全无法精调**——
//     2 小时的片子 1px ≈ 18s，手一抖就跳几分钟，用户反馈「只能一分钟起步」。
//
// 现在：
//  - 短片（≤ 10 分钟）：整屏 = 全长。10 分钟时 1px ≈ 1.5s，精度够，直达更爽。
//  - 长片：前 50% 屏宽是**严格线性精细段**（整屏 90s → 1px ≈ 0.22s，可按秒调）；
//    超过后按二次曲线加速，再滑 1.5 屏即可覆盖剩余全部时长。
// ────────────────────────────────────────────────────────────────

/// 精细段：滑满一整屏对应的秒数。
const double _kSeekFineSecondsPerScreen = 90.0;

/// 短片阈值：不超过该时长就直接「整屏 = 全长」映射。
const double _kSeekShortVideoMaxSec = 600.0;

/// 精细段占屏宽的比例（前 50% 严格精细）。
const double _kSeekFineZoneRatio = 0.5;

/// 加速段跨度：从精细段末尾再滑这么多屏，覆盖剩余全部时长。
const double _kSeekAccelSpanRatio = 1.5;

/// 把横向位移换算成「跳转多少秒」（带符号，正=快进，负=快退）。
///
/// [dx] 相对按下点的水平位移（px），[screenWidth] 屏宽（px），
/// [durationMs] 当前视频总时长（ms）。
///
/// 抽成顶层纯函数是为了能直接单测（见 test/seek_gesture_test.dart）。
double seekDeltaSeconds(double dx, double screenWidth, int durationMs) {
  if (screenWidth <= 0 || durationMs <= 0) return 0;
  final durationSec = durationMs / 1000.0;
  final r = dx / screenWidth; // 拖了几屏（带符号）
  final absR = r.abs();

  // 短片：整屏 = 全长
  if (durationSec <= _kSeekShortVideoMaxSec) {
    return r * durationSec;
  }

  const fineSeconds = _kSeekFineSecondsPerScreen * _kSeekFineZoneRatio;

  double seconds;
  if (absR <= _kSeekFineZoneRatio) {
    // 精细段：线性，斜率 = 90s/屏
    seconds = _kSeekFineSecondsPerScreen * absR;
  } else {
    // 加速段：精细段走完后再按二次曲线铺开剩余时长
    final t = ((absR - _kSeekFineZoneRatio) / _kSeekAccelSpanRatio)
        .clamp(0.0, 1.0);
    final remaining = (durationSec - fineSeconds).clamp(0.0, durationSec);
    seconds = fineSeconds + remaining * t * t;
  }
  return r.sign * seconds;
}

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

  // 横向 seek 的分段映射参数与换算函数在文件顶层（见 [seekDeltaSeconds]），
  // 抽成纯函数是为了能直接单测，避免以后又被改回「整屏 = 全长」。

  /// 横向拖动的最小位移，避免误触就跳进度
  static const double _seekMinDrag = 12.0;

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
          onLongPressStart: hasLongPress ? (_) => _onLongPressStart() : null,
          onLongPressEnd: hasLongPress ? (_) => _onLongPressEnd() : null,
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
    // 如果外部锁定 seek，不初始化预览值
    if (!widget.blockSeek) {
      _previewTargetMs = null;
    }
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
      // 如果外部锁定 seek（如 GlassSlider 正在拖动），横向手势降级：不响
      if (_axis == _GestureAxis.horizontal && widget.blockSeek) {
        _axis = _GestureAxis.none;
        return;
      }
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
    if (_axis == _GestureAxis.horizontal &&
        target != null &&
        !widget.blockSeek) {
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

    // 换算逻辑见顶层的 [seekDeltaSeconds]（分段精细/加速映射）
    final deltaMs = seekDeltaSeconds(dx, screenWidth, duration) * 1000;
    final target = (_startPositionMs + deltaMs)
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
