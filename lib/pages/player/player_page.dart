/// 视频播放器页面 — iOS 27 玻璃质感
///
/// 手机/竖屏 → 全屏视频 + 玻璃控制栏
/// 平板横屏 → 左视频 / 右毛玻璃控制面板
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/video_model.dart';
import '../../models/cast_device_model.dart';
import '../../providers/player_provider.dart';
import '../../providers/cast_provider.dart';
import '../../services/app_settings_service.dart';
import '../../services/subtitle_service.dart';
import '../../widgets/player/player_gesture_layer.dart';
import '../../widgets/player/subtitle_overlay.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_slider.dart';
import '../../widgets/glass/safe_glass.dart';
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
  bool _isFullscreen = false;
  late VideoController _videoController;
  late AnimationController _controlsAnim;

  @override
  void initState() {
    super.initState();
    // 使用全局 VideoController，页面销毁时保留引用给 mini player 复用
    _videoController = ref.read(playerProvider).videoController!;
    _controlsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1,
    );
    // 延迟到 widget tree 构建完成后加载视频
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadVideo();
      _startAutoHideTimer();
    });
  }

  @override
  void dispose() {
    _controlsAnim.dispose();
    // 退出播放器：立即落盘进度，避免下次从头播放
    ref.read(playerProvider.notifier).saveProgress();
    // 退出播放器时恢复竖屏 + 非沉浸
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 切换全屏（横屏沉浸）
  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      _isFullscreen = false;
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      _isFullscreen = true;
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (mounted) setState(() {});
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
      onSeekForward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(AppSettingsService.instance.skipSeconds),
      onSeekBackward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(-AppSettingsService.instance.skipSeconds),
      onVolumeUp: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume + 0.05).clamp(0, 1)),
      onVolumeDown: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume - 0.05).clamp(0, 1)),
      onToggleSubtitles: _showSubtitleSheet,
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
              initialBrightness: state.brightness,
              initialVolume: state.volume,
              onBrightnessChange: (value) =>
                  ref.read(playerProvider.notifier).setBrightness(value),
              onVolumeChange: (value) =>
                  ref.read(playerProvider.notifier).setVolume(value),
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
                      _buildGlassTopBar(context, state, isLarge: isLarge),
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
      onSeekForward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(AppSettingsService.instance.skipSeconds),
      onSeekBackward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(-AppSettingsService.instance.skipSeconds),
      onVolumeUp: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume + 0.05).clamp(0, 1)),
      onVolumeDown: () => ref.read(playerProvider.notifier).setVolume(
          (state.volume - 0.05).clamp(0, 1)),
      onToggleSubtitles: _showSubtitleSheet,
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
                    initialBrightness: state.brightness,
                    initialVolume: state.volume,
                    onBrightnessChange: (value) => ref
                        .read(playerProvider.notifier)
                        .setBrightness(value),
                    onVolumeChange: (value) => ref
                        .read(playerProvider.notifier)
                        .setVolume(value),
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
            const VerticalDivider(width: 0.5, color: Color(0x14000000)),
            Expanded(
              child: Container(
                color: GlassTheme.bg,
                child: _buildGlassSidePanel(context, state),
              ),
            ),
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
                  icon: const Icon(Icons.arrow_back_rounded, color: GlassTheme.textPrimary),
                  onPressed: () => context.pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(widget.videoTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary, fontSize: 18,
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
                // 拖动结束才真正 seek，拖动中仅更新视觉（由 GlassSlider 内部跟手）
                onChangeEnd: (v) => ref
                    .read(playerProvider.notifier)
                    .seekTo(Duration(milliseconds: v.round())),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtDuration(state.position),
                      style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 11)),
                  Text(_fmtDuration(state.duration),
                      style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 11)),
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
                  padding: EdgeInsets.zero,
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
                  const Icon(Icons.queue_play_next, size: 16, color: GlassTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text('播放队列 (${state.queue.length})',
                      style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 13)),
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
                                    color: GlassTheme.textPrimary, fontSize: 13)),
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
            _sideGlassRow(
                Icons.subtitles_rounded,
                '字幕',
                state.activeSubtitle?.language ??
                    (state.activeTrackId != null ? '内嵌' : '无'),
                _showSubtitleSheet),
            const SizedBox(height: 8),
            _sideGlassRow(Icons.picture_in_picture_rounded, '画中画', '开启',
                _enterPiP),
            const SizedBox(height: 8),
            _sideGlassRow(Icons.cast_rounded, '投屏', '搜索设备', _showCastSheet),
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
          Icon(icon, size: 18, color: GlassTheme.textSecondary),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 14)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  color: GlassTheme.accentPurple, fontSize: 13)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              color: GlassTheme.textTertiary, size: 16),
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
          Icon(icon, size: 18, color: GlassTheme.textSecondary),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 13)),
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

  Widget _buildGlassTopBar(BuildContext context, PlayerState state,
      {bool isLarge = false}) {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: ClipRect(
        child: SafeBackdropFilter(
          blurSigma: 18,
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
                // 只显示文件名，详细参数放在「详情」弹窗里
                Expanded(
                  child: Text(
                    state.currentVideo?.name ?? widget.videoTitle,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isLarge ? 18 : 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '视频详情',
                  icon: const Icon(Icons.info_outline_rounded,
                      color: Colors.white70),
                  onPressed: () => _showVideoInfoSheet(state),
                ),
                // 播放页内直接搜索投屏设备
                IconButton(
                  tooltip: '投屏',
                  icon: const Icon(Icons.cast_rounded, color: Colors.white70),
                  onPressed: _showCastSheet,
                ),
                IconButton(
                  icon: Icon(
                    _isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white70,
                  ),
                  onPressed: _toggleFullscreen,
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

  // ═══════════════ 视频详情 ═══════════════

  static String _two(int n) => n.toString().padLeft(2, '0');

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _fmtDateTime(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} '
      '${_two(d.hour)}:${_two(d.minute)}';

  /// 音轨描述：编码 + 声道 + 采样率（多轨用 / 分隔）
  String _audioTrackDesc(PlayerState state) {
    final tracks = state.audioTracks;
    if (tracks.isEmpty) return '未知';
    return tracks.map((a) {
      final parts = <String>[
        if (a.codec?.isNotEmpty == true) a.codec!,
        if (a.channelscount != null && a.channelscount! > 0)
          '${a.channelscount}声道',
        if (a.samplerate != null && a.samplerate! > 0)
          '${(a.samplerate! / 1000).toStringAsFixed(1)}kHz',
        if (a.language?.isNotEmpty == true) a.language!,
      ];
      return parts.isEmpty ? '音轨' : parts.join(' ');
    }).join(' / ');
  }

  void _showVideoInfoSheet(PlayerState state) {
    final v = state.currentVideo;
    final rows = <List<String>>[
      ['文件名', v?.name ?? widget.videoTitle],
      [
        '分辨率',
        state.videoWidth > 0
            ? '${state.videoWidth}×${state.videoHeight}'
            : '未知'
      ],
      [
        '视频编码',
        (state.videoCodec?.isNotEmpty == true) ? state.videoCodec! : '未知'
      ],
      [
        '帧率',
        (state.videoFps != null && state.videoFps! > 0)
            ? '${state.videoFps!.toStringAsFixed(2)} fps'
            : '未知'
      ],
      [
        '音频',
        _audioTrackDesc(state),
      ],
      [
        '时长',
        state.duration > Duration.zero ? _fmtDuration(state.duration) : '未知'
      ],
      ['文件大小', v != null && v.size > 0 ? _fmtSize(v.size) : '未知'],
      ['文件时间', v != null ? _fmtDateTime(v.dateModified) : '未知'],
      ['所在文件夹', (v != null && v.folderPath.isNotEmpty) ? v.folderPath : '未知'],
      ['完整路径', v?.path ?? widget.videoPath],
      [
        '内嵌字幕',
        state.embeddedSubtitles.isEmpty
            ? '无'
            : state.embeddedSubtitles.map((t) {
                final label = (t.title?.isNotEmpty == true)
                    ? t.title!
                    : ((t.language?.isNotEmpty == true) ? t.language! : t.id);
                return label;
              }).join(' / ')
      ],
      [
        '解码方式',
        AppSettingsService.instance.hardwareDecoding ? '硬件解码' : '软件解码'
      ],
      ['播放次数', v != null ? '${v.playCount} 次' : '0 次'],
      [
        '上次播放到',
        (v != null && v.lastPosition > 0)
            ? _fmtDuration(Duration(milliseconds: v.lastPosition.toInt()))
            : '从头开始'
      ],
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.8,
        ),
        decoration: const BoxDecoration(
          color: Color(0xF2FFFFFF),
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('视频详情',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              ...rows.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 84,
                          child: Text(r[0],
                              style: const TextStyle(
                                  color: GlassTheme.textTertiary,
                                  fontSize: 13)),
                        ),
                        Expanded(
                          child: Text(r[1],
                              style: const TextStyle(
                                  color: GlassTheme.textPrimary, fontSize: 13)),
                        ),
                      ],
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════ 投屏（播放页内搜索） ═══════════════

  void _showCastSheet() {
    ref.read(castProvider.notifier).startDiscovery();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => const _CastDeviceSheet(),
    );
  }

  // ═══════════════ 字幕 ═══════════════

  /// 字幕面板：内嵌轨道 + 同目录外挂 + 手动添加文件
  void _showSubtitleSheet() {
    // 快照读取：playerProvider 每 200ms 更新位置，
    // 在可随时关闭的弹窗里 watch 它会在关闭瞬间触发 Riverpod 断言
    final st = ref.read(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.75,
        ),
        decoration: const BoxDecoration(
          color: Color(0xF2FFFFFF),
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('字幕',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),

              // 关闭字幕
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.subtitles_off_rounded,
                    size: 20, color: GlassTheme.textSecondary),
                title: const Text('关闭字幕',
                    style: TextStyle(
                        color: GlassTheme.textPrimary, fontSize: 14)),
                trailing: (st.activeSubtitle == null && st.activeTrackId == null)
                    ? const Icon(Icons.check_rounded,
                        color: GlassTheme.accentPurple, size: 18)
                    : null,
                onTap: () {
                  notifier.disableSubtitles();
                  Navigator.pop(ctx);
                },
              ),

              // 内嵌字幕
              _subSectionHeader('内嵌字幕 (${st.embeddedSubtitles.length})'),
              if (st.embeddedSubtitles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 8),
                  child: Text('该视频没有内嵌字幕',
                      style: TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 12)),
                )
              else
                ...st.embeddedSubtitles.map((t) {
                  final isActive = st.activeTrackId == t.id;
                  final label = (t.title?.isNotEmpty == true)
                      ? t.title!
                      : ((t.language?.isNotEmpty == true)
                          ? t.language!
                          : '字幕轨 ${t.id}');
                  final extra = [
                    if (t.language?.isNotEmpty == true && t.language != t.title)
                      t.language!,
                    if (t.codec?.isNotEmpty == true) t.codec!,
                  ].join(' · ');
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.closed_caption_rounded,
                        size: 20, color: GlassTheme.accentTeal),
                    title: Text(label,
                        style: TextStyle(
                            color: isActive
                                ? GlassTheme.accentPurple
                                : GlassTheme.textPrimary,
                            fontSize: 14)),
                    subtitle: extra.isEmpty
                        ? null
                        : Text(extra,
                            style: const TextStyle(
                                color: GlassTheme.textTertiary, fontSize: 11)),
                    trailing: isActive
                        ? const Icon(Icons.check_rounded,
                            color: GlassTheme.accentPurple, size: 18)
                        : null,
                    onTap: () {
                      notifier.selectEmbeddedSubtitle(t);
                      Navigator.pop(ctx);
                    },
                  );
                }),

              // 外挂字幕
              if (st.availableSubtitles.isNotEmpty) ...[
                _subSectionHeader('外挂字幕 (${st.availableSubtitles.length})'),
                ...st.availableSubtitles.map((s) {
                  final isActive = st.activeSubtitle?.path == s.path;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_rounded,
                        size: 20, color: GlassTheme.accentPurple),
                    title: Text(s.title,
                        style: TextStyle(
                            color: isActive
                                ? GlassTheme.accentPurple
                                : GlassTheme.textPrimary,
                            fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: isActive
                        ? const Icon(Icons.check_rounded,
                            color: GlassTheme.accentPurple, size: 18)
                        : null,
                    onTap: () {
                      notifier.loadExternalSubtitle(s.path,
                          language: s.language, title: s.title);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],

              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: GlassButton.outlined(
                  icon: Icons.add_rounded,
                  label: '添加字幕文件…',
                  foregroundColor: GlassTheme.accentTeal,
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickSubtitleFile(
                        st.currentVideo?.path ?? widget.videoPath);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subSectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(text,
          style: const TextStyle(
              color: GlassTheme.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    );
  }

  /// 选择字幕文件（扫描视频同目录与常用下载目录）
  Future<void> _pickSubtitleFile(String videoPath) async {
    final files = await SubtitleService.findCandidateSubtitles(videoPath);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        decoration: const BoxDecoration(
          color: Color(0xF2FFFFFF),
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择字幕文件',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (files.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '未找到字幕文件\n请把 .srt / .ass / .vtt 放在视频同目录或 Download 文件夹',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: GlassTheme.textTertiary,
                        fontSize: 13,
                        height: 1.6),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: files.length,
                  itemBuilder: (context, i) {
                    final f = files[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.subtitles_rounded,
                          size: 20, color: GlassTheme.accentPurple),
                      title: Text(f.title,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(f.path,
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () {
                        ref.read(playerProvider.notifier).loadExternalSubtitle(
                              f.path,
                              language: f.language,
                              title: f.title,
                            );
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
          ],
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
        child: SafeBackdropFilter(
          blurSigma: 18,
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
                      onChangeEnd: (v) => ref
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
                      // 倍速
                      GlassButton(
                        icon: Icons.speed_rounded,
                        compact: true,
                        onTap: () => setState(
                            () => _showSpeedSelector = !_showSpeedSelector),
                      ),
                      // 字幕（内嵌 / 外挂 / 手动添加）
                      GlassButton(
                        icon: Icons.subtitles_rounded,
                        compact: true,
                        foregroundColor: (state.activeSubtitle != null ||
                                state.activeTrackId != null)
                            ? GlassTheme.accentPurple
                            : null,
                        onTap: _showSubtitleSheet,
                      ),
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
                      // 投屏（页内搜索设备）
                      GlassButton(
                        icon: Icons.cast_rounded,
                        compact: true,
                        onTap: _showCastSheet,
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
}

// ═══════════════ 投屏设备面板（播放页内） ═══════════════
//
// 用轮询 + mounted 保护读取 castProvider：
// 直接在弹窗里 watch 会在弹窗关闭瞬间对已卸载的元素触发重建断言。

class _CastDeviceSheet extends ConsumerStatefulWidget {
  const _CastDeviceSheet();

  @override
  ConsumerState<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends ConsumerState<_CastDeviceSheet> {
  late CastState _castState;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _castState = ref.read(castProvider);
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      final next = ref.read(castProvider);
      if (!identical(next, _castState)) {
        setState(() => _castState = next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(castProvider.notifier);
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF2FFFFFF),
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(GlassTheme.radiusXl)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('投屏到设备',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_castState.isDiscovering)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: GlassTheme.accentPurple),
                ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                color: GlassTheme.textTertiary,
                onPressed: () {
                  notifier.refresh();
                  setState(() => _castState = ref.read(castProvider));
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (_castState.isConnected && _castState.activeDevice != null)
            ListTile(
              leading: const Icon(Icons.cast_connected_rounded,
                  color: GlassTheme.accentTeal),
              title: Text('已连接：${_castState.activeDevice!.name}',
                  style: const TextStyle(
                      color: GlassTheme.textPrimary, fontSize: 14)),
              trailing: TextButton(
                onPressed: notifier.disconnect,
                child: const Text('断开',
                    style: TextStyle(color: GlassTheme.accentPink)),
              ),
            ),
          if (_castState.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_castState.isDiscovering)
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: GlassTheme.accentPurple),
                      )
                    else
                      const Icon(Icons.cast_rounded,
                          size: 40, color: GlassTheme.textTertiary),
                    const SizedBox(height: 10),
                    Text(
                      _castState.isDiscovering ? '正在搜索设备…' : '未发现投屏设备',
                      style: const TextStyle(
                          color: GlassTheme.textSecondary, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    const Text('请确保设备与手机在同一 Wi-Fi',
                        style: TextStyle(
                            color: GlassTheme.textTertiary, fontSize: 12)),
                  ],
                ),
              ),
            )
          else
            ..._castState.devices.map((d) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    d.protocol == CastProtocol.chromecast
                        ? Icons.cast_rounded
                        : Icons.tv_rounded,
                    color: GlassTheme.accentPurple,
                  ),
                  title: Text(d.name,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary, fontSize: 14)),
                  subtitle: Text(
                    d.host.isNotEmpty ? d.host : d.protocol.name,
                    style: const TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 12),
                  ),
                  trailing: d.status == CastDeviceStatus.connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: GlassTheme.accentPurple))
                      : const Icon(Icons.chevron_right_rounded,
                          color: GlassTheme.textTertiary),
                  onTap: () => notifier.connect(d),
                )),
        ],
      ),
    );
  }
}
