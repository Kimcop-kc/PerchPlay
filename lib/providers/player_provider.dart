import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/video_model.dart';
import '../models/subtitle_model.dart';
import '../services/subtitle_service.dart';
import '../services/database_service.dart';

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

  PlayerNotifier()
      : super(PlayerState(
          player: Player(),
        )) {
    _setupListeners();
  }

  /// 当前 media_kit Player 实例（播放页用它创建 VideoController）
  Player get player => state.player;

  /// 绑定播放页创建的 VideoController
  void attachVideoController(VideoController controller) {
    state = state.copyWith(videoController: controller);
  }

  void _setupListeners() {
    state.player.stream.position.listen((pos) {
      state = state.copyWith(position: pos);
      _updateActiveSubtitle();
      // 定期保存进度（每5秒）
      if (pos.inMilliseconds % 5000 < 250 && state.currentVideo != null) {
        _db.updatePlayPosition(
            state.currentVideo!.id, pos.inMilliseconds.toDouble());
      }
    });

    state.player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
    });

    state.player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    state.player.stream.buffering.listen((buffering) {
      state = state.copyWith(isBuffering: buffering);
    });

    state.player.stream.completed.listen((_) {
      state = state.copyWith(isCompleted: true);
      // 自动播放下一个
      _playNext();
    });
  }

  /// 加载视频
  Future<void> loadVideo(VideoModel video,
      {List<VideoModel>? queue, int? startIndex}) async {
    await state.player.open(Media(video.path));
    state = state.copyWith(
      currentVideo: video,
      queue: queue ?? [video],
      currentIndex: startIndex ?? 0,
      isCompleted: false,
      position: Duration.zero,
    );

    // 恢复上次播放位置
    if (video.lastPosition > 0) {
      await state.player.seek(Duration(milliseconds: video.lastPosition.toInt()));
    }

    // 加载外挂字幕
    final subtitles =
        await SubtitleService.findExternalSubtitles(video.path);
    state = state.copyWith(availableSubtitles: subtitles);
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

  /// 设置音量
  Future<void> setVolume(double vol) async {
    state = state.copyWith(volume: vol.clamp(0.0, 1.0));
    await state.player.setVolume(vol.clamp(0.0, 1.0) * 100);
  }

  /// 设置亮度
  void setBrightness(double brightness) {
    state = state.copyWith(brightness: brightness.clamp(0.0, 1.0));
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
