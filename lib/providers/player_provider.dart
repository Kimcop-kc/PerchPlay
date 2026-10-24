import 'dart:async' show Timer, unawaited;
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
import '../services/cloud/cloud_drive_service.dart';
import '../services/device_info_service.dart';
import '../services/native_bridge_service.dart';
import '../services/library_prune_service.dart';
import '../services/playback_busy.dart';

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
  ///
  /// 注意：这里只存 `stream.subtitle[0]`（mpv `sub-text`，主字幕）。
  /// 第二字幕文本存 [secondarySubtitleLines]（mpv `secondary-sub-text`）。
  final List<String> currentSubtitleLines;

  /// 当前 mpv 正在显示的第二字幕文本（来自 `stream.subtitle[1]`，
  /// 对应 mpv 的 `secondary-sub-text` 属性）。
  ///
  /// 内嵌第二字幕（secondary-sid）与主字幕一样都能通过 mpv 属性拿到文本，
  /// 因此可以统一走 Flutter 渲染，不必依赖 mpv 原生绘制第二字幕。
  final List<String> secondarySubtitleLines;

  /// 当前播放源被判定为「服务器限速」。
  ///
  /// 用于播放页在长时间缓冲时给用户一条明确提示，
  /// 而不是让用户对着转圈干等、以为是 App 卡了。
  final bool isSlowSource;

  /// 慢源提示文案（为空表示无提示）。
  final String slowSourceHint;

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
    this.isSlowSource = false,
    this.slowSourceHint = '',
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
    this.secondarySubtitleLines = const [],
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
    List<String>? secondarySubtitleLines,
    bool? isSlowSource,
    String? slowSourceHint,
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
      currentVideo:
          clearCurrentVideo ? null : (currentVideo ?? this.currentVideo),
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      availableSubtitles: availableSubtitles ?? this.availableSubtitles,
      activeSubtitle:
          clearActiveSubtitle ? null : (activeSubtitle ?? this.activeSubtitle),
      subtitleEntries: subtitleEntries ?? this.subtitleEntries,
      activeSubtitleIndex: activeSubtitleIndex ?? this.activeSubtitleIndex,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      embeddedSubtitles: embeddedSubtitles ?? this.embeddedSubtitles,
      activeTrackId:
          clearTrackId ? null : (activeTrackId ?? this.activeTrackId),
      videoCodec: clearMediaInfo ? null : (videoCodec ?? this.videoCodec),
      videoFps: clearMediaInfo ? null : (videoFps ?? this.videoFps),
      audioTracks:
          clearMediaInfo ? const [] : (audioTracks ?? this.audioTracks),
      activeAudioTrackId: clearMediaInfo
          ? null
          : (activeAudioTrackId ?? this.activeAudioTrackId),
      colorPrimaries:
          clearMediaInfo ? null : (colorPrimaries ?? this.colorPrimaries),
      transferFunction:
          clearMediaInfo ? null : (transferFunction ?? this.transferFunction),
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
      secondarySubtitleLines:
          secondarySubtitleLines ?? this.secondarySubtitleLines,
      isSlowSource: isSlowSource ?? this.isSlowSource,
      slowSourceHint: slowSourceHint ?? this.slowSourceHint,
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
    // iOS 锁屏 / 控制中心的远程控制（播放、暂停、快进、下一集等）
    _registerRemoteControls();
  }

  /// 注册锁屏 / 控制中心的远程控制回调（iOS）。
  ///
  /// 原生侧（AppDelegate 的 MPRemoteCommandCenter）把按键事件通过
  /// `remoteCommand` 方法发过来；这里映射到播放器的实际操作。
  /// 之前原生只往 NotificationCenter 发通知、Dart 侧无人监听，
  /// 导致锁屏上点播放/暂停完全没有反应。
  void _registerRemoteControls() {
    NativeBridgeService.instance.registerRemoteCommandHandler((cmd, arg) {
      debugPrint('[Player] 远程控制: $cmd ${arg ?? ""}');
      switch (cmd) {
        case 'togglePlayPause':
          togglePlayPause();
        case 'play':
          state.player.play();
        case 'pause':
          state.player.pause();
        case 'skipForward':
          _seekRelative(const Duration(seconds: 10));
        case 'skipBackward':
          _seekRelative(const Duration(seconds: -10));
        case 'next':
          _playNext();
        case 'previous':
          playPrevious();
        case 'seek':
          // arg 是秒（double）
          final secs = (arg as num?)?.toDouble();
          if (secs != null) {
            state.player.seek(Duration(milliseconds: (secs * 1000).round()));
          }
      }
    });
  }

  /// 相对当前位置跳转（远程控制的快进/快退用）。
  Future<void> _seekRelative(Duration delta) async {
    try {
      final dur = state.duration;
      var target = state.position + delta;
      if (target < Duration.zero) target = Duration.zero;
      if (dur > Duration.zero && target > dur) target = dur;
      await state.player.seek(target);
    } catch (e) {
      debugPrint('[Player] 相对跳转失败: $e');
    }
  }

  /// 把当前播放状态同步给 iOS 锁屏 / 控制中心。
  ///
  /// 只在 iOS 生效（内部已判断平台）。位置变化不需要每帧推，
  /// 由调用方在「换片 / 播放暂停切换 / 定期」时机调用即可。
  void _syncNowPlaying() {
    final v = state.currentVideo;
    if (v == null) return;
    NativeBridgeService.instance.updateNowPlaying(
      title: v.name,
      artist: 'PerchPlay',
      duration: state.duration,
      position: state.position,
      isPlaying: state.isPlaying,
    );
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
      //
      // 硬解时给 4 线程：虽然主体解码在 GPU，但 ffmpeg 仍需线程做
      // 码流解析/送帧，2 线程在高码率下容易成为瓶颈导致掉帧。
      final cores = DeviceInfoService.instance.capabilities.cpuCores;
      final threads = on ? 4 : (cores >= 8 ? 8 : (cores >= 4 ? 4 : 2));
      await platform.setProperty('vd-lavc-threads', '$threads');

      // 硬解失败时的兜底行为：允许 mpv 在硬解出错时自动切回软解，
      // 而不是直接黑屏/卡住（auto-safe 已含此语义，这里显式声明）。
      await platform.setProperty('hwdec-extra-frames', on ? '6' : '0');
    } catch (e) {
      debugPrint('[Player] 应用解码参数失败: $e');
    }
  }

  /// 播放引擎关键参数健壮性兜底：容器/音视频轨道异常时自动跳过坏流，
  /// 同时配置 HDR 色调映射，让 HDR10/HLG 视频在 SDR 屏幕上正确显示。
  /// 按视频来源设置「每文件」mpv 选项（缓存 / demuxer / 网络超时）。
  ///
  /// 为什么必须单独抽出来：`cache`、`cache-on-disk`、`demuxer-max-bytes`、
  /// `demuxer-max-back-bytes`、`network-timeout` 都是 mpv 的**每文件选项**，
  /// 在 `open()` 时读取。原来它们只在 open 之后设置，等于永远慢一部——
  /// 本地片切网盘/NAS 时仍用着 `cache=no` + 5s 超时（卡顿、频繁重连），
  /// 网络片切本地时反而背着磁盘缓存。
  ///
  /// 这里在 open 前同步设置一次（不 await，mpv 属性设置是排队生效的），
  /// open 之后 applyRobustPlayback 会再设一遍兜底。
  void _applyOptionsForSource(String path) {
    final platform = state.player.platform;
    if (platform is! NativePlayer) return;
    final remote = LibraryPruneService.isRemotePath(path);
    // 逐条 fire-and-forget：open 前不能 await（会把打开推迟到设置完成之后）
    platform.setProperty('cache', remote ? 'yes' : 'no').catchError((_) {});
    // ⚠ 网络源**不要**开磁盘缓存。
    // `cache-on-disk=yes` 会把网络流先写进手机存储再读出来，等于多一次
    // 闪存写 + 读；手机 UFS 的随机写带宽远低于网盘下载速度，高码率片源
    // 会被这个落盘环节拖住，观感就是「缓冲很久、开播要等十几秒」。
    // 内存缓存（cache=yes + demuxer-max-bytes）已经够用。
    platform.setProperty('cache-on-disk', 'no').catchError((_) {});
    // 网络源：128MB 前向缓冲，容纳码率抖动
    // 本地文件：给到 64MB。高码率 4K 片源（50~100Mbps）单秒数据量就有
    // 6~12MB，32MB 只够 3~5 秒，seek 或起播时容易反复触发重新读取；
    // 64MB 在手机内存上仍安全，却能让大文件起播与拖动明显更跟手。
    platform
        .setProperty('demuxer-max-bytes', remote ? '134217728' : '67108864')
        .catchError((_) {});
    platform
        .setProperty(
            'demuxer-max-back-bytes', remote ? '134217728' : '33554432')
        .catchError((_) {});
    platform
        .setProperty('network-timeout', remote ? '15' : '5')
        .catchError((_) {});
    if (remote) {
      // 预读时长：默认 10s 意味着「先攒够 10 秒数据才开播」，
      // 网盘首包本来就慢，叠加起来就是长时间黑屏/转圈。
      // 3s 足够吸收抖动，又能明显加快起播。
      platform.setProperty('cache-secs', '3').catchError((_) {});
      platform.setProperty('demuxer-readahead-secs', '3').catchError((_) {});
      // 允许更大的单次读取块，减少 HTTP 往返次数
      platform.setProperty('demuxer-max-packets', '512').catchError((_) {});
      // YouTube-DL 之类的探测会额外发请求拖慢起播，网盘直链不需要
      platform.setProperty('ytdl', 'no').catchError((_) {});

      // ── 分段下载策略 ──
      //
      // mpv/ffmpeg 默认会并发开多个 Range 连接「抢带宽」。对网盘直链这反而
      // 有害：夸克/115 对第三方直链有频次与并发限速，多发几个连接会被判定
      // 为异常流量，整体吞吐反而更低，表现为「一直缓冲、进度条几乎不动」。
      //
      // 改成单连接顺序读取：吞吐稳定，不会触发风控。
      platform.setProperty('http-max-request-retries', '3').catchError((_) {});
      // 关闭「预读时另起连接探测文件大小」的行为，省一次往返
      platform.setProperty('http-seekable', 'yes').catchError((_) {});
      // 单次读 1MB，减少请求次数又不至于让首包等待过久
      platform.setProperty('demuxer-lavf-buffersize', '1048576')
          .catchError((_) {});
      // 关闭 demuxer 层面的激进探测，直链不需要
      platform.setProperty('demuxer-lavf-probe-info', 'nostreams')
          .catchError((_) {});
    } else {
      // ── 本地文件起播优化 ──
      //
      // 本地文件不需要网络缓冲，但**需要快速探测**。默认 ffmpeg 会读较多
      // 数据来判断流信息，大文件/高码率时会明显延迟首帧。
      // 降低 probe 数据量与分析时长，只解析流结构，能显著加快起播。
      platform.setProperty('demuxer-lavf-probe-info', 'auto')
          .catchError((_) {});
      platform.setProperty('demuxer-lavf-analyzeduration', '1')
          .catchError((_) {});
      // 本地读不需要 lavf 的大缓冲区（会多一次内存拷贝）
      platform.setProperty('demuxer-lavf-buffersize', '262144')
          .catchError((_) {});
      // 预读 2 秒即可：本地读几乎没有延迟，攒太多反而推迟首帧
      platform.setProperty('cache-secs', '2').catchError((_) {});
      platform.setProperty('demuxer-readahead-secs', '2').catchError((_) {});
      // 关闭 ytdl 探测（本地文件绝不需要）
      platform.setProperty('ytdl', 'no').catchError((_) {});
    }
  }

  Future<void> applyRobustPlayback() async {
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;
      // 允许过期/不兼容的字幕编码自动替换字符，避免 ASS 特效子幕导致崩溃
      await platform.setProperty('sub-ass-override', 'yes');

      // ── 音视频同步与掉帧策略（播放流畅度的核心）──
      //
      // 默认 `video-sync=audio` 以音频为主时钟，视频跟不上就丢帧；
      // 但 mpv 默认 `framedrop=no`（不丢帧）——解码/渲染跟不上时会越积越多，
      // 表现为「越播越卡、音画逐渐错位」。这里显式设置：
      //   * framedrop=decoder+vo：解码或渲染任一侧跟不上都允许丢帧，
      //     保证音画同步优先、画面持续流畅（比只 `vo` 更平滑）
      //   * video-sync=audio：以音频为基准，避免视频拖慢整体节奏
      //   * interpolation=no：关闭运动插值（高开销，手机上只会拖慢）
      await platform.setProperty('framedrop', 'decoder+vo');
      await platform.setProperty('video-sync', 'audio');
      await platform.setProperty('interpolation', 'no');

      // 渲染侧「低延迟」取舍：允许 mpv 为流畅度牺牲少量精确性。
      // 对本地高码率/4K 片源，能明显减少因渲染管线排队导致的卡顿。
      await platform.setProperty('video-latency-hacks', 'yes');

      // ── 内核缓冲优化（本地文件）──
      //
      // media_kit 默认 `cache=yes` + `cache-on-disk=yes`：对网络流有用，
      // 但本地文件（/storage/...）本身就是随机可读的，磁盘缓存反而多一层
      // 磁盘 IO，高码率/4K 时可能因为缓存写盘抖动导致「突然卡一下」。
      //
      // 这里按视频路径判断：本地文件关掉磁盘缓存，网络源（网盘/NAS/直链）
      // 保留缓存与更大的 demuxer 缓冲，减少网络抖动带来的卡顿。
      final path = state.currentVideo?.path ?? '';
      final remote = LibraryPruneService.isRemotePath(path);
      await platform.setProperty('cache', remote ? 'yes' : 'no');
      // 与 _applyOptionsForSource 保持一致：网络源不落盘
      await platform.setProperty('cache-on-disk', 'no');
      // 网络源 128MB / 本地 64MB（高码率大文件需要更大前向缓冲，见
      // _applyOptionsForSource 的说明）
      await platform.setProperty(
          'demuxer-max-bytes', remote ? '134217728' : '67108864');
      await platform.setProperty(
          'demuxer-max-back-bytes', remote ? '134217728' : '33554432');
      // 网络超时：5 秒太短，网盘/NAS 偶尔慢响应会频繁超时重连，调到 15 秒
      await platform.setProperty('network-timeout', remote ? '15' : '5');
      if (remote) {
        // 起播预读：3s（默认 10s，叠加网盘首包延迟会让起播非常慢）
        await platform.setProperty('cache-secs', '3');
        await platform.setProperty('demuxer-readahead-secs', '3');
        await platform.setProperty('demuxer-max-packets', '512');
        await platform.setProperty('ytdl', 'no');
      } else {
        // 本地文件：降低 probe 开销、缩小预读时长，加快首帧
        await platform.setProperty('demuxer-lavf-probe-info', 'auto');
        await platform.setProperty('demuxer-lavf-analyzeduration', '1');
        await platform.setProperty('demuxer-lavf-buffersize', '262144');
        await platform.setProperty('cache-secs', '2');
        await platform.setProperty('demuxer-readahead-secs', '2');
        await platform.setProperty('ytdl', 'no');
      }

      // ── 字幕渲染：统一由 Flutter 自绘 ──
      //
      // mpv/libass 只负责**解析**字幕文本（sub-text / secondary-sub-text），
      // 不再绘制任何字幕。`sub-visibility=no` 关闭 libass 渲染，但文本流照常
      // 推送，Flutter 浮层据此渲染，保证所有字幕（含 ASS）样式统一、可控，
      // 也彻底消除「mpv 画一份 + Flutter 画一份」的双重绘制。
      await platform.setProperty('sub-visibility', 'no');
      await platform.setProperty('secondary-sub-visibility', 'no');

      // HDR 色调映射交给 applyHdrToneMapping（它在色彩参数流到达后按需调用）
      await applyHdrToneMapping();
    } catch (e) {
      debugPrint('[Player] 应用健壮性参数失败: $e');
    }
  }

  /// 按当前片源是否为 HDR 启用/关闭色调映射。
  ///
  /// 性能要点：色调映射（尤其 `hdr-compute-peak=yes` 的逐帧直方图计算）
  /// 对 **SDR 片源是纯浪费**，会稳定占用 CPU/GPU，高码率播放时直接表现为
  /// 掉帧。所以只有真实 HDR 片源才开这套，SDR 走最轻的 `tone-mapping=clip`。
  ///
  /// 调用时机很关键：`stream.videoParams` 是 open 之后的异步事件，
  /// `applyRobustPlayback` 里同步调用时元数据还没到（会被误判成 SDR），
  /// 所以这里被 videoParams 监听器再调一次，确保判断基于真实参数。
  Future<void> applyHdrToneMapping() async {
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;
      final isHdr = state.hdrType != null;
      if (isHdr) {
        // bt.2390（业界标准 EETF），最接近片源色彩意图
        await platform.setProperty('tone-mapping', 'bt.2390');
        // 目标显示亮度：手机屏一般在 200~1200 nit，用 250 保守值避免过曝
        await platform.setProperty('target-peak', '250');
        // 让 mpv 自己算信号峰值（对缺失 sig-peak 元数据的 HDR 源很有用）
        await platform.setProperty('hdr-compute-peak', 'yes');
        // HDR10+ 动态元数据：打开（若片源带，mpv 会自动用）
        await platform.setProperty('hdr10plus', 'auto');
        // 杜比视界：mpv 的 vo 若能解 profile 5 单层则解，否则回退 HDR10 基础层
        await platform.setProperty('dolbyvision', 'yes');
      } else {
        // SDR：关掉全部色调映射开销，让渲染管线走最轻路径
        await platform.setProperty('tone-mapping', 'clip');
        await platform.setProperty('hdr-compute-peak', 'no');
        await platform.setProperty('hdr10plus', 'no');
        await platform.setProperty('dolbyvision', 'no');
      }
    } catch (e) {
      debugPrint('[Player] 应用 HDR 色调映射失败: $e');
    }
  }

  /// 当前 media_kit Player 实例（播放页用它创建 VideoController）
  Player get player => state.player;

  /// 重新应用字幕渲染模式（保留兼容：字幕设置变更后确保 mpv 不绘制字幕）。
  ///
  /// 所有字幕统一由 Flutter 渲染，这里只确保 mpv 的 libass 绘制保持关闭，
  /// 让 sub-text / secondary-sub-text 文本流继续推送给 Flutter。
  Future<void> reapplySubtitleMode() async {
    try {
      final platform = state.player.platform;
      if (platform is! NativePlayer) return;
      await platform.setProperty('sub-visibility', 'no');
      await platform.setProperty('secondary-sub-visibility', 'no');
      debugPrint('[Player] 字幕渲染模式: Flutter 自绘');
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
  ///
  /// 注意：此处仅反映「主动要求服务保持运行」的意愿；
  /// 停止播放时用 [_forceShutdownBackgroundService] 无条件消亡，
  /// 避免暂停→关小窗的路径让 flag 被置为 false 导致通知永远不消失。
  bool _bgServiceOn = false;

  /// 缓冲看门狗定时器（见 [_startBufferWatchdog]）
  Timer? _bufferWatchdog;

  /// 看门狗代次：每次重新起计时递增。
  ///
  /// 用来丢弃「过期」的回调。典型场景：上一部片在缓冲、看门狗已起计时，
  /// 此时用户切到下一部 —— 旧定时器如果不作废，8 秒后会在**新视频**上
  /// 误弹「网盘限速」提示。
  int _bufferWatchdogId = 0;

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

  /// 无条件停止前台播放通知，不检查 [_bgServiceOn] flag。
  ///
  /// stop()/dispose() 走过暂停→关小窗路径时，flag 可能已经被
  /// _syncBackgroundService(false) 置为 false（:434-438 为了保护暂停不杀服务），
  /// 导致旧的 _shutdownBackgroundService() 因为 flag==false 直接 return。
  /// 这里幂等调用 stopBackgroundService() 确保通知清掉。
  void _forceShutdownBackgroundService() {
    if (!Platform.isAndroid) return;
    _bgServiceOn = false;
    NativeBridgeService.instance.stopBackgroundService();
  }

  /// 缓冲看门狗：缓冲超过阈值就判定「源太慢」，给用户可执行的提示。
  ///
  /// 为什么需要它：网盘（尤其夸克非会员）对第三方直链有服务端限速，
  /// 这种情况客户端怎么调参数都救不回来。让用户对着转圈干等是最糟的
  /// 体验——他不知道是自己的网、App 的 bug，还是网盘限速。
  ///
  /// 8 秒是个经验值：正常起播（含首包 + 预读 3s）通常 2~5 秒完成，
  /// 超过 8 秒还没出画基本都是源端吞吐不够。
  void _startBufferWatchdog() {
    _bufferWatchdog?.cancel();
    final id = ++_bufferWatchdogId;
    _bufferWatchdog = Timer(const Duration(seconds: 8), () {
      // 代次不匹配说明这期间已经换片/重新起计时了，丢弃这次回调
      if (id != _bufferWatchdogId) return;
      if (!state.isBuffering) return;
      final path = state.currentVideo?.path ?? '';
      final isCloud = path.contains('quark.cn') ||
          path.contains('115.com') ||
          path.contains('alidrive') ||
          path.contains('alipan') ||
          path.contains('baidu.com');
      final hint = isCloud
          ? '网盘服务器限速，可能因非会员／并发过大。\n'
              '可尝试：切换到 4G/Wi-Fi、换清晰度较低的片源，\n'
              '或把文件转存到本地后播放。'
          : '网络较慢或文件码率过高，正在努力加载…';
      state = state.copyWith(isSlowSource: true, slowSourceHint: hint);
      debugPrint('[Player] 缓冲超过 8s，判定慢源: $path');
    });
  }

  /// 停止播放时关掉前台服务（在 stop()/dispose 路径调用）
  ///
  /// 已废弃：改用 [_forceShutdownBackgroundService] 无条件停止。
  /// 保留此注释防止有人重新引入 flag 检查版本。

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
      // iOS：时长到达后补一次锁屏信息（锁屏进度条需要总时长）
      _syncNowPlaying();
      // 时长就绪后补一次 seek（首次 seek 可能早于媒体加载完成而被忽略）
      final pending = _pendingResume;
      final loadId = _pendingResumeLoadId;
      if (pending != null && dur > Duration.zero) {
        _pendingResume = null;
        _pendingResumeLoadId = 0;
        // 用 player 当前时长做钳位（不用回调参数 dur）：
        // 快速切集时回调里的 dur 可能来自旧媒体，用它钳位会出错。
        final realDur = state.player.state.duration;
        final clamped = pending < Duration.zero
            ? Duration.zero
            : (pending > realDur ? realDur : pending);
        final token = ++_seekToken;
        state.player.seek(clamped).then((_) {
          if (token != _seekToken || loadId != _loadToken) return;
          state = state.copyWith(position: clamped);
        }).catchError((_) {});
      }
    });

    state.player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
      // 更新全局「播放中」标志：缩略图解码、TMDB 刮削等后台任务
      // 会轮询它，在播放时暂停，把 CPU/网络让给播放器。
      PlaybackBusy.playing = playing;
      // 「后台播放」开关原来是个空转设置：Dart 侧从未启动过前台服务。
      // 现在按设置真正启停，才能在息屏/内存回收下继续播。
      _syncBackgroundService(playing);
      // iOS：同步锁屏/控制中心的播放状态（播放中 ↔ 暂停）
      _syncNowPlaying();
    });

    state.player.stream.buffering.listen((buffering) {
      state = state.copyWith(isBuffering: buffering);
      if (buffering) {
        _startBufferWatchdog();
      } else {
        _bufferWatchdog?.cancel();
        _bufferWatchdog = null;
        if (state.isSlowSource) {
          state = state.copyWith(isSlowSource: false, slowSourceHint: '');
        }
      }
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
      // 元数据到位后按需启用/关闭色调映射（见 applyHdrToneMapping 的说明：
      // open 后立刻调 applyRobustPlayback 时这些参数还没到，必须在这里补一次）
      applyHdrToneMapping();
    });

    // 当前 mpv 正在显示的字幕文本（统一字幕渲染的唯一事实来源）。
    //
    // `stream.subtitle` 返回**两个元素**：
    //   [0] = 主字幕文本（mpv `sub-text`）
    //   [1] = 第二字幕文本（mpv `secondary-sub-text`）
    // 内嵌第二字幕（secondary-sid）的文本也能从 [1] 拿到，
    // 因此主/次字幕都可以统一走 Flutter 渲染，不必依赖 mpv 原生绘制。
    state.player.stream.subtitle.listen((lines) {
      state = state.copyWith(
        currentSubtitleLines: _toLines(lines.isNotEmpty ? lines[0] : ''),
        secondarySubtitleLines: _toLines(lines.length > 1 ? lines[1] : ''),
      );
    });

    state.player.stream.completed.listen((_) {
      // 防止 mpv 在 EOF 处反复上报导致 playCount 被多次 +1、
      // 历史里插入多条相同记录
      if (state.isCompleted) return;
      state = state.copyWith(isCompleted: true);
      // 使用安全的异步处理，避免 stream listener 中的 async 异常
      unawaited(_handleCompleted().catchError((Object e) {
        debugPrint('[Player] completed 处理失败: $e');
      }));
    });
  }

  /// 处理播放完成事件（安全的异步包装）
  ///
  /// 1. 清零进度并记入历史
  /// 2. 自动播放下一集
  Future<void> _handleCompleted() async {
    // 播完清零进度并记入历史，下次从头播放。
    // 网络源（云盘/NAS/直链）不写库：它们的 id 是 URL，写进去会污染影库。
    final v = state.currentVideo;
    if (v != null && !LibraryPruneService.isRemotePath(v.path)) {
      // 必须 await：确保清零落库后再换片，否则下一集加载后会覆盖清零操作
      try {
        await _db.updatePlayPosition(
          v.id,
          0,
          durationMs: state.duration.inMilliseconds,
        );
      } catch (e) {
        debugPrint('[Player] 播完清零进度失败: $e');
      }
    }
    
    // 自动播放下一个（受设置控制）
    // 确保暖清零完成后再换片
    if (AppSettingsService.instance.autoPlayNext) {
      await _playNext();
    }
  }

  /// 上次进度落盘时间（5s 节流）
  DateTime? _lastSaveAt;

  /// 待恢复的播放位置，配合 [_pendingResumeLoadId] 防止旧媒体的 duration
  /// 事件抢在新媒体之前消费掉 resume。
  Duration? _pendingResume;
  int _pendingResumeLoadId = 0;

  /// seek 竞态令牌：每次新 seek 递增，旧 seek 回来发现编号落后就丢弃。
  int _seekToken = 0;

  /// 第几次 loadVideo（自动挂字幕用）
  ///
  /// loadVideo 里有好几个 await（开播放器、列字幕目录、读记忆），期间用户
  /// 可能已经切到下一集了。异步结果回来时拿它对一下：不是最新那次就丢掉，
  /// 否则上一部的字幕会挂到这一部上。
  int _loadToken = 0;

  /// 把当前进度写库（真实视频 id）
  ///
  /// 使用快照避免竞态：如果在 await 期间换片了，丢弃这次写入
  Future<void> _persistProgress() async {
    // 快照当前状态，避免 await 期间状态变化导致写错数据
    final token = _loadToken;
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
    
    // 再次检查是否换片了（在获取快照后可能有其他异步操作触发换片）
    if (token != _loadToken) return;
    
    try {
      await _db.saveProgress(
        video.id,
        nearEnd ? 0 : ms.toDouble(),
        durationMs: durMs,
      );
      // 写库完成后再次检查，如果换片了，这次写入可能已被覆盖，但无害
    } catch (e) {
      debugPrint('[Player] 保存进度失败: $e');
    }
  }

  /// 外部调用：立即保存进度（退出播放器 / 关闭小窗时）
  Future<void> saveProgress() => _persistProgress();

  /// 加载视频
  Future<void> loadVideo(
    VideoModel video, {
    List<VideoModel>? queue,
    int? startIndex,
    Map<String, String>? headers,
  }) async {
    final token = ++_loadToken;
    // 作废在途 seek：换片瞬间上一次 seek 可能还在 await 里，
    // 它回来时会拿新片的位置去写 state（把上一部的时间写进新片）。
    ++_seekToken;
    // 丢弃上一部的 pending resume（可能来自旧 duration 事件尾抛）
    _pendingResume = null;
    _pendingResumeLoadId = 0;
    // 播放页可能只传 path/title 构造的临时模型；
    // 从数据库取真实记录，拿到真实 id 与上次进度。
    VideoModel effective = video;
    try {
      final stored = await _db.getVideoByPath(video.path);
      if (stored != null) effective = stored;
    } catch (_) {}
    // await 之后必须先确认这次 load 还是最新的：
    // 连点「下一集」时，第一次 load 的 Future 可能晚于第二次完成，
    // 若继续往下走会把旧片写进 state（进度写错行、标题/队列全错）。
    if (token != _loadToken) return;

    // 关键：缓存/解码类 mpv 选项是「每文件」的，必须在 open() 之前设置，
    // 否则本次 open 读到的仍是上一部留下的配置（网络源拿不到 cache、
    // 本地片反而背磁盘缓存）。这里在 open 前先按本片来源应用一次。
    _applyOptionsForSource(video.path);

    // 换片：作废上一部遗留的缓冲看门狗与慢源提示，
    // 否则旧定时器可能在新视频上误报「网盘限速」。
    _bufferWatchdog?.cancel();
    _bufferWatchdog = null;
    ++_bufferWatchdogId;
    if (state.isSlowSource) {
      state = state.copyWith(isSlowSource: false, slowSourceHint: '');
    }

    // ── 复播黑屏修复：open 前先 stop 上一个文件 ──
    //
    // mpv 在「已有文件正在播放」的状态下直接 open 新文件，旧的视频输出
    // 上下文（vo 纹理 / 渲染尺寸 / 解码器实例）不会立刻释放，新文件的首帧
    // 常常渲染到旧纹理上 —— 表现就是「退出播放再回来，先黑屏一段、卡一下
    // 才开始出画面」。先 stop() 把上一个文件彻底卸载，再 open 新文件，
    // 渲染管线从干净状态重建，首帧更稳。
    try {
      await state.player.stop();
    } catch (e) {
      debugPrint('[Player] stop 上一个文件失败（忽略）: $e');
    }
    if (token != _loadToken) return;

    // 解码设置必须在 open **之前**应用：hwdec / vd-lavc-threads 是
    // 「每文件」选项，open 之后再设对当前文件不生效（只影响下一部）。
    // 原来放在 open 之后，导致每次首播实际走 mpv 默认解码配置，
    // 高码率片源因此掉帧。
    await applyDecodingMode();
    if (token != _loadToken) return;

    try {
      // 网盘播放需要自定义请求头（Cookie / User-Agent / Referer / Authorization）。
      //
      // **必须走 Media.httpHeaders**：mpv 的 `http-header-fields` 是每文件选项，
      // 用 setProperty 在 open 之前设不保证生效；而且手工拼
      // `'Key:value','Key2:value2'` 时，值里含逗号会被 mpv 截断
      // （夸克/百度的 Cookie 里就有逗号），导致鉴权失败、服务端限速甚至
      // 反复 403 重连 —— 表现出来就是「登录成功但视频缓冲很久」。
      // media_kit 的 Media 原生支持 httpHeaders，由它统一转义和下发。
      await state.player.open(
        Media(
          video.path,
          httpHeaders: (headers != null && headers.isNotEmpty) ? headers : null,
        ),
      );
      if (headers != null && headers.isNotEmpty) {
        debugPrint('[Player] 设置 HTTP 请求头: ${headers.keys.join(",")}');
      }
    } catch (e) {
      debugPrint('[Player] 打开视频失败: $e');
      // 文件可能已被删除/移动，或格式不支持；直接返回防止崩溃
      return;
    }
    if (token != _loadToken) return;

    state = state.copyWith(
      currentVideo: effective,
      queue: queue ?? [effective],
      currentIndex: startIndex ?? 0,
      isCompleted: false,
      position: Duration.zero,
      // 必须清零时长：否则新 duration 事件到达前，旧片时长会参与
      // seek 钳位 / nearEnd 判断 / durationMs 落库（把旧时长永久写进新片）。
      duration: Duration.zero,
      // 换片保留用户当前倍速（原来这里写死 defaultSpeed，导致用户手动切到
      // 1.5x/2x 后一换片就被打回默认值，看起来像「倍速点了没用」）。
      // 只有全新打开播放页（state.speed 尚未被用户改过）才用默认速度。
      speed: state.speed > 0 ? state.speed : AppSettingsService.instance.defaultSpeed,
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
      // 换片时清空字幕显示状态，避免上一部的字幕残留到下一部
      currentSubtitleLines: const [],
      secondarySubtitleLines: const [],
      activeSubtitleIndex: 0,
      secondarySubtitleIndex: 0,
    );
    _lastSaveAt = DateTime.now();
    _lastPosEmitAt = null; // 重置节流，新视频位置立即生效
    _entryHint.clear(); // 清字幕命中缓存，下标从零开始

    // 每次换片重新应用解码设置（mpv 在 open 后可能重置）
    await applyDecodingMode();
    await applyRobustPlayback();
    if (token != _loadToken) return;

    // 应用播放速度：走 setSpeed 而不是裸 setRate，这样会一并配置
    // 音频变速（scaletempo2 + pitch correction），高倍速才真正生效。
    await setSpeed(state.speed > 0
        ? state.speed
        : AppSettingsService.instance.defaultSpeed);

    // iOS：换片后立刻更新锁屏/控制中心的标题（时长要等 duration 事件）
    _syncNowPlaying();

    // 恢复上次播放位置（<1s 视为从头开始）
    final resumeMs = effective.lastPosition;
    debugPrint(
      '[Player] load "${effective.name}" id=${effective.id} '
      'resume=${resumeMs.toInt()}ms',
    );
    if (resumeMs > 1000) {
      final dur = state.player.state.duration;
      // 如果 player 已经报告了时长，立刻钳位并跳转；
      // 否则挂到 pending，等 duration 事件来再跳。
      if (dur > Duration.zero) {
        final clamped = Duration(
            milliseconds: resumeMs.round().clamp(0, dur.inMilliseconds));
        final stoken = ++_seekToken;
        try {
          await state.player.seek(clamped);
        } catch (_) {}
        if (stoken == _seekToken) {
          state = state.copyWith(position: clamped);
        }
      } else {
        _pendingResume = Duration(milliseconds: resumeMs.toInt());
        _pendingResumeLoadId = token; // 绑定到当前 load，旧 duration 事件不会消费
        try {
          await state.player.seek(_pendingResume!);
        } catch (_) {}
      }
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
        await _restoreEmbeddedTrack(pick.trackId, token);
      case SubtitlePickKind.embeddedPreferred:
        // 片源自带内嵌字幕：不自动挂外挂（外挂仍在字幕列表里，想用可以手动选）
        return;
      case SubtitlePickKind.rememberedOff:
        // 用户上次主动关掉了字幕：必须显式设 no track，否则 mpv 换文件会按
        // default/forced flag 自动选内嵌轨 → 画面有字幕、面板却勾着「关闭」。
        await _disableAllSubtitleTracks();
        return;
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
          token: token,
        );
    }
  }

  /// 显式关闭所有字幕轨道，阻止 mpv 换文件后按 default/forced flag 自动启用。
  Future<void> _disableAllSubtitleTracks() async {
    try {
      await state.player.setSubtitleTrack(SubtitleTrack.no());
      await _disableMpvSubtitleRendering();
    } catch (e) {
      debugPrint('[Subtitle] 关闭所有字幕失败: $e');
    }
    state = state.copyWith(
      clearActiveSubtitle: true,
      clearTrackId: true,
      subtitleEntries: null,
      activeSubtitleIndex: 0,
    );
  }

  /// 按记忆选中内嵌字幕轨（不写记忆：这是恢复，不是用户的新选择）
  Future<void> _restoreEmbeddedTrack(String? trackId, int token) async {
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
    if (token != _loadToken) return;
    await _applyEmbeddedSubtitle(track);
  }

  /// 停止播放并清除当前视频（关闭小窗/后台播放）
  Future<void> stop() async {
    // 先落盘进度，再停止
    await _persistProgress();
    // 恢复系统亮度：播放页左半屏下滑把亮度调暗后，必须恢复
    await _restoreBrightness();
    try {
      await state.player.stop();
    } catch (_) {}
    // 关掉串流代理，释放本地端口。
    // 必须在这里而不是播放页 dispose：用户可能从播放页返回首页继续用小窗
    // 听声音，那时代理还要活着；只有真正 stop（关小窗/结束播放）才该释放。
    try {
      await CloudDriveService.instance.stopStreamProxy();
    } catch (_) {}
    // 停止播放后不再需要前台服务（无条件关，就算状态不对也关到位）
    _forceShutdownBackgroundService();
    // 恢复后台任务（缩略图/刮削）
    PlaybackBusy.playing = false;
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

  /// 跳转：钳位到有效区间，并用 seekToken 保护竞态。
  ///
  /// 对网络源（NAS/云盘/直链），若 mpv 不支持该流的精确跳转，
  /// position 流会在 200ms 内自然拉回实际位置，进度条不会卡在错误值。
  Future<void> seekTo(Duration position) async {
    final dur = state.duration;
    final clamped = dur > Duration.zero
        ? (position < Duration.zero
            ? Duration.zero
            : (position > dur ? dur : position))
        : position;
    final token = ++_seekToken;
    try {
      await state.player.seek(clamped);
    } catch (_) {}
    // 如果这期间又有了新的 seek 请求，这次的结果作废
    if (token != _seekToken) return;
    state = state.copyWith(position: clamped);
    // 立即按新位置刷新字幕命中下标（不等 position 流回推，避免旧字幕残留）
    _updateActiveSubtitle();
  }

  /// 相对跳转
  Future<void> seekRelative(int seconds) async {
    final dur = state.duration;
    if (dur <= Duration.zero) {
      // 时长未知：做不了相对跳转
      await state.player.seek(state.position);
      return;
    }
    final raw = state.position + Duration(seconds: seconds);
    final target =
        raw < Duration.zero ? Duration.zero : (raw > dur ? dur : raw);
    final token = ++_seekToken;
    try {
      await state.player.seek(target);
    } catch (_) {}
    if (token != _seekToken) return;
    state = state.copyWith(position: target);
    // 立即按新位置刷新字幕命中下标
    _updateActiveSubtitle();
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

  /// 进播放页时存系统真实亮度（0-1），退出时用它恢复。
  ///
  /// 之前 `brightness` 默认值硬编码为 0.5，进播放页第一次下滑亮度
  /// 会从真实值（如 90%）瞬间跳到 50%，视觉上是一闪。
  /// 这里读取一次系统真实值作为起点。
  /// 失败（权限/无传感器）用 0.5 作为兜底。
  double? _savedSystemBrightness;
  Future<void> captureSystemBrightness() async {
    try {
      _savedSystemBrightness = await ScreenBrightness().application;
    } catch (_) {
      _savedSystemBrightness = null;
    }
    if (_savedSystemBrightness != null &&
        state.currentVideo != null &&
        state.brightness == 0.5) {
      // 用真实值替换硬编码默认值；若用户设过且不等于 0.5 则不动
      state = state.copyWith(brightness: _savedSystemBrightness!);
    }
  }

  /// 退出播放/关闭小窗时恢复系统亮度（由 stop()/dispose() 调用）。
  Future<void> _restoreBrightness() async {
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
      debugPrint('[Brightness] 系统亮度已恢复');
    } catch (e) {
      debugPrint('[Brightness] 恢复系统亮度失败: $e');
    }
  }

  /// 设置倍速
  ///
  /// 高倍速（>2x）能生效的前提是 mpv 侧配置了音频变速：
  ///  - `audio-pitch-correction=yes`：变速不变调（否则高倍速声音尖锐）
  ///  - `audio-stream-silence`：变速期间保持音频时钟稳定
  ///  - 变速滤镜 `scaletempo2`：mpv 默认的 scaletempo 在高倍速下
  ///    容易丢音/断流，scaletempo2 是专门为大范围变速做的实现
  ///
  /// 之前只调 `setRate` 没配这些，mpv 在 >2x 时会因音频跟不上而把
  /// rate 钳回 2.0（表现就是「点 2.5x/3x/4x 没反应」）。
  Future<void> setSpeed(double speed) async {
    // 钳到合理范围：mpv 官方支持 0.01~100，但 >4x 音画同步体验很差
    final clamped = speed.clamp(0.25, 4.0).toDouble();
    state = state.copyWith(speed: clamped);
    try {
      final platform = state.player.platform;
      if (platform is NativePlayer) {
        // 变速相关参数：只在**非 1x** 时挂 scaletempo2 滤镜。
        // 1x 下挂滤镜是纯浪费（每帧都要做重采样/时间伸缩），会拖低播放
        // 流畅度；正常速度必须走直通路径。
        await platform.setProperty('audio-pitch-correction', 'yes');
        if ((clamped - 1.0).abs() > 0.01) {
          await platform.setProperty('audio-stream-silence', 'yes');
          await platform.setProperty('af', 'scaletempo2');
        } else {
          await platform.setProperty('af', '');
        }
      }
      await state.player.setRate(clamped);
    } catch (e) {
      debugPrint('[Player] 设置倍速失败 ($clamped): $e');
    }
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
  /// 统一字幕渲染策略：主/次字幕都由自绘浮层画，mpv 只负责解析出
  /// 「当前该显示的字幕文本」（sub-text / secondary-sub-text），不再自己画。
  ///
  /// sub-visibility=no 只关渲染，`stream.subtitle` 依旧正常推送当前文本。
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
      activeSubtitleIndex: 0,
      // 立即清空主字幕文本，不等 mpv sub-text 流回推空
      currentSubtitleLines: const [],
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
    await _applyExternalSubtitle(path,
        title: title, language: language, token: _loadToken);
    // 只有手动选择才写记忆：自动挂载如果也写，等于把自动挑的结果
    // 伪装成用户意愿，下次"恢复"的其实是自己猜的东西
    await _rememberSubtitleChoice(path);
  }

  /// 把外挂字幕挂到播放器并解析成本地条目（不写记忆）
  Future<void> _applyExternalSubtitle(
    String path, {
    String? title,
    String? language,
    required int token,
  }) async {
    if (token != _loadToken) return;
    try {
      await state.player.setSubtitleTrack(
        SubtitleTrack.uri(path, title: title, language: language),
      );
      await _disableMpvSubtitleRendering();
    } catch (e) {
      debugPrint('[Subtitle] 载入外挂字幕失败: $e');
    }
    if (token != _loadToken) return;
    final model = SubtitleModel(
      path: path,
      language: language ?? '外挂字幕',
      title: title ?? path.split('/').last,
    );
    final entries = await _parseSubtitle(model);
    if (token != _loadToken) return;
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

  /// 把某个内嵌轨设为第二字幕。
  ///
  /// mpv 的 `secondary-sub-text` 属性会推送第二字幕文本（同主字幕的
  /// `sub-text`），因此内嵌第二字幕也能统一走 Flutter 渲染，不再依赖
  /// mpv/libass 原生绘制。
  ///
  /// 关键：`secondary-sid` 让 mpv 解析该轨并更新 `secondary-sub-text`；
  /// `secondary-sub-visibility=no` 只关 libass 绘制，文本属性照常推送。
  /// 这样第二字幕文本交给 Flutter 浮层，避免「mpv 画一份 + Flutter 画一份」。
  Future<void> setSecondaryEmbedded(SubtitleTrack track) async {
    final platform = state.player.platform;
    try {
      if (platform is NativePlayer) {
        await platform.setProperty('secondary-sid', track.id);
        // 关掉 libass 第二字幕绘制，文本走 secondary-sub-text 由 Flutter 画
        await platform.setProperty('secondary-sub-visibility', 'no');
      }
    } catch (e) {
      debugPrint('[Subtitle] 设置内嵌第二字幕失败: $e');
    }
    state = state.copyWith(
      secondaryTrackId: track.id,
      clearSecondarySubtitle: true,
      secondarySubtitleLines: const [],
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
    // 立即按当前播放位置刷新第二字幕命中下标（不等 position 流）
    _updateActiveSubtitle();
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
      secondarySubtitleLines: const [],
    );
    await _applySubtitleLayout();
  }

  /// 主字幕位置：外挂第二字幕与主字幕现在**合并到同一个 Flutter 浮层**，
  /// 不再需要把 mpv 主字幕抬高。此方法保留仅为兼容内嵌第二字幕（secondary-sid）
  /// 的场景 —— 那时主/次字幕都由 mpv/libass 自己布局，也不该手动改 sub-pos。
  Future<void> _applySubtitleLayout() async {
    // 统一渲染后不再手动调整 sub-pos，交给默认布局即可
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

  /// 把 mpv 推的单个字幕文本转成行列表。
  ///
  /// mpv 的 `sub-text` / `secondary-sub-text` 是单字符串，可能含 `\n`
  /// 换行（ASS 的 \N 或 SRT 多行）。这里拆成行、过滤空行。
  static List<String> _toLines(String text) {
    if (text.isEmpty) return const <String>[];
    final lines =
        text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    return List<String>.from(lines);
  }

  void _updateActiveSubtitle() {
    final pos = state.position;
    final p = _entryIndexAt(state.subtitleEntries, pos);
    // 命中条目变化才更新；不在任何区间时把下标清回 -1，
    // 避免字幕过期后浮层仍显示上一条（旧状态残留）。
    final nextP = p ?? -1;
    if (nextP != state.activeSubtitleIndex) {
      state = state.copyWith(activeSubtitleIndex: nextP);
    }
    final s = _entryIndexAt(state.secondaryEntries, pos);
    final nextS = s ?? -1;
    if (nextS != state.secondarySubtitleIndex) {
      state = state.copyWith(secondarySubtitleIndex: nextS);
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
    _bufferWatchdog?.cancel();
    // 恢复系统亮度 + 收掉前台通知
    _restoreBrightness();
    _forceShutdownBackgroundService();
    state.player.dispose();
    super.dispose();
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, PlayerState>(
  (ref) => PlayerNotifier(),
);
