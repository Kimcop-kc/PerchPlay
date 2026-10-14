import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';

/// 播放器底部控制栏
class PlayerControlsOverlay extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double volume;
  final double brightness;
  final double speed;
  final VoidCallback onPlayPause;
  final void Function(Duration) onSeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final void Function(double)? onVolumeChange;
  final double scale;

  const PlayerControlsOverlay({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    required this.brightness,
    required this.speed,
    required this.onPlayPause,
    required this.onSeek,
    this.onPrevious,
    this.onNext,
    this.onVolumeChange,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final currentMs = position.inMilliseconds;
    final progress = totalMs > 0 ? currentMs / totalMs : 0.0;

    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条
            _buildProgressBar(progress),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 当前时间
                  Text(
                    _formatDuration(position),
                    style: TextStyle(color: Colors.white70, fontSize: 12 * scale),
                  ),
                  const Spacer(),
                  // 总时长
                  Text(
                    _formatDuration(duration),
                    style: TextStyle(color: Colors.white54, fontSize: 12 * scale),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 控制按钮行
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 上一集
                  IconButton(
                    icon: Icon(Icons.skip_previous_rounded,
                        color: Colors.white, size: 28 * scale),
                    onPressed: onPrevious,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: 40 * scale, minHeight: 40 * scale),
                  ),

                  // 快退 10s
                  IconButton(
                    icon: Icon(Icons.replay_10_rounded,
                        color: Colors.white, size: 28 * scale),
                    onPressed: () => onSeek(position - const Duration(seconds: 10)),
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: 40 * scale, minHeight: 40 * scale),
                  ),

                  // 播放/暂停
                  Container(
                    width: 52 * scale,
                    height: 52 * scale,
                    decoration: BoxDecoration(
                      color: GlassTheme.accentPurple,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 30 * scale,
                      ),
                      onPressed: onPlayPause,
                    ),
                  ),

                  // 快进 10s
                  IconButton(
                    icon: Icon(Icons.forward_10_rounded,
                        color: Colors.white, size: 28 * scale),
                    onPressed: () => onSeek(position + const Duration(seconds: 10)),
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: 40 * scale, minHeight: 40 * scale),
                  ),

                  // 下一集
                  IconButton(
                    icon: Icon(Icons.skip_next_rounded,
                        color: Colors.white, size: 28 * scale),
                    onPressed: onNext,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints(
                        minWidth: 40 * scale, minHeight: 40 * scale),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 倍速标签
            if (speed != 1.0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: GlassTheme.accentPurple.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${speed}x',
                    style: const TextStyle(
                      color: GlassTheme.accentPurple,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(double progress) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: GlassTheme.accentPurple,
          inactiveTrackColor: Colors.white24,
          thumbColor: GlassTheme.accentPurple,
          overlayColor: GlassTheme.accentPurple.withOpacity(0.15),
        ),
        child: Slider(
          value: progress.clamp(0.0, 1.0),
          onChanged: (value) {
            final newPos = Duration(
              milliseconds: (value * duration.inMilliseconds).round(),
            );
            onSeek(newPos);
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }
}