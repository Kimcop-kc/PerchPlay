import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../models/video_model.dart';
import '../models/subtitle_model.dart';
import '../services/subtitle_service.dart';
import '../services/database_service.dart';
import '../services/app_settings_service.dart';

/// 播放器状态
class PlayerState {
  final Player player;
  final VideoController? videoController;
  final bool isPlaying;
  final bool isBuffering;
  final bool isCompleted;
  final Duration position;
  final Duration duration;
  final double volume;
  final double brightness;
  final double speed;
  final VideoModel? currentVideo;
  final List<VideoModel> queue;
  final int currentIndex;
  final List<SubtitleModel> availableSubtitles;
  final SubtitleModel? activeSubtitle;
  final List<SubtitleEntry>? subtitleEntries;
  final int activeSubtitleIndex;

  const PlayerState({
    required this.player,
    this.videoController,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isCompleted = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
    this.brightness = 0.5,
    this.speed = 1.0,
    this.currentVideo,
    this.queue = const [],
    this.currentIndex = 0,
    this.availableSubtitles = const [],
    this.activeSubtitle,
    this.subtitleEntries,
    this.activeSubtitleIndex = 0,
  });

  PlayerState copyWith({
    Player? player,
    VideoController? videoController,
    bool? isPlaying,
    bool? isBuffering,
    bool? isCompleted,
    Duration? position,
    Duration? duration,
    double? volume,
    double? brightness,
    double? speed,
    VideoModel? currentVideo,
    List<VideoModel>? queue,
    int? currentIndex,
    List<SubtitleModel>? availableSubtitles,
    SubtitleModel? activeSubtitle,
    List<SubtitleEntry>? subtitleEntries,
    int? activeSubtitleIndex,
  }) {
    return PlayerState(
      player: player ?? this.player,
      videoController: videoController ?? this.videoController,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      isCompleted: isCompleted ?? this.isCompleted,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      brightness: brightness ?? this.brightness,
      speed: speed ?? this.speed,
      currentVideo: currentVideo ?? this.currentVideo,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      availableSubtitles: availableSubtitles ?? this.availableSubtitles,
      activeSubtitle: activeSubtitle ?? this.activeSubtitle,
      subtitleEntries: subtitleEntries ?? this.subtitleEntries,
      activeSubtitleIndex: activeSubtitleIndex ?? this.activeSubtitleIndex,
    );
  }
}

class PlayerNotifier extends StateNotifier<PlayerState> {
  final DatabaseService _db = DatabaseService.instance;
  late final VideoController _globalController;

  PlayerNotifier()
      : super(PlayerState(
          player: Player(),
        )) {
    // VideoController 由 Provider 全局创建，跨页面复用
    _globalController = VideoController(state.player);
    state = state.copyWith(videoController: _globalController);
    _setupListeners();
  }

  /// 当前 media_kit Player 实例（播放页用它创建 VideoController）
  Player get player => state.player;

  /// 绑定播放页创建的 VideoController（保留兼容）
  void attachVideoController(VideoController controller) {
    state = state.copyWith(videoController: controller);
  }

  void _setupListeners() {
    state.player.stream.position.listen((pos) {
      state = state.copyWith(position: pos);
      _updateActiveSubtitle();
      // 每 5 秒落盘一次进度
      final now = DateTime.now();
      if (_lastSaveAt == null ||
          now.difference(_lastSaveAt!).inSeconds >= 5) {
        _lastSaveAt = now;
        _persistProgress();
      }
    });

    state.player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
      // 时长就绪后补一次 seek（首次 seek 可能早于媒体加载完成而被忽略）
      final pending = _pendingResume;
      if (pending != null && dur > Duration.zero) {
        _pendingResume = null;
        state.player.seek(pending);
      }
    });

    state.player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    state.player.stream.buffering.listen((buffering) {
      state = state.copyWith(isBuffering: buffering);
    });

    state.player.stream.completed.listen((_) {
      state = state.copyWith(isCompleted: true);
      // 播完清零进度并记入历史，下次从头播放
      final v = state.currentVideo;
      if (v != null) {
        _db.updatePlayPosition(v.id, 0,
            durationMs: state.duration.inMilliseconds);
      }
      // 自动播放下一个（受设置控制）
      if (AppSettingsService.instance.autoPlayNext) {
        _playNext();
      }
    });
  }

  DateTime? _lastSaveAt;
  Duration? _pendingResume;

  /// 把当前进度写库（真实视频 id）
  Future<void> _persistProgress() async {
    final video = state.currentVideo;
    if (video == null) return;
    final ms = state.position.inMilliseconds;
    if (ms <= 0) return;
    final durMs = state.duration.inMilliseconds;
    // 只有较长视频播到结尾附近才清零（短视频不适用，否则进度永远存不下来）
    final nearEnd = durMs > 30000 && ms >= durMs - 3000;
    try {
      await _db.saveProgress(
        video.id,
        nearEnd ? 0 : ms.toDouble(),
        durationMs: durMs,
      );
    } catch (_) {}
  }

  /// 外部调用：立即保存进度（退出播放器 / 关闭小窗时）
  Future<void> saveProgress() => _persistProgress();

  /// 加载视频
  Future<void> loadVideo(VideoModel video,
      {List<VideoModel>? queue, int? startIndex}) async {
    // 播放页可能只传 path/title 构造的临时模型；
    // 从数据库取真实记录，拿到真实 id 与上次进度。
    VideoModel effective = video;
    try {
      final stored = await _db.getVideoByPath(video.path);
      if (stored != null) effective = stored;
    } catch (_) {}

    await state.player.open(Media(video.path));
    state = state.copyWith(
      currentVideo: effective,
      queue: queue ?? [effective],
      currentIndex: startIndex ?? 0,
      isCompleted: false,
      position: Duration.zero,
      speed: AppSettingsService.instance.defaultSpeed,
    );
    _lastSaveAt = DateTime.now();

    // 应用默认播放速度
    await state.player
        .setRate(AppSettingsService.instance.defaultSpeed);

    // 恢复上次播放位置（<1s 视为从头开始）
    final resumeMs = effective.lastPosition;
    debugPrint('[Player] load "${effective.name}" id=${effective.id} '
        'resume=${resumeMs.toInt()}ms');
    if (resumeMs > 1000) {
      _pendingResume = Duration(milliseconds: resumeMs.toInt());
      try {
        await state.player.seek(_pendingResume!);
      } catch (_) {}
    }

    // 加载外挂字幕
    final subtitles =
        await SubtitleService.findExternalSubtitles(video.path);
    state = state.copyWith(availableSubtitles: subtitles);
  }

  /// 停止播放并清除当前视频（关闭小窗/后台播放）
  Future<void> stop() async {
    // 先落盘进度，再停止
    await _persistProgress();
    try {
      await state.player.stop();
    } catch (_) {}
    state = state.copyWith(
      currentVideo: null,
      isPlaying: false,
      isCompleted: false,
      position: Duration.zero,
      duration: Duration.zero,
    );
  }

  /// 播放/暂停
  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await state.player.pause();
    } else {
      await state.player.play();
    }
  }

  /// 跳转
  Future<void> seekTo(Duration position) async {
    await state.player.seek(position);
  }

  /// 相对跳转
  Future<void> seekRelative(int seconds) async {
    final newPos = state.position + Duration(seconds: seconds);
    if (newPos < Duration.zero) {
      await state.player.seek(Duration.zero);
    } else if (newPos > state.duration) {
      await state.player.seek(state.duration);
    } else {
      await state.player.seek(newPos);
    }
  }

  /// 设置音量（0-1，控制 media_kit 播放器音量）
  Future<void> setVolume(double vol) async {
    final v = vol.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    await state.player.setVolume(v * 100);
  }

  /// 设置亮度（0-1，控制系统屏幕亮度）
  Future<void> setBrightness(double brightness) async {
    final b = brightness.clamp(0.0, 1.0);
    state = state.copyWith(brightness: b);
    try {
      await ScreenBrightness().setScreenBrightness(b);
    } catch (e) {
      // ignore: avoid_print
      print('[Brightness] 设置系统亮度失败: $e');
    }
  }

  /// 设置倍速
  Future<void> setSpeed(double speed) async {
    state = state.copyWith(speed: speed);
    await state.player.setRate(speed);
  }

  /// 播放下一个
  Future<void> _playNext() async {
    if (state.currentIndex < state.queue.length - 1) {
      final nextVideo = state.queue[state.currentIndex + 1];
      await loadVideo(nextVideo,
          queue: state.queue, startIndex: state.currentIndex + 1);
      await state.player.play();
    }
  }

  /// 公开的播放下一个
  Future<void> playNext() => _playNext();

  /// 播放上一个
  Future<void> playPrevious() async {
    if (state.currentIndex > 0) {
      final prevVideo = state.queue[state.currentIndex - 1];
      await loadVideo(prevVideo,
          queue: state.queue, startIndex: state.currentIndex - 1);
      if (state.isPlaying) await state.player.play();
    }
  }

  /// 选择字幕轨道
  void selectSubtitle(SubtitleModel subtitle) {
    state = state.copyWith(activeSubtitle: subtitle);
  }

  /// 字幕相关
  Future<void> loadSubtitle(SubtitleModel subtitle) async {
    // media_kit 自带字幕支持，也可手动解析
    final isEmbedded = false; // media_kit handles embedded
    if (!isEmbedded) {
      final entries = await _parseSubtitle(subtitle);
      state = state.copyWith(
        activeSubtitle: subtitle,
        subtitleEntries: entries,
      );
    }
  }

  Future<List<SubtitleEntry>?> _parseSubtitle(SubtitleModel subtitle) async {
    if (subtitle.path.endsWith('.srt')) {
      return SubtitleService.parseSrt(subtitle.path);
    } else if (subtitle.path.endsWith('.vtt')) {
      return SubtitleService.parseVtt(subtitle.path);
    }
    return null;
  }

  void _updateActiveSubtitle() {
    final entries = state.subtitleEntries;
    if (entries == null || entries.isEmpty) return;

    for (int i = 0; i < entries.length; i++) {
      if (state.position >= entries[i].start &&
          state.position <= entries[i].end) {
        if (i != state.activeSubtitleIndex) {
          state = state.copyWith(activeSubtitleIndex: i);
        }
        return;
      }
    }
  }

  @override
  void dispose() {
    state.player.dispose();
    super.dispose();
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>(
  (ref) => PlayerNotifier(),
);
