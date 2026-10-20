import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../models/video_model.dart';
import '../models/subtitle_model.dart';
import '../services/subtitle_service.dart';
import '../services/subtitle_auto_service.dart';
import '../services/subtitle_matcher.dart';
import '../services/database_service.dart';
import '../services/app_settings_service.dart';
import '../services/device_info_service.dart';
import '../services/native_bridge_service.dart';
import '../services/library_prune_service.dart';

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

  /// 视频画面尺寸（分辨率），未知为 0
  final int videoWidth;
  final int videoHeight;

  /// 内嵌字幕轨道（来自容器）
  final List<SubtitleTrack> embeddedSubtitles;

  /// 当前选中的内嵌轨道 id
  final String? activeTrackId;

  /// 视频编码 / 帧率 / 音频轨（详情展示）
  final String? videoCodec;
  final double? videoFps;
  final List<AudioTrack> audioTracks;

  /// 当前选中的音轨 id（`no` = 静音，`auto` = 默认）。null = 尚未明确选择。
  final String? activeAudioTrackId;

  /// HDR / 色彩信息（来自 mpv video-params，识别 HDR10 / 杜比视界 / SDR）
  final String? colorPrimaries; // 色域：bt.2020 / bt.709 / ...
  final String? transferFunction; // 传递函数：pq / hlg / bt.1886 / ...
  final double? sigPeak; // 信号峰值亮度（HDR 才有，SDR 通常 null 或 1.0）

  /// 第二字幕：内嵌轨道 id（交给 mpv 的 secondary-sid 渲染）
  final String? secondaryTrackId;

  /// 第二字幕：外挂文件（由自绘浮层渲染，可同时与主字幕显示）
  final SubtitleModel? secondarySubtitle;
  final List<SubtitleEntry>? secondaryEntries;
  final int secondarySubtitleIndex;

  /// 当前 mpv 正在显示的字幕文本（多行，来自 `player.stream.subtitle`）。
  ///
  /// 统一字幕渲染的**唯一事实来源**：无论内嵌还是外挂，mpv 都把当前应该
  /// 显示的字幕吐到这里，浮层只渲染这份文本，避免「mpv 画一份 + 自绘浮层
  /// 又画一份」的双重/错位 bug。
  final List<String> currentSubtitleLines;

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
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.embeddedSubtitles = const [],
    this.activeTrackId,
    this.videoCodec,
    this.videoFps,
    this.audioTracks = const [],
    this.activeAudioTrackId,
    this.colorPrimaries,
    this.transferFunction,
    this.sigPeak,
    this.secondaryTrackId,
    this.secondarySubtitle,
    this.secondaryEntries,
    this.secondarySubtitleIndex = 0,
    this.currentSubtitleLines = const [],
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
    int? videoWidth,
    int? videoHeight,
    List<SubtitleTrack>? embeddedSubtitles,
    String? activeTrackId,
    String? videoCodec,
    double? videoFps,
    List<AudioTrack>? audioTracks,
    String? activeAudioTrackId,
    String? colorPrimaries,
    String? transferFunction,
    double? sigPeak,
    String? secondaryTrackId,
    SubtitleModel? secondarySubtitle,
    List<SubtitleEntry>? secondaryEntries,
    int? secondarySubtitleIndex,
    List<String>? currentSubtitleLines,
    bool clearActiveSubtitle = false,
    bool clearTrackId = false,
    bool clearMediaInfo = false,
    bool clearSecondaryTrackId = false,
    bool clearSecondarySubtitle = false,
    // 注意：currentVideo 用 `??` 合并，传 null 是"不改"而不是"清空"。
    // 想表达"停止播放、没有当前视频"必须用这个显式标志，
    // 否则 stop() 清不掉它 —— 首页小窗会以为自己还该显示。
    bool clearCurrentVideo = false,
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
      currentVideo: clearCurrentVideo
          ? null
          : (currentVideo ?? this.currentVideo),
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      availableSubtitles: availableSubtitles ?? this.availableSubtitles,
      activeSubtitle: clearActiveSubtitle
          ? null
          : (activeSubtitle ?? this.activeSubtitle),
      subtitleEntries: subtitleEntries ?? this.subtitleEntries,
      activeSubtitleIndex: activeSubtitleIndex ?? this.activeSubtitleIndex,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      embeddedSubtitles: embeddedSubtitles ?? this.embeddedSubtitles,
      activeTrackId: clearTrackId
          ? null
          : (activeTrackId ?? this.activeTrackId),
      videoCodec: clearMediaInfo ? null : (videoCodec ?? this.videoCodec),
      videoFps: clearMediaInfo ? null : (videoFps ?? this.videoFps),
      audioTracks: clearMediaInfo
          ? const []
          : (audioTracks ?? this.audioTracks),
      activeAudioTrackId: clearMediaInfo
          ? null
          : (activeAudioTrackId ?? this.activeAudioTrackId),
      colorPrimaries: clearMediaInfo
          ? null
          : (colorPrimaries ?? this.colorPrimaries),
      transferFunction: clearMediaInfo
          ? null
          : (transferFunction ?? this.transferFunction),
      sigPeak: clearMediaInfo ? null : (sigPeak ?? this.sigPeak),
      secondaryTrackId: clearSecondaryTrackId
          ? null
          : (secondaryTrackId ?? this.secondaryTrackId),
      secondarySubtitle: clearSecondarySubtitle
          ? null
          : (secondarySubtitle ?? this.secondarySubtitle),
      secondaryEntries: clearSecondarySubtitle
          ? null
          : (secondaryEntries ?? this.secondaryEntries),
      secondarySubtitleIndex: clearSecondarySubtitle
          ? 0
          : (secondarySubtitleIndex ?? this.secondarySubtitleIndex),
      currentSubtitleLines: currentSubtitleLines ?? this.currentSubtitleLines,
    );
  }

  /// 推断 HDR 类型（供 UI 展示）。
  ///
  /// 判断依据（按优先级）：
  ///  1. **杜比视界**：视频编码 codec 以 `dv` 开头（dvhe / dvh1 / dav1），
  ///     这是 mpv 能给的、最可靠的杜比信号；文件名兜底（见 [dolbyVision]）
  ///  2. 传递函数 pq + 色域 bt.2020 → HDR10（也可能是杜比回退的 HDR10 基础层）
  ///  3. 传递函数 hlg → HLG（广播 HDR）
  ///  4. 否则 → null（SDR 或未知）
  String? get hdrType {
    if (dolbyVision) return '杜比视界';
    final tf = (transferFunction ?? '').toLowerCase();
    final cp = (colorPrimaries ?? '').toLowerCase();
    if (tf.contains('pq') || cp.contains('2020')) {
      if (sigPeak != null && sigPeak! > 1.0) return 'HDR10';
      // 有 pq 传递函数但没读出峰值，仍按 HDR10 处理（元数据可能缺失）
      if (tf.contains('pq')) return 'HDR10';
    }
    if (tf.contains('hlg')) return 'HLG';
    return null; // SDR 或未知
  }

  /// 是否为杜比视界。
  ///
  /// 两层判断：
  ///  1. **codec**：videoCodec 以 `dv` 开头（dvhe / dvh1 / dav1）——最可靠
  ///  2. **文件名**：含 "dolby" / "vision" / "dovi" / "杜比" / "dv" 等关键字
  ///     （对齐 NovaPlayer 的 `_detectInitialHdrFromName`，libmpv 拿不到
  ///     完整杜比元数据时的兜底）
  bool get dolbyVision {
    final codec = (videoCodec ?? '').toLowerCase();
    // dvhe / dvh1 是 HEVC 封装的杜比视界，dav1 是 AV1 封装的杜比视界
    if (codec.startsWith('dvhe') ||
        codec.startsWith('dvh1') ||
        codec.startsWith('dav1')) {
      return true;
    }
    final name = (currentVideo?.name ?? currentVideo?.path ?? '').toLowerCase();
    if (name.contains('dolby vision') ||
        name.contains('dolbyvision') ||
        name.contains('.dovi') ||
        name.contains('杜比') ||
        name.contains('dolby')) {
      return true;
    }
    return false;
  }
}

class PlayerNotifier extends StateNotifier<PlayerState> {
  final DatabaseService _db = DatabaseService.instance;
  late final VideoController _globalController;

  PlayerNotifier() : super(PlayerState(player: Player())) {
    // VideoController 由 Provider 全局创建，跨页面复用
    _globalController = VideoController(state.player);
    state = state.copyWith(videoController: _globalController);
    _setupListeners();
    applyDecodingMode();
  }

  /// 应用硬解/软解设置（mpv hwdec）+ 配套播放引擎参数。
  ///
  /// 这里不只是「开/关硬件解码」，而是把与解码相关的 mpv 参数一起对齐：
  ///  - `hwdec`：硬解后端（auto-safe 会自动在硬解失败时退回软解）
  ///  - `vd-lavc-dr`：直接渲染（direct rendering），减少一次内存拷贝
  ///  - `vd-lavc-threads`：解码线程数，按设备核心自适应
  Future<void> applyDecodingMode() async {
    final on = AppSettingsService.instance.hardwareDecoding;
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;

      // 硬解：auto-safe（优先硬解，失败自动回退软解，避免花屏/黑屏直接卡死）
      await platform.setProperty('hwdec', on ? 'auto-safe' : 'no');

      // 直接渲染（direct rendering）：硬解时让解码器直接写 GPU 显存，
      // 少一次 CPU 拷贝，4K 高码率下明显降低 CPU 占用与功耗。
      await platform.setProperty('vd-lavc-dr', on ? 'yes' : 'no');

      // 软解线程数：硬解时解码负载在 GPU，软解靠 CPU；核心越多线程越多。
      // 不要超过 8，否则线程切换开销反而拖慢。
      final cores = DeviceInfoService.instance.capabilities.cpuCores;
      final threads = on ? 2 : (cores >= 8 ? 8 : (cores >= 4 ? 4 : 2));
      await platform.setProperty('vd-lavc-threads', '$threads');
    } catch (e) {
      debugPrint('[Player] 应用解码参数失败: $e');
    }
  }

  /// 播放引擎关键参数健壮性兜底：容器/音视频轨道异常时自动跳过坏流，
  /// 同时配置 HDR 色调映射，让 HDR10/HLG 视频在 SDR 屏幕上正确显示。
  Future<void> applyRobustPlayback() async {
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;
      // 允许过期/不兼容的字幕编码自动替换字符，避免 ASS 特效子幕导致崩溃
      await platform.setProperty('sub-ass-override', 'yes');
      // 音视频不同步时，宁可丢帧也要保持音画同步，避免越播越偏移
      await platform.setProperty('framedrop', 'vo');

      // ── 字幕渲染模式 ──
      //
      // 两种模式互斥，由「设置 → 字幕样式 → ASS 原生渲染」控制：
      //
      //  A) 自绘浮层（默认，nativeAss=false）
      //     mpv 只推文本不画（sub-visibility=no），Flutter 读
      //     `stream.subtitle` 自己渲染。好处：样式统一可调、黑底可控；
      //     代价：ASS 的卡拉OK/旋转/矢量绘图等特效丢失，只留文本。
      //
      //  B) mpv/libass 原生渲染（nativeAss=true）
      //     sub-visibility=yes，由 mpv 用 libass 完整绘制，ASS 特效原样呈现。
      //     代价：样式由字幕文件决定，字幕外观设置对它无效；且必须保证
      //     自绘浮层同时**不画**，否则又变成双字幕。
      //
      // 注意第二内嵌字幕始终由 mpv 的 secondary-sid 渲染，
      // 由 setSecondaryEmbedded / setSecondaryExternal 单独控制
      // secondary-sub-visibility，与本开关无关，不会叠。
      final nativeAss = AppSettingsService.instance.subtitleNativeAss;
      await platform.setProperty('sub-visibility', nativeAss ? 'yes' : 'no');
      // 原生模式下让 libass 完全按字幕文件来（不强制覆盖样式），
      // 否则 ASS 的字体/位置会被 mpv 默认值改掉。
      await platform.setProperty(
          'sub-ass-override', nativeAss ? 'no' : 'yes');

      // ── HDR 色调映射（对 SDR 视频无副作用）──
      // mobius（最接近片源色彩意图） / bt.2390（业界标准 EETF）
      await platform.setProperty('tone-mapping', 'bt.2390');
      // 目标显示亮度：手机屏一般在 200~1200 nit，用 250 保守值避免过曝
      await platform.setProperty('target-peak', '250');
      // 让 mpv 自己算信号峰值（对缺失 sig-peak 元数据的 HDR 源很有用）
      await platform.setProperty('hdr-compute-peak', 'yes');
      // HDR10+ 动态元数据：打开（若片源带，mpv 会自动用）
      await platform.setProperty('hdr10plus', 'auto');
      // 杜比视界：mpv 的 vo 若能解 profile 5 单层则解，否则回退 HDR10 基础层
      await platform.setProperty('dolbyvision', 'yes');
    } catch (e) {
      debugPrint('[Player] 应用健壮性参数失败: $e');
    }
  }

  /// 当前 media_kit Player 实例（播放页用它创建 VideoController）
  Player get player => state.player;

  /// 重新应用字幕渲染模式（切换「ASS 原生渲染」开关后调用，立即生效）。
  ///
  /// 只动字幕相关的两个属性，不重跑整套 HDR 参数，避免闪一下画面。
  Future<void> reapplySubtitleMode() async {
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;
      final nativeAss = AppSettingsService.instance.subtitleNativeAss;
      await platform.setProperty('sub-visibility', nativeAss ? 'yes' : 'no');
      await platform.setProperty(
          'sub-ass-override', nativeAss ? 'no' : 'yes');
      debugPrint('[Player] 字幕渲染模式: ${nativeAss ? "mpv/libass 原生" : "Flutter 自绘"}');
    } catch (e) {
      debugPrint('[Player] 切换字幕渲染模式失败: $e');
    }
  }

  /// 绑定播放页创建的 VideoController（保留兼容）
  void attachVideoController(VideoController controller) {
    state = state.copyWith(videoController: controller);
  }

  /// 上次位置状态发布时间（限流用，避免高频重建整页）
  DateTime? _lastPosEmitAt;

  /// 后台播放前台服务是否已启动（避免重复调用）
  bool _bgServiceOn = false;

  /// 根据「后台播放」设置与播放状态启停前台服务
  void _syncBackgroundService(bool playing) {
    if (!Platform.isAndroid) return;
    final want = playing && AppSettingsService.instance.backgroundPlay;
    if (want == _bgServiceOn) return;
    _bgServiceOn = want;
    if (want) {
      NativeBridgeService.instance.startBackgroundService();
    } else {
      // 暂停时不停服务（可能马上继续播），只有真正停止/切集才停
      if (!playing && !state.isBuffering && state.currentVideo == null) {
        NativeBridgeService.instance.stopBackgroundService();
      }
    }
  }

  /// 停止播放时关掉前台服务（在 stop()/dispose 路径调用）
  void _shutdownBackgroundService() {
    if (!Platform.isAndroid || !_bgServiceOn) return;
    _bgServiceOn = false;
    NativeBridgeService.instance.stopBackgroundService();
  }

  void _setupListeners() {
    state.player.stream.position.listen((pos) {
      // 位置流每秒会推很多次，整页跟着重建会明显发热掉帧。
      // 这里限制状态更新频率（进度条 4Hz 足够顺滑），
      // 播放页只让进度条/时间文字这类叶子节点订阅 position。
      final now = DateTime.now();
      final last = _lastPosEmitAt;
      if (last != null &&
          now.difference(last).inMilliseconds < 220 &&
          (pos - state.position).abs() < const Duration(seconds: 2)) {
        return;
      }
      _lastPosEmitAt = now;
      state = state.copyWith(position: pos);
      _updateActiveSubtitle();
      // 每 5 秒落盘一次进度
      if (_lastSaveAt == null || now.difference(_lastSaveAt!).inSeconds >= 5) {
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
      // 「后台播放」开关原来是个空转设置：Dart 侧从未启动过前台服务。
      // 现在按设置真正启停，才能在息屏/内存回收下继续播。
      _syncBackgroundService(playing);
    });

    state.player.stream.buffering.listen((buffering) {
      state = state.copyWith(isBuffering: buffering);
    });

    // 画面分辨率（详情展示用）
    state.player.stream.width.listen((w) {
      if (w != null && w > 0) state = state.copyWith(videoWidth: w);
    });
    state.player.stream.height.listen((h) {
      if (h != null && h > 0) state = state.copyWith(videoHeight: h);
    });

    // 字幕/音轨等轨道信息（内嵌字幕识别 + 编码/帧率）
    state.player.stream.tracks.listen((tracks) {
      bool real(String id) => id != 'auto' && id != 'no';
      final subs = tracks.subtitle.where((t) => real(t.id)).toList();
      final vids = tracks.video.where((t) => real(t.id)).toList();
      final auds = tracks.audio.where((t) => real(t.id)).toList();
      state = state.copyWith(
        embeddedSubtitles: subs,
        audioTracks: auds,
        videoCodec: vids.isNotEmpty ? vids.first.codec : null,
        videoFps: vids.isNotEmpty ? vids.first.fps : null,
      );
    });

    // 视频色彩参数（识别 HDR10 / 杜比视界 / SDR，用于详情展示与色调映射）
    state.player.stream.videoParams.listen((params) {
      state = state.copyWith(
        colorPrimaries: params.primaries,
        transferFunction: params.gamma,
        sigPeak: params.sigPeak,
      );
    });

    // 当前 mpv 正在显示的字幕文本（统一字幕渲染的唯一事实来源）。
    // 内嵌/外挂都走这个流，浮层只渲染这一份，避免双重绘制与位置错乱。
    state.player.stream.subtitle.listen((lines) {
      state = state.copyWith(
        currentSubtitleLines: lines.isEmpty
            ? const <String>[]
            : List<String>.from(lines),
      );
    });

    state.player.stream.completed.listen((_) {
      // 防止 mpv 在 EOF 处反复上报导致 playCount 被多次 +1、
      // 历史里插入多条相同记录
      if (state.isCompleted) return;
      state = state.copyWith(isCompleted: true);
      // 播完清零进度并记入历史，下次从头播放。
      // 网络源（云盘/NAS/直链）不写库：它们的 id 是 URL，写进去会污染影库。
      final v = state.currentVideo;
      if (v != null && !LibraryPruneService.isRemotePath(v.path)) {
        _db.updatePlayPosition(
          v.id,
          0,
          durationMs: state.duration.inMilliseconds,
        );
      }
      // 自动播放下一个（受设置控制）
      if (AppSettingsService.instance.autoPlayNext) {
        _playNext();
      }
    });
  }

  DateTime? _lastSaveAt;
  Duration? _pendingResume;

  /// 第几次 loadVideo（自动挂字幕用）
  ///
  /// loadVideo 里有好几个 await（开播放器、列字幕目录、读记忆），期间用户
  /// 可能已经切到下一集了。异步结果回来时拿它对一下：不是最新那次就丢掉，
  /// 否则上一部的字幕会挂到这一部上。
  int _loadToken = 0;

  /// 把当前进度写库（真实视频 id）
  Future<void> _persistProgress() async {
    final video = state.currentVideo;
    if (video == null) return;
    // 云盘 / NAS / 投屏这类网络源不写进度：
    //  1) 它们的 id 就是 URL（或临时串），插进 videos 表会污染影库与观看历史；
    //  2) 云盘直链有时效（几小时就失效），存下来也永远续播不了。
    if (LibraryPruneService.isRemotePath(video.path)) return;
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
  Future<void> loadVideo(
    VideoModel video, {
    List<VideoModel>? queue,
    int? startIndex,
  }) async {
    final token = ++_loadToken;
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
      // 换片时清掉上一部的字幕状态（内嵌轨道会由 tracks 流重新推送）
      clearActiveSubtitle: true,
      clearTrackId: true,
      clearMediaInfo: true,
      clearSecondaryTrackId: true,
      clearSecondarySubtitle: true,
      subtitleEntries: null,
      embeddedSubtitles: const [],
      videoWidth: 0,
      videoHeight: 0,
      availableSubtitles: const [],
    );
    _lastSaveAt = DateTime.now();

    // 每次换片重新应用解码设置（mpv 在 open 后可能重置）
    await applyDecodingMode();
    await applyRobustPlayback();

    // 应用默认播放速度
    await state.player.setRate(AppSettingsService.instance.defaultSpeed);

    // 恢复上次播放位置（<1s 视为从头开始）
    final resumeMs = effective.lastPosition;
    debugPrint(
      '[Player] load "${effective.name}" id=${effective.id} '
      'resume=${resumeMs.toInt()}ms',
    );
    if (resumeMs > 1000) {
      _pendingResume = Duration(milliseconds: resumeMs.toInt());
      try {
        await state.player.seek(_pendingResume!);
      } catch (_) {}
    }

    // 加载外挂字幕（同目录下所有同名文件，面板里可选）
    final subtitles = await SubtitleService.findExternalSubtitles(video.path);
    // 切片了：这份列表属于上一部，别再往当前状态里塞
    if (token != _loadToken) return;
    state = state.copyWith(availableSubtitles: subtitles);

    // 自动挂载：优先恢复上次选择，其次按优先级挑同名字幕
    await _autoAttachSubtitle(video.path, token);
  }

  /// mpv 当前的内嵌字幕轨（直接读它属性，不等 tracks 事件）
  ///
  /// 为什么优先读 `player.state` 而不是我们自己的 `embeddedSubtitles`：
  /// 后者靠 tracks 事件流更新，事件还没到时会被误判成「没有内嵌字幕」。
  /// 读 mpv 的当前属性值则可以立刻拿到结果；事件流那份留作兜底。
  List<SubtitleTrack> _currentEmbeddedTracks() {
    final fromMpv = state.player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    if (fromMpv.isNotEmpty) return fromMpv;
    return state.embeddedSubtitles;
  }

  /// 轨道信息是否已经拿到
  ///
  /// mpv 的 tracks 是 `open` 之后异步推的。优先看 mpv 当前属性；再退回
  /// 事件流落到 state 的字段（有音轨 / 有内嵌字幕轨 / 拿到帧率都算探测完）。
  bool get _tracksProbed {
    final mpv = state.player.state.tracks;
    if (mpv.video.isNotEmpty ||
        mpv.audio.isNotEmpty ||
        mpv.subtitle.isNotEmpty) {
      return true;
    }
    return state.audioTracks.isNotEmpty ||
        state.embeddedSubtitles.isNotEmpty ||
        state.videoFps != null;
  }

  /// 等 mpv 把轨道信息推过来（最多 1.2 秒）
  ///
  /// 为什么必须等：不等的话，记忆里存的内嵌 trackId 会因为「还没看到轨道」被
  /// 误判成已不存在；有内嵌字幕的视频也会被误判成没有内嵌，结果本来该用片源
  /// 自带字幕的片子被自动挂上了外挂。
  Future<void> _waitForTracks() async {
    if (_tracksProbed) return;
    try {
      await state.player.stream.tracks.first.timeout(
        const Duration(milliseconds: 1200),
      );
    } catch (_) {
      // 超时 / 流异常：把「没拿到轨道信息」当成「没有内嵌字幕」，
      // 免得流程一直卡着（这种片子本来也挂不出内嵌字幕）
    }
  }

  /// 打开视频后决定字幕：恢复记忆 / 尊重内嵌 / 自动挂同名外挂
  ///
  /// 三个「别动手」条件：
  ///  - token 变了：loadVideo 已经切到别的片子，这次的结论作废；
  ///  - 已经有字幕（外挂或内嵌）：上面几个 await 之间用户自己选了，
  ///    不能把他的选择盖掉。
  Future<void> _autoAttachSubtitle(String videoPath, int token) async {
    if (token != _loadToken) return;
    if (state.activeSubtitle != null || state.activeTrackId != null) return;

    // 网络源（云盘 / NAS / 直链）没有本地目录可扫，跳过外挂字幕匹配。
    // 内嵌字幕仍会通过 tracks 流正常出现，不受影响。
    if (LibraryPruneService.isRemotePath(videoPath)) return;

    // 先等轨道：记忆里可能存的是内嵌轨 id，判断"有没有内嵌字幕"也靠它
    await _waitForTracks();
    if (token != _loadToken) return;
    if (state.activeSubtitle != null || state.activeTrackId != null) return;

    final trackIds = [for (final t in _currentEmbeddedTracks()) t.id];
    final pick = await SubtitleAutoService.instance.resolve(
      videoPath,
      embeddedTrackIds: trackIds,
    );
    if (token != _loadToken) return;
    if (state.activeSubtitle != null || state.activeTrackId != null) return;

    switch (pick.kind) {
      case SubtitlePickKind.rememberedEmbedded:
        await _restoreEmbeddedTrack(pick.trackId);
      case SubtitlePickKind.embeddedPreferred:
        // 片源自带内嵌字幕：不自动挂外挂（外挂仍在字幕列表里，想用可以手动选）
        return;
      case SubtitlePickKind.rememberedOff:
      case SubtitlePickKind.none:
        return;
      case SubtitlePickKind.rememberedFile:
      case SubtitlePickKind.auto:
        final path = pick.path;
        if (path == null) return;
        final candidate = pick.candidate;
        await _applyExternalSubtitle(
          path,
          language: candidate?.language,
          title: candidate?.title,
        );
    }
  }

  /// 按记忆选中内嵌字幕轨（不写记忆：这是恢复，不是用户的新选择）
  Future<void> _restoreEmbeddedTrack(String? trackId) async {
    if (trackId == null) return;
    SubtitleTrack? track;
    for (final t in _currentEmbeddedTracks()) {
      if (t.id == trackId) {
        track = t;
        break;
      }
    }
    // 期间轨道变了（重新探测/换片）：不猜，宁可什么都不挂
    if (track == null) return;
    await _applyEmbeddedSubtitle(track);
  }

  /// 停止播放并清除当前视频（关闭小窗/后台播放）
  Future<void> stop() async {
    // 先落盘进度，再停止
    await _persistProgress();
    try {
      await state.player.stop();
    } catch (_) {}
    // 停止播放后不再需要前台服务（否则通知会一直挂着耗电）
    _shutdownBackgroundService();
    state = state.copyWith(
      clearCurrentVideo: true,
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
      await ScreenBrightness().setApplicationScreenBrightness(b);
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
      await loadVideo(
        nextVideo,
        queue: state.queue,
        startIndex: state.currentIndex + 1,
      );
      await state.player.play();
    }
  }

  /// 公开的播放下一个
  Future<void> playNext() => _playNext();

  /// 播放上一个
  Future<void> playPrevious() async {
    if (state.currentIndex > 0) {
      final prevVideo = state.queue[state.currentIndex - 1];
      await loadVideo(
        prevVideo,
        queue: state.queue,
        startIndex: state.currentIndex - 1,
      );
      if (state.isPlaying) await state.player.play();
    }
  }

  // ═══════════════ 字幕 ═══════════════

  /// 关闭 mpv 的「默认字幕渲染」但保留 sub-text 流。
  ///
  /// 统一字幕渲染策略：主字幕由自绘浮层画（用 `currentSubtitleLines`），
  /// mpv 只负责解析出「当前该显示的字幕文本」，不再自己画 —— 否则会出现
  /// 「mpv 画一份 + 浮层又画一份」的双重字幕（导入外挂字幕位置不对的根因）。
  ///
  /// sub-visibility=no 只关渲染，`stream.subtitle`（对应 mpv sub-text）依旧
  /// 正常推送当前文本，浮层照常拿到内容。
  Future<void> _disableMpvSubtitleRendering() async {
    final platform = state.player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('sub-visibility', 'no');
    } catch (e) {
      debugPrint('[Subtitle] 关闭 mpv 字幕渲染失败: $e');
    }
  }

  /// 选择内嵌字幕轨道（容器内的字幕流，用户手动选）
  Future<void> selectEmbeddedSubtitle(SubtitleTrack track) async {
    await _applyEmbeddedSubtitle(track);
    // 内嵌轨也要记：不记的话下次打开会被"自动挑外挂"或片源默认轨道盖掉
    await _rememberEmbeddedChoice(track);
  }

  /// 切换音轨。
  ///
  /// 与字幕切换对齐：`setAudioTrack` 之后记录当前选中 id，供 UI 高亮。
  Future<void> selectAudioTrack(AudioTrack track) async {
    try {
      await state.player.setAudioTrack(track);
    } catch (e) {
      debugPrint('[Audio] 切换音轨失败: $e');
    }
    state = state.copyWith(activeAudioTrackId: track.id);
  }

  /// 选中内嵌字幕轨（不写记忆：自动恢复和用户手动选择共用）
  Future<void> _applyEmbeddedSubtitle(SubtitleTrack track) async {
    try {
      await state.player.setSubtitleTrack(track);
      await _disableMpvSubtitleRendering();
    } catch (e) {
      debugPrint('[Subtitle] 选择内嵌轨道失败: $e');
    }
    state = state.copyWith(
      activeTrackId: track.id,
      clearActiveSubtitle: true,
      subtitleEntries: null,
    );
  }

  /// 关闭字幕
  Future<void> disableSubtitles() async {
    try {
      await state.player.setSubtitleTrack(SubtitleTrack.no());
    } catch (_) {}
    state = state.copyWith(
      clearTrackId: true,
      clearActiveSubtitle: true,
      subtitleEntries: null,
    );
    // 关掉也是一种选择：记住它，否则下次打开又被同名自动加载挂上
    await _rememberSubtitleChoice(null);
  }

  /// 加载外挂字幕文件并立即生效（用户手动选）
  Future<void> loadExternalSubtitle(
    String path, {
    String? title,
    String? language,
  }) async {
    await _applyExternalSubtitle(path, title: title, language: language);
    // 只有手动选择才写记忆：自动挂载如果也写，等于把自动挑的结果
    // 伪装成用户意愿，下次"恢复"的其实是自己猜的东西
    await _rememberSubtitleChoice(path);
  }

  /// 把外挂字幕挂到播放器并解析成本地条目（不写记忆）
  Future<void> _applyExternalSubtitle(
    String path, {
    String? title,
    String? language,
  }) async {
    try {
      await state.player.setSubtitleTrack(
        SubtitleTrack.uri(path, title: title, language: language),
      );
      await _disableMpvSubtitleRendering();
    } catch (e) {
      debugPrint('[Subtitle] 载入外挂字幕失败: $e');
    }
    final model = SubtitleModel(
      path: path,
      language: language ?? '外挂字幕',
      title: title ?? path.split('/').last,
    );
    final entries = await _parseSubtitle(model);
    state = state.copyWith(
      activeSubtitle: model,
      clearTrackId: true,
      subtitleEntries: entries,
      activeSubtitleIndex: 0,
    );
    // 记录到可选项，便于再次切换
    if (!state.availableSubtitles.any((s) => s.path == path)) {
      state = state.copyWith(
        availableSubtitles: [...state.availableSubtitles, model],
      );
    }
  }

  /// 记住「这个视频上次选了什么字幕」；[path] 为 null 表示关掉了字幕
  Future<void> _rememberSubtitleChoice(String? path) async {
    final video = state.currentVideo;
    if (video == null) return;
    await SubtitleAutoService.instance.remember(video.path, path);
  }

  /// 记住「这个视频上次选的是哪条内嵌轨」
  Future<void> _rememberEmbeddedChoice(SubtitleTrack track) async {
    final video = state.currentVideo;
    if (video == null) return;
    await SubtitleAutoService.instance.rememberEmbedded(
      video.path,
      track.id,
      language: track.language,
    );
  }

  /// 兼容旧调用
  Future<void> selectSubtitle(SubtitleModel subtitle) =>
      loadExternalSubtitle(subtitle.path, language: subtitle.language);

  Future<void> loadSubtitle(SubtitleModel subtitle) =>
      loadExternalSubtitle(subtitle.path, language: subtitle.language);

  // ═══════════════ 第二字幕（中英同时显示） ═══════════════

  /// 把某个内嵌轨设为第二字幕（交给 mpv 的 secondary-sid 渲染）
  Future<void> setSecondaryEmbedded(SubtitleTrack track) async {
    final platform = state.player.platform;
    try {
      if (platform is NativePlayer) {
        await platform.setProperty('secondary-sid', track.id);
        await platform.setProperty('secondary-sub-visibility', 'yes');
      }
    } catch (e) {
      debugPrint('[Subtitle] 设置内嵌第二字幕失败: $e');
    }
    state = state.copyWith(
      secondaryTrackId: track.id,
      clearSecondarySubtitle: true,
    );
    await _applySubtitleLayout();
  }

  /// 把外挂字幕文件设为第二字幕（自绘浮层渲染，可与主字幕并存）
  Future<void> setSecondaryExternal(SubtitleModel subtitle) async {
    final platform = state.player.platform;
    try {
      if (platform is NativePlayer) {
        await platform.setProperty('secondary-sub-visibility', 'no');
      }
    } catch (_) {}
    final entries = await _parseSubtitle(subtitle);
    state = state.copyWith(
      secondarySubtitle: subtitle,
      secondaryEntries: entries,
      secondarySubtitleIndex: 0,
      clearSecondaryTrackId: true,
    );
    await _applySubtitleLayout();
  }

  /// 关闭第二字幕
  Future<void> clearSecondarySubtitle() async {
    final platform = state.player.platform;
    try {
      if (platform is NativePlayer) {
        await platform.setProperty('secondary-sub-visibility', 'no');
        await platform.setProperty('secondary-sid', 'no');
      }
    } catch (_) {}
    state = state.copyWith(
      clearSecondaryTrackId: true,
      clearSecondarySubtitle: true,
    );
    await _applySubtitleLayout();
  }

  /// 主字幕位置：外挂第二字幕用自绘浮层时，把 mpv 主字幕抬高避免重叠
  Future<void> _applySubtitleLayout() async {
    final platform = state.player.platform;
    if (platform is! NativePlayer) return;
    final hasOverlay = state.secondaryEntries?.isNotEmpty == true;
    try {
      await platform.setProperty('sub-pos', hasOverlay ? '88' : '100');
    } catch (_) {}
  }

  Future<List<SubtitleEntry>?> _parseSubtitle(SubtitleModel subtitle) async {
    final lower = subtitle.path.toLowerCase();
    try {
      if (lower.endsWith('.srt')) {
        return await SubtitleService.parseSrt(subtitle.path);
      } else if (lower.endsWith('.vtt')) {
        return await SubtitleService.parseVtt(subtitle.path);
      } else if (lower.endsWith('.ass') || lower.endsWith('.ssa')) {
        return await SubtitleService.parseAss(subtitle.path);
      }
    } catch (e) {
      debugPrint('[Subtitle] 解析失败: $e');
    }
    return null;
  }

  void _updateActiveSubtitle() {
    final pos = state.position;
    final p = _entryIndexAt(state.subtitleEntries, pos);
    if (p != null && p != state.activeSubtitleIndex) {
      state = state.copyWith(activeSubtitleIndex: p);
    }
    final s = _entryIndexAt(state.secondaryEntries, pos);
    if (s != null && s != state.secondarySubtitleIndex) {
      state = state.copyWith(secondarySubtitleIndex: s);
    }
  }

  /// 命中的字幕条目下标；不在任何区间时返回 null（保持上一条显示）
  ///
  /// 字幕条目按时间升序，先用上次命中的位置做邻近判断（播放是顺序推进的，
  /// 绝大多数情况一步命中），落空再用二分查找。
  /// 原来是每次位置回调线性扫全表（一部电影 1500+ 条，每秒扫几十次）。
  int? _entryIndexAt(List<SubtitleEntry>? entries, Duration pos) {
    if (entries == null || entries.isEmpty) return null;

    final hint = _entryHint[entries] ?? 0;
    // 优先看上次命中与下一条
    for (final i in [hint, hint + 1, hint - 1]) {
      if (i < 0 || i >= entries.length) continue;
      if (pos >= entries[i].start && pos <= entries[i].end) {
        _entryHint[entries] = i;
        return i;
      }
    }

    // 二分：找最后一个 start <= pos 的条目
    var lo = 0;
    var hi = entries.length - 1;
    var candidate = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (entries[mid].start <= pos) {
        candidate = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (candidate >= 0 &&
        pos >= entries[candidate].start &&
        pos <= entries[candidate].end) {
      _entryHint[entries] = candidate;
      return candidate;
    }
    return null;
  }

  /// 每个字幕列表的上次命中下标（IdentityHashMap 语义，按对象区分）
  final Map<List<SubtitleEntry>, int> _entryHint = Map.identity();

  @override
  void dispose() {
    // 释放播放器时也要收掉前台服务，否则退出后通知残留
    _shutdownBackgroundService();
    state.player.dispose();
    super.dispose();
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>(
  (ref) => PlayerNotifier(),
);
