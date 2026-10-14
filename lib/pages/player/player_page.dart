/// 视频播放器页面 — iOS 27 玻璃质感
///
/// 手机/竖屏 → 全屏视频 + 玻璃控制栏
/// 平板横屏 → 左视频 / 右毛玻璃控制面板
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/video_model.dart';
import '../../providers/player_provider.dart';
import '../../widgets/player/player_gesture_layer.dart';
import '../../widgets/player/subtitle_overlay.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_slider.dart';
import '../../widgets/keyboard_shortcut_handler.dart';

class PlayerPage extends ConsumerStatefulWidget {
  final String videoPath;
  final String videoTitle;
  const PlayerPage({
    super.key,
    required this.videoPath,
    required this.videoTitle,
  });

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with TickerProviderStateMixin {
  bool _showControls = true;
  bool _showSpeedSelector = false;
  bool _showSubtitleSelector = false;
  late VideoController _videoController;
  late AnimationController _controlsAnim;

  @override
  void initState() {
    super.initState();
    final playerNotifier = ref.read(playerProvider.notifier);
    _videoController = VideoController(playerNotifier.player);
    playerNotifier.attachVideoController(_videoController);
    _controlsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1,
    );
    _loadVideo();
    _startAutoHideTimer();
  }

  void _startAutoHideTimer() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && ref.read(playerProvider).isPlaying) {
        _hideControls();
      }
    });
  }

  void _toggleControls() {
    if (_showControls) {
      _hideControls();
    } else {
      _showControls = true;
      _controlsAnim.forward();
      _startAutoHideTimer();
    }
  }

  void _hideControls() {
    _controlsAnim.reverse().then((_) {
      if (mounted) setState(() => _showControls = false);
    });
  }

  Future<void> _loadVideo() async {
    await ref.read(playerProvider.notifier).loadVideo(
          VideoModel(
            id: widget.videoPath,
            path: widget.videoPath,
            name: widget.videoTitle,
            folderPath: '',
            size: 0,
            durationMs: 0,
            dateAdded: DateTime.now(),
            dateModified: DateTime.now(),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(playerProvider);
    final isLandscape = AppBreakpoints.isLandscape(context);
    final isLarge = AppBreakpoints.isLargeScreen(context);

    if (isLandscape && isLarge) {
      return _buildSplitLayout(context, playerState);
    }
    return _buildFullScreenLayout(context, playerState);
  }

  // ═══════════════ 全屏（手机/竖屏） ═══════════════

  Widget _buildFullScreenLayout(BuildContext context, PlayerState state) {
    final isLarge = AppBreakpoints.isLargeScreen(context);
    final buttonScale = isLarge ? 1.3 : 1.0;

    return KeyboardShortcutHandler(
      onPlayPause: () => ref.read(playerProvider.notifier).togglePlayPause(),
      onSeekForward: () => ref.read(playerProvider.notifier).seekRelative(10),
      onSeekBackward: () => ref.read(playerProvider.notifier).seekRelative(-10),
      onVolumeUp: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume + 0.05).clamp(0, 1)),
      onVolumeDown: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume - 0.05).clamp(0, 1)),
      onToggleSubtitles: () =>
          setState(() => _showSubtitleSelector = !_showSubtitleSelector),
      onToggleSpeed: () =>
          setState(() => _showSpeedSelector = !_showSpeedSelector),
      onExit: () => context.pop(),
      onSeekFraction: (fraction) {
        ref.read(playerProvider.notifier).seekRelative(
              ((fraction * state.duration.inMilliseconds / 1000) -
                      state.position.inMilliseconds / 1000)
                  .round(),
            );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _buildVideoLayer(state),
            PlayerGestureLayer(
              onTap: _toggleControls,
              onDoubleTap: () =>
                  ref.read(playerProvider.notifier).togglePlayPause(),
              onBrightnessChange: (delta) => ref
                  .read(playerProvider.notifier)
                  .setBrightness(state.brightness + delta),
              onVolumeChange: (delta) => ref
                  .read(playerProvider.notifier)
                  .setVolume(state.volume + delta),
              onSeek: (seconds) =>
                  ref.read(playerProvider.notifier).seekRelative(seconds),
            ),
            // 字幕
            if (state.subtitleEntries != null &&
                state.subtitleEntries!.isNotEmpty)
              Positioned(
                bottom: isLarge ? 120 : 80,
                left: isLarge ? 40 : 20,
                right: isLarge ? 40 : 20,
                child: SubtitleOverlay(
                  entries: state.subtitleEntries!,
                  activeIndex: state.activeSubtitleIndex,
                ),
              ),
            // 弹出面板
            _buildPopupMenus(context, state),
            // 控制栏（玻璃动画）
            if (_showControls)
              GlassAnimatedBuilder(
                listenable: _controlsAnim,
                builder: (context, _) => Opacity(
                  opacity: _controlsAnim.value,
                  child: Stack(
                    children: [
                      _buildGlassTopBar(context, isLarge: isLarge),
                      _buildGlassBottomControls(context, state,
                          scale: buttonScale),
                      _buildCenterPlayButton(state, scale: buttonScale),
                    ],
                  ),
                ),
              ),
            // 缓冲
            if (state.isBuffering)
              Center(
                child: CircularProgressIndicator(
                  color: GlassTheme.accentPurple,
                  strokeWidth: isLarge ? 4 : 3,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 平板横屏分栏 ═══════════════

  Widget _buildSplitLayout(BuildContext context, PlayerState state) {
    final size = MediaQuery.of(context).size;
    final videoWidth = size.width * 0.62;

    return KeyboardShortcutHandler(
      onPlayPause: () => ref.read(playerProvider.notifier).togglePlayPause(),
      onSeekForward: () => ref.read(playerProvider.notifier).seekRelative(10),
      onSeekBackward: () => ref.read(playerProvider.notifier).seekRelative(-10),
      onVolumeUp: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume + 0.05).clamp(0, 1)),
      onVolumeDown: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume - 0.05).clamp(0, 1)),
      onToggleSubtitles: () =>
          setState(() => _showSubtitleSelector = !_showSubtitleSelector),
      onToggleSpeed: () =>
          setState(() => _showSpeedSelector = !_showSpeedSelector),
      onExit: () => context.pop(),
      onSeekFraction: (fraction) {
        ref.read(playerProvider.notifier).seekRelative(
              ((fraction * state.duration.inMilliseconds / 1000) -
                      state.position.inMilliseconds / 1000)
                  .round(),
            );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Row(
          children: [
            SizedBox(
              width: videoWidth,
              child: Stack(
                children: [
                  _buildVideoLayer(state),
                  PlayerGestureLayer(
                    onTap: _toggleControls,
                    onBrightnessChange: (delta) => ref
                        .read(playerProvider.notifier)
                        .setBrightness(state.brightness + delta),
                    onVolumeChange: (delta) => ref
                        .read(playerProvider.notifier)
                        .setVolume(state.volume + delta),
                    onSeek: (seconds) => ref
                        .read(playerProvider.notifier)
                        .seekRelative(seconds),
                  ),
                  if (state.subtitleEntries != null &&
                      state.subtitleEntries!.isNotEmpty)
                    Positioned(
                      bottom: 90, left: 40, right: 40,
                      child: SubtitleOverlay(
                        entries: state.subtitleEntries!,
                        activeIndex: state.activeSubtitleIndex,
                      ),
                    ),
                  if (state.isBuffering)
                    const Center(
                      child: CircularProgressIndicator(
                          color: GlassTheme.accentPurple),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 0.5, color: Color(0x10FFFFFF)),
            Expanded(child: _buildGlassSidePanel(context, state)),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 玻璃侧边面板（平板横屏） ═══════════════

  Widget _buildGlassSidePanel(BuildContext context, PlayerState state) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题 + 返回
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => context.pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(widget.videoTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 18,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 进度条
            if (state.duration > Duration.zero) ...[
              GlassSlider(
                value: state.position.inMilliseconds.toDouble(),
                min: 0,
                max: state.duration.inMilliseconds.toDouble(),
                activeColor: GlassTheme.accentPurple,
                height: 5,
                onChanged: (v) =>
                    ref.read(playerProvider.notifier).seekTo(
                          Duration(milliseconds: v.round()),
                        ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtDuration(state.position),
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  Text(_fmtDuration(state.duration),
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // 播放控制按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GlassButton(
                  icon: Icons.skip_previous_rounded,
                  compact: true,
                  onTap: () =>
                      ref.read(playerProvider.notifier).playPrevious(),
                ),
                const SizedBox(width: 12),
                GlassButton.filled(
                  icon: state.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  width: 52,
                  height: 52,
                  onTap: () =>
                      ref.read(playerProvider.notifier).togglePlayPause(),
                ),
                const SizedBox(width: 12),
                GlassButton(
                  icon: Icons.skip_next_rounded,
                  compact: true,
                  onTap: () => ref.read(playerProvider.notifier).playNext(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 队列
            if (state.queue.length > 1) ...[
              Row(
                children: [
                  const Icon(Icons.queue_play_next, size: 16, color: Colors.white54),
                  const SizedBox(width: 6),
                  Text('播放队列 (${state.queue.length})',
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 8),
              ...state.queue.take(5).map((v) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: GlassCard(
                      radius: GlassTheme.radiusXs,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      tint: GlassTheme.tintPurple,
                      child: Row(
                        children: [
                          Icon(Icons.movie_rounded,
                              size: 14, color: GlassTheme.accentPurple),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(v.name, maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                  )),
              const SizedBox(height: 20),
            ],

            // 快捷操作
            _sideGlassRow(Icons.speed_rounded, '速度', '${state.speed}x',
                () => setState(() => _showSpeedSelector = !_showSpeedSelector)),
            const SizedBox(height: 8),
            _sideGlassRow(Icons.subtitles_rounded, '字幕',
                state.activeSubtitle?.language ?? '无',
                () => setState(() => _showSubtitleSelector = !_showSubtitleSelector)),
            const SizedBox(height: 8),
            _sideGlassRow(Icons.picture_in_picture_rounded, '画中画', '开启',
                _enterPiP),
            const SizedBox(height: 8),
            _sideGlassRow(Icons.cast_rounded, '投屏', '设备',
                () => context.pushNamed('cast')),
            const SizedBox(height: 20),

            // 音量
            _sliderRow(Icons.volume_up_rounded, '音量', state.volume,
                (v) => ref.read(playerProvider.notifier).setVolume(v)),
            const SizedBox(height: 12),
            // 亮度
            _sliderRow(Icons.brightness_6_rounded, '亮度', state.brightness,
                (v) => ref.read(playerProvider.notifier).setBrightness(v)),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  Widget _sideGlassRow(
      IconData icon, String label, String value, VoidCallback onTap) {
    return GlassCard(
      radius: GlassTheme.radiusSm,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white54),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: GlassTheme.accentPurple, fontSize: 13)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              color: Colors.white24, size: 16),
        ],
      ),
    );
  }

  Widget _sliderRow(
      IconData icon, String label, double value, ValueChanged<double> onChange) {
    return GlassCard(
      radius: GlassTheme.radiusSm,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white54),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(width: 10),
          Expanded(
            child: GlassSlider(
              value: value,
              height: 3,
              activeColor: GlassTheme.accentPurple,
              showThumb: false,
              onChanged: onChange,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════ 玻璃顶栏 ═══════════════

  Widget _buildGlassTopBar(BuildContext context, {bool isLarge = false}) {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => context.pop(),
                ),
                Expanded(
                  child: Text(
                    widget.videoTitle,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isLarge ? 18 : 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.cast_rounded, color: Colors.white70),
                  onPressed: () => context.pushNamed('cast'),
                ),
                IconButton(
                  icon: const Icon(Icons.picture_in_picture_rounded,
                      color: Colors.white70),
                  onPressed: _enterPiP,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════ 玻璃底部控制栏 ═══════════════

  Widget _buildGlassBottomControls(BuildContext context, PlayerState state,
      {double scale = 1.0}) {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 8,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.7),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度条
                if (state.duration > Duration.zero)
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 16 * scale),
                    child: GlassSlider(
                      value: state.position.inMilliseconds.toDouble(),
                      min: 0,
                      max: state.duration.inMilliseconds.toDouble(),
                      activeColor: GlassTheme.accentPurple,
                      height: 4,
                      onChanged: (v) => ref
                          .read(playerProvider.notifier)
                          .seekTo(Duration(milliseconds: v.round())),
                    ),
                  ),
                SizedBox(height: 4 * scale),
                // 时间
                if (state.duration > Duration.zero)
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 20 * scale),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmtDuration(state.position),
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11 * scale)),
                        Text(_fmtDuration(state.duration),
                            style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11 * scale)),
                      ],
                    ),
                  ),
                SizedBox(height: 6 * scale),
                // 按钮行
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 12 * scale),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      GlassButton(
                        icon: Icons.skip_previous_rounded,
                        compact: true,
                        onTap: () =>
                            ref.read(playerProvider.notifier).playPrevious(),
                      ),
                      GlassButton(
                        icon: state.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        compact: true,
                        onTap: () => ref
                            .read(playerProvider.notifier)
                            .togglePlayPause(),
                      ),
                      GlassButton(
                        icon: Icons.skip_next_rounded,
                        compact: true,
                        onTap: () =>
                            ref.read(playerProvider.notifier).playNext(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterPlayButton(PlayerState state, {double scale = 1.0}) {
    return Center(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: state.isPlaying ? 0 : 1,
          child: GlassButton.filled(
            icon: Icons.play_arrow_rounded,
            width: (64 * scale).clamp(48, 80),
            height: (64 * scale).clamp(48, 80),
          ),
        ),
      ),
    );
  }

  // ═══════════════ 弹出面板 ═══════════════

  Widget _buildPopupMenus(BuildContext context, PlayerState state) {
    return Stack(
      children: [
        if (_showSpeedSelector)
          Positioned(
            right: 20,
            bottom: 140,
            child: GlassPanel(
              radius: GlassTheme.radiusLg,
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((s) {
                  final isActive = state.speed == s;
                  return GlassButton(
                    label: '${s}x',
                    height: 36,
                    width: 52,
                    outlined: !isActive,
                    filled: isActive,
                    onTap: () {
                      ref.read(playerProvider.notifier).setSpeed(s);
                      setState(() => _showSpeedSelector = false);
                    },
                  );
                }).toList(),
              ),
            ),
          ),
        if (_showSubtitleSelector)
          Positioned(
            right: 20,
            bottom: 140,
            child: GlassPanel(
              radius: GlassTheme.radiusLg,
              padding: const EdgeInsets.all(12),
              width: 200,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: state.availableSubtitles.map((s) {
                  final isActive = state.activeSubtitle?.path == s.path;
                  return ListTile(
                    dense: true,
                    title: Text(s.language,
                        style: TextStyle(
                            color: isActive
                                ? GlassTheme.accentPurple
                                : Colors.white,
                            fontSize: 13)),
                    trailing: isActive
                        ? const Icon(Icons.check_rounded,
                            color: GlassTheme.accentPurple, size: 18)
                        : null,
                    onTap: () {
                      ref.read(playerProvider.notifier).selectSubtitle(s);
                      setState(() => _showSubtitleSelector = false);
                    },
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════ Video Layer ═══════════════

  Widget _buildVideoLayer(PlayerState state) {
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(GlassTheme.radiusLg),
          topRight: Radius.circular(GlassTheme.radiusLg),
        ),
        child: Video(
          controller: _videoController,
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  void _enterPiP() {
    // PiP via native bridge
  }

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _controlsAnim.dispose();
    super.dispose();
  }
}
