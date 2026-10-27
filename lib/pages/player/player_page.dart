/// 视频播放器页面 — iOS 27 玻璃质感
///
/// 手机 / 平板统一：全屏视频 + 玻璃控制栏（浮层自动隐藏）
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/system/orientation_policy.dart';
import '../../core/system/system_ui_policy.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/video_model.dart';
import '../../models/cast_device_model.dart';
import '../../models/subtitle_model.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/ui_settings_provider.dart';
import '../../providers/cast_provider.dart';
import '../../services/app_settings_service.dart';
import '../../services/media_namer_service.dart';
import '../../services/subtitle_service.dart';
import '../../services/cloud_subtitle_service.dart';
import '../../services/native_bridge_service.dart';
import '../../services/library_prune_service.dart';
import '../../widgets/player/player_gesture_layer.dart';
import '../../widgets/player/subtitle_overlay.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_slider.dart';
import '../../widgets/glass/safe_glass.dart';
import '../../widgets/scrape/scrape_widgets.dart';
import '../../widgets/keyboard_shortcut_handler.dart';

class PlayerPage extends ConsumerStatefulWidget {
  final String videoPath;
  final String videoTitle;

  /// 播放队列（视频 id 列表，来自播放列表/文件夹），按顺序播放
  final List<String>? queueIds;
  final int startIndex;
  
  /// 自定义 HTTP 请求头（网盘播放需要带 Cookie/UA 等）
  final Map<String, String>? headers;

  /// 网盘上下文（用于「同目录外挂字幕」查找）。
  ///
  /// 网盘视频只有 HTTP 直链、没有本地目录，播放页无法像本地视频那样
  /// `Directory(dirname).list()` 找字幕。带上账号 id + 目录 id 后，
  /// 播放页才能回头去列网盘目录、下载同名字幕。
  /// 三者都为 null 表示不是网盘来源（本地/NAS）。
  final String? cloudAccountId;
  final String? cloudDirId;
  final String? cloudVideoName;

  const PlayerPage({
    super.key,
    required this.videoPath,
    required this.videoTitle,
    this.queueIds,
    this.startIndex = 0,
    this.headers,
    this.cloudAccountId,
    this.cloudDirId,
    this.cloudVideoName,
  });

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _showControls = true;
  bool _showSpeedSelector = false;
  bool _isFullscreen = false;

  /// 手势拖动进度时的预览位置（毫秒）；null 表示当前没在拖动。
  ///
  /// 用 ValueNotifier 而不是普通字段：拖动过程中每次预览更新只通知
  /// 进度条/时间文字局部重建，**不触发整页 setState**，避免打断
  /// 正在进行的手势（这就是之前"进度条只能滑几下"的根因）。
  final ValueNotifier<double?> _seekPreviewMs = ValueNotifier<double?>(null);

  /// GlassSlider 正在拖动时置 true，用来禁止手势层同时触发的 seek。
  bool _sliderDragging = false;

  /// 长按前的速度，松手时恢复这个值
  double? _speedBeforeLongPress;

  /// 控件自动隐藏定时器（可取消）
  Timer? _autoHideTimer;

  /// 系统是否支持画中画（不支持则不显示该按钮）
  bool? _pipSupported;

  late VideoController _videoController;
  late AnimationController _controlsAnim;

  /// 提前抓住 notifier 引用。
  ///
  /// `dispose()` 阶段 `ref` 已经失效，此时再 `ref.read(...)` 会抛
  /// 「Cannot use "ref" after the widget was disposed」，导致**播放进度存不进去**
  /// （日志里就是这条）。所以在 initState 就把 notifier 和版本号 notifier 存下来，
  /// dispose 里直接用缓存引用。
  PlayerNotifier? _playerNotifier;
  StateController<int>? _playbackVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 使用全局 VideoController，页面销毁时保留引用给 mini player 复用
    _videoController = ref.read(playerProvider).videoController!;
    // dispose 阶段 ref 不可用，提前缓存 notifier
    _playerNotifier = ref.read(playerProvider.notifier);
    _playbackVersion = ref.read(playbackVersionProvider.notifier);
    _controlsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1,
    );
    // 方向：按用户设置（auto/landscape/portrait）决定进入方向
    OrientationPolicy.applyPlayer(
      orientation: AppSettingsService.instance.playerOrientation,
    );
    // 播放页默认就是「沉浸式」：状态栏/导航栏都收起来。
    //
    // 这里必须**同时**做两件事，缺一不可：
    //  1) applyImmersive()：调 setEnabledSystemUIMode(immersiveSticky)，
    //     真正把状态栏/导航栏从屏幕上隐藏掉；
    //  2) _applyPlayerFullscreenUi()：设样式（透明底 + 白色图标）。
    //
    // 之前只做了第 2 步，结果是 `statusBarColor: transparent` 让状态栏底
    // 变透明，但**状态栏本身还在**——在 edgeToEdge 模式下它仍然占据屏幕
    // 顶部空间并显示时间/电量图标，所以用户看到「播放界面状态栏还是显示」。
    SystemUiPolicy.applyImmersive();
    _applyPlayerFullscreenUi();
    // 延迟到 widget tree 构建完成后加载视频
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadVideo();
      // 捕获系统真实亮度作为起点，避免"硬编码 0.5 → 真实值 0.9"的跳变
      ref.read(playerProvider.notifier).captureSystemBrightness();
      _startAutoHideTimer();
      _checkPipSupport();
    });
  }

  /// 进入播放页时设置的系统 UI 样式（透明状态栏 + 白色图标，沉浸式）。
  static void _applyPlayerFullscreenUi() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  /// 查询系统是否支持画中画
  Future<void> _checkPipSupport() async {
    final supported = await NativeBridgeService.instance.isPipSupported();
    if (mounted) setState(() => _pipSupported = supported);
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _controlsAnim.dispose();
    _seekPreviewMs.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _restoreIdleOrientation();
    // 用 initState 缓存的引用：dispose 阶段 ref 已失效
    try {
      _playerNotifier?.saveProgress();
    } catch (e) {
      debugPrint('[Player] dispose 保存进度失败: $e');
    }
    // 进度已落库，通知历史页刷新（不 invalidate videoListProvider——dispose
    // 阶段 invalidate 可能触发首页在 widget tree 销毁过程中重建导致闪退）
    try {
      _playbackVersion?.state++;
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      try {
        ref.read(playerProvider.notifier).saveProgress();
      } catch (_) {}
    }
  }

  /// 退出播放页的方向恢复 + 退出沉浸模式。
  ///
  /// 注意：**不能**无脑锁竖屏 —— 平板横放时锁竖屏会被系统加黑边，
  /// 首页又变回「竖条 + 导航栏挤到侧边」。交给 OrientationPolicy
  /// 按设备类型决定（手机竖屏 / 平板跟随物理方向）。
  void _restoreIdleOrientation() {
    OrientationPolicy.applyIdle();
    // 按 Android 版本恢复系统栏：低版本用 manual，避免导航栏遮住页面底部
    SystemUiPolicy.applyPlayerExit();
    // 恢复浅色状态栏图标（首页等页面是浅色背景，深色图标）
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: GlassTheme.bg,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  /// 退出播放器：先落盘进度、恢复方向，再返回
  Future<void> _exitPlayer() async {
    try {
      await ref.read(playerProvider.notifier).saveProgress();
    } catch (_) {}
    // 通知历史页刷新（版本号递增，不 invalidate 整个 provider）
    try {
      ref.read(playbackVersionProvider.notifier).state++;
    } catch (_) {}
    _restoreIdleOrientation();
    if (mounted) context.pop();
  }

  /// 切换全屏（横屏沉浸）
  ///
  /// 注意：这里「退出全屏」指的是回到播放页的**常规竖屏/自适应方向**，
  /// 不是退出播放页。所以两种状态下都保持沉浸式（状态栏隐藏），
  /// 只有真正离开播放页（[_restoreIdleOrientation]）才恢复系统栏。
  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      _isFullscreen = false;
      await OrientationPolicy.applyIdle();
      // 仍在播放页 → 继续沉浸，不能调 applyPlayerExit（那会让状态栏回来）
      await SystemUiPolicy.applyImmersive();
    } else {
      _isFullscreen = true;
      await OrientationPolicy.applyFullscreen();
      await SystemUiPolicy.applyImmersive();
      // ⚠ 进入 immersive 后不要调 _applyPlayerFullscreenUi ——
      // setSystemUIOverlayStyle 在某些 Android 版本上会覆盖 immersive，
      // 导致状态栏重新显示为透明浮层。
    }
    if (mounted) setState(() {});
  }

  void _startAutoHideTimer() {
    // 用可取消的 Timer：原来用 Future.delayed，快速切页/反复点击时
    // 会累积一堆无法取消的回调
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && ref.read(playerProvider).isPlaying) {
        _hideControls();
      }
    });
  }

  void _toggleControls() {
    // 动画正在跑（控件正在淡出/淡入）：说明用户在这个 350ms 窗口里
    // 又点了一次屏幕。直接 forward 回到可见态，不做状态机判断。
    // 否则 `_showControls` 还没变（要等 .then 才改），
    // _hideControls() 会再调一次 reverse() → 控件继续隐藏。
    if (_controlsAnim.isAnimating) {
      _controlsAnim.forward();
      _startAutoHideTimer();
      return;
    }
    if (_showControls) {
      _hideControls();
    } else {
      // 必须 setState：控件隐藏时已从 widget 树移除，
      // 只改标志位不会重建，之前这里导致控件再也唤不出来
      setState(() => _showControls = true);
      _controlsAnim.forward();
      _startAutoHideTimer();
    }
  }

  void _hideControls() {
    _controlsAnim.reverse().then((_) {
      if (mounted) setState(() => _showControls = false);
    });
  }

  /// 是否有「外挂第二字幕」需要自绘浮层
  bool _hasSecondaryOverlay(PlayerState state) =>
      state.secondaryEntries != null && state.secondaryEntries!.isNotEmpty;

  // ─────────── 字幕外观（来自设置，运行时即时生效）───────────

  AppSettingsService get _settings => AppSettingsService.instance;

  double _subtitleFontSize(bool isLarge) {
    final v = _settings.subtitleFontSize;
    if (v > 0) return isLarge ? v + 2 : v;
    return isLarge ? 18 : 16;
  }

  /// 把设置的字符串对齐值转成 TextAlign。
  TextAlign _subtitleAlign(String value) {
    switch (value) {
      case 'start':
        return TextAlign.left;
      case 'end':
        return TextAlign.right;
      case 'center':
      default:
        return TextAlign.center;
    }
  }

  /// 主字幕命中的 ASS 条目（带 verticalPos / alignment）。
  ///
  /// 主字幕若是外挂 ASS/SSA，`subtitleEntries` 里存的解析结果含定位信息；
  /// 命中下标 `activeSubtitleIndex` 指向当前应显示的条目。内嵌字幕无此信息，
  /// 返回 null（mpv 只推纯文本，没有 ASS 定位）。
  SubtitleEntry? _primaryAssEntry(PlayerState state) {
    final entries = state.subtitleEntries;
    if (entries == null || entries.isEmpty) return null;
    final idx = state.activeSubtitleIndex;
    if (idx < 0 || idx >= entries.length) return null;
    return entries[idx];
  }

  double _subtitleBottom(bool isLarge) {
    final base = isLarge ? 20.0 : 12.0;
    final screenH = MediaQuery.of(context).size.height;
    // 叠加底部安全区（手势导航条/圆角屏），避免字幕被系统 UI 遮挡
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return base + safeBottom + _settings.subtitlePosition * screenH * 0.85;
  }

  /// 手势拖动进度：实时带动底部进度条（局部通知，不整页重建）
  void _onSeekPreview(int targetMs) {
    _seekPreviewMs.value = targetMs.toDouble();
  }

  /// 松手提交跳转
  void _onSeekCommit(int targetMs) {
    ref.read(playerProvider.notifier).seekTo(Duration(milliseconds: targetMs));
    _seekPreviewMs.value = null;
  }

  /// 滑块开始拖动：通知手势层抑制横向 seek
  void _onSliderDragStart() {
    if (!mounted) return;
    setState(() => _sliderDragging = true);
  }

  /// 滑块结束拖动（松手/取消）：清除预览，通知手势层恢复
  void _onSliderDragEnd() {
    if (!mounted) return;
    setState(() {
      _sliderDragging = false;
    });
    _seekPreviewMs.value = null;
  }

  /// 长按画面开始 → 倍速播放
  void _onLongPressStart() {
    final notifier = ref.read(playerProvider.notifier);
    final currentSpeed = ref.read(playerProvider).speed;
    _speedBeforeLongPress = currentSpeed;
    final targetSpeed = AppSettingsService.instance.longPressSpeed;
    notifier.setSpeed(targetSpeed);
  }

  /// 松手 → 恢复原速
  void _onLongPressEnd() {
    final restore = _speedBeforeLongPress;
    if (restore != null) {
      ref.read(playerProvider.notifier).setSpeed(restore);
      _speedBeforeLongPress = null;
    }
  }

  Future<void> _loadVideo() async {
    final path = widget.videoPath;
    // 本地文件不存在 → 弹 toast 返回，不闪退。
    //
    // 注意：照片库资产是 phasset://<id> 虚拟路径（磁盘上没有文件）、
    // 网盘/NAS 是远程地址，都不能用 File.existsSync 判断，否则一进播放页
    // 就被误判成「文件已不存在」直接弹回去。
    if (!LibraryPruneService.isRemotePath(path) && !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('视频文件已不存在，可能已被删除或移动')),
        );
        context.pop();
      }
      return;
    }

    final model = VideoModel(
      id: widget.videoPath,
      path: widget.videoPath,
      name: widget.videoTitle,
      folderPath: '',
      size: 0,
      durationMs: 0,
      dateAdded: DateTime.now(),
      dateModified: DateTime.now(),
    );

    // 有队列时按队列顺序加载（播放列表 / 剧集连播）
    List<VideoModel>? queue;
    final ids = widget.queueIds;
    if (ids != null && ids.isNotEmpty) {
      final all = ref.read(libraryProvider).valueOrNull ?? const <VideoModel>[];
      final byId = {for (final v in all) v.id: v};
      queue = ids
          .map((id) => byId[id])
          .whereType<VideoModel>()
          .toList(growable: false);
      if (queue.isEmpty) queue = null;
    }

    // ── 复播黑屏修复（关键）──
    //
    // 每次进入播放页都无条件 loadVideo 会出问题：
    //  * 从 mini player / 后台回到播放页时，同一个视频**正在播放**，
    //    再 open 一次会先把渲染管线拆掉重建 —— 表现为黑屏 + 卡顿重载；
    //  * 连播队列里上一集的播放也会被无谓打断。
    // 所以先判断：当前播放器里已经是这个视频，且队列一致，就直接复用，
    // 只补一次播放（若被暂停过）和进度恢复，不再重新 open。
    final notifier = ref.read(playerProvider.notifier);
    final playerState = ref.read(playerProvider);
    final current = playerState.currentVideo;
    final sameVideo = current != null && current.path == widget.videoPath;
    if (sameVideo && !playerState.isCompleted) {
      // 队列变了（例如从剧集列表换了入口）才需要重载，否则复用
      final sameQueue =
          queue == null || queue.length == playerState.queue.length;
      if (sameQueue) {
        debugPrint('[Player] 复用已加载的视频，跳过重新 open: ${widget.videoPath}');
        // 页面回来时如果处于暂停（如小窗被暂停），恢复播放
        if (!playerState.isPlaying) {
          try {
            await notifier.togglePlayPause();
          } catch (_) {}
        }
        return;
      }
    }

    await notifier.loadVideo(
          model,
          queue: queue,
          startIndex:
              queue == null ? 0 : widget.startIndex.clamp(0, queue.length - 1),
          headers: widget.headers,
        );

    // 网盘：后台查找并下载「同目录外挂字幕」。
    //
    // 本地视频由 SubtitleService 扫同目录，但网盘只有 HTTP 直链、没有目录，
    // 那边会直接跳过。这里用播放时带上的账号/目录上下文回头列一次目录，
    // 找到同名 .srt/.ass 后下载到本地缓存再挂载。
    // 不 await：字幕是加分项，不能挡住视频开播。
    _loadCloudSubtitlesIfNeeded();
  }

  /// 网盘同目录字幕：查找 → 下载 → 挂载（后台执行，不阻塞播放）。
  Future<void> _loadCloudSubtitlesIfNeeded() async {
    final accountId = widget.cloudAccountId;
    final dirId = widget.cloudDirId;
    if (accountId == null || dirId == null) return; // 非网盘来源
    if (!mounted) return;

    try {
      final subs = await CloudSubtitleService.instance.findAndDownload(
        accountId: accountId,
        dirId: dirId,
        videoName: widget.cloudVideoName ?? widget.videoTitle,
      );
      if (!mounted || subs.isEmpty) return;

      // 已有字幕（用户自己选了 / 内嵌）就不要覆盖
      final st = ref.read(playerProvider);
      if (st.activeSubtitle != null) return;

      final notifier = ref.read(playerProvider.notifier);
      // 先把候选列表塞进状态（面板里可见），再自动挂第一个
      notifier.addAvailableSubtitles(subs);
      await notifier.selectSubtitle(subs.first);
      debugPrint('[CloudSub] 已自动挂载字幕: ${subs.first.title}');
    } catch (e) {
      debugPrint('[CloudSub] 自动挂载失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听字幕设置变更：改字号/位置/背景后立即重建浮层
    ref.watch(subtitleSettingsTickProvider);

    // 只订阅「结构性」字段：position / 字幕行号这类高频变化的字段
    // 由进度条、时间文字、字幕浮层等叶子节点各自 select 订阅。
    // 否则播放中整页会以每秒数次重建（发热、掉帧的主因之一）。
    ref.watch(
      playerProvider.select(
        (p) => (
          p.currentVideo?.id,
          p.videoController != null,
          p.queue.length,
          p.currentIndex,
          p.isPlaying,
          p.isBuffering,
          p.isSlowSource,
          p.slowSourceHint,
          p.isCompleted,
          p.duration.inMilliseconds,
          p.speed,
          p.volume,
          p.brightness,
          p.videoWidth,
          p.videoHeight,
          p.videoCodec,
          p.videoFps,
          p.embeddedSubtitles.length,
          p.audioTracks.length,
          p.activeTrackId,
          p.secondaryTrackId,
          // 字幕列表按「对象身份」比较（List 未重写 ==），换了文件也会重建
          p.subtitleEntries,
          p.secondaryEntries,
          // 统一字幕渲染：mpv 当前显示的多行字幕
          p.currentSubtitleLines,
        ),
      ),
    );
    final playerState = ref.read(playerProvider);

    // 手机 / 平板统一用全屏布局：视频铺满整屏、控件浮层自动隐藏。
    // 之前平板横屏走「左视频 62% + 右控制面板 38%」的分栏，视频铺不满、
    // 右边像一直有块面板挡着，观感也和手机端不一致。
    return _buildFullScreenLayout(context, playerState);
  }

  // ═══════════════ 全屏（手机 / 平板统一） ═══════════════

  Widget _buildFullScreenLayout(BuildContext context, PlayerState state) {
    final isLarge = AppBreakpoints.isLargeScreen(context);
    // 横屏/大屏下控制栏要**更紧凑**，不是放大。
    //
    // 原来 isLarge ? 1.3 : 1.0：手机横屏后宽度 > 平板阈值，误判成"大屏"，
    // 所有间距/字号/按钮都放大 30%，导致横屏控制栏很占地方（用户反馈）。
    // 横屏本来垂直空间就紧张（视频上下有黑边），控制栏越紧凑越好。
    final buttonScale = isLarge ? 0.85 : 1.0;

    return KeyboardShortcutHandler(
      onPlayPause: () => ref.read(playerProvider.notifier).togglePlayPause(),
      onSeekForward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(AppSettingsService.instance.skipSeconds),
      onSeekBackward: () => ref
          .read(playerProvider.notifier)
          .seekRelative(-AppSettingsService.instance.skipSeconds),
      onVolumeUp: () => ref
          .read(playerProvider.notifier)
          .setVolume((state.volume + 0.05).clamp(0, 1)),
      onVolumeDown: () => ref
          .read(playerProvider.notifier)
          .setVolume((state.volume - 0.05).clamp(0, 1)),
      onToggleSubtitles: _showSubtitleSheet,
      onToggleSpeed: () =>
          setState(() => _showSpeedSelector = !_showSpeedSelector),
      onExit: _exitPlayer,
      onSeekFraction: (fraction) {
        // 用 ref.read 取实时位置，避免订阅高频字段
        final live = ref.read(playerProvider);
        ref.read(playerProvider.notifier).seekRelative(
              ((fraction * live.duration.inMilliseconds / 1000) -
                      live.position.inMilliseconds / 1000)
                  .round(),
            );
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // 视频铺到状态栏后面，实现真正的沉浸式（顶栏/底栏自己处理安全区）
        extendBodyBehindAppBar: true,
        extendBody: true,
        body: Stack(
          children: [
            // 播放页全屏：视频层不做圆角裁剪（避免每帧纹理裁剪合成的卡顿）
            _buildVideoLayer(state, rounded: false),
            // 手势层需要实时的播放位置作为拖动基准，
            // 单独用一个只订阅 position 的 Consumer 包住（不重建整页）
            _LivePosition(
              builder: (context, live) => PlayerGestureLayer(
                onTap: _toggleControls,
                onDoubleTap: () =>
                    ref.read(playerProvider.notifier).togglePlayPause(),
                initialBrightness: state.brightness,
                initialVolume: state.volume,
                positionMs: live.position.inMilliseconds,
                durationMs: live.duration.inMilliseconds,
                onBrightnessChange: (value) =>
                    ref.read(playerProvider.notifier).setBrightness(value),
                onVolumeChange: (value) =>
                    ref.read(playerProvider.notifier).setVolume(value),
                onSeekPreview: _onSeekPreview,
                onSeekCommit: _onSeekCommit,
                onLongPressStart: _onLongPressStart,
                onLongPressEnd: _onLongPressEnd,
                longPressSpeed: AppSettingsService.instance.longPressSpeed,
                blockSeek: _sliderDragging,
              ),
            ),
            // ── 统一字幕渲染入口 ──
            // 主字幕（mpv sub-text）+ 第二字幕（内嵌 secondary-sub-text 或
            // 外挂 entries）合并到**同一个** SubtitleOverlay，全部由 Flutter
            // 渲染。mpv/libass 只解析文本、不绘制，彻底消除双重绘制。
            _LiveSubtitle(
              builder: (context, live) {
                final hasPrimary = live.currentSubtitleLines.isNotEmpty;
                // 内嵌第二字幕：secondarySubtitleLines（mpv 文本）
                final embeddedSecondary =
                    live.secondarySubtitleLines.isNotEmpty;
                // 外挂第二字幕：secondaryEntries（Dart 解析 + 命中）
                final externalSecondary = _hasSecondaryOverlay(live);
                final hasSecondary = embeddedSecondary || externalSecondary;

                if (!hasPrimary && !hasSecondary) {
                  return const SizedBox.shrink();
                }

                return Positioned(
                  bottom: _subtitleBottom(isLarge),
                  left: isLarge ? 40 : 20,
                  right: isLarge ? 40 : 20,
                  // IgnorePointer：字幕文字不能吞掉手势（单击唤控件、双击暂停、
                  // 长按加速），否则点在字幕上时下层 PlayerGestureLayer 收不到事件。
                  child: IgnorePointer(
                    child: SubtitleOverlay(
                      lines: hasPrimary ? live.currentSubtitleLines : const [],
                      secondaryLines: embeddedSecondary
                          ? live.secondarySubtitleLines
                          : const [],
                      entries:
                          externalSecondary ? live.secondaryEntries! : const [],
                      activeIndex:
                          externalSecondary ? live.secondarySubtitleIndex : -1,
                      fontSize: _subtitleFontSize(isLarge),
                      fontFamily: _settings.subtitleFontFamily,
                      fontWeightIndex: _settings.subtitleFontWeight,
                      lineHeight: _settings.subtitleLineHeight,
                      lineSpacing: _settings.subtitleLineSpacing,
                      bgOpacity: _settings.subtitleBgOpacity,
                      bgColor: Color(_settings.subtitleBgColorValue),
                      showBg: _settings.subtitleShowBg,
                      bgRadius: _settings.subtitleBgRadius,
                      textColor: Color(_settings.subtitleTextColorValue),
                      stroke: _settings.subtitleStroke,
                      secondaryScale: _settings.subtitleSecondaryScale,
                      secondaryDim: _settings.subtitleSecondaryDim,
                      align: _subtitleAlign(_settings.subtitleAlign),
                      primaryAssEntry: _primaryAssEntry(live),
                      useAssPosition: _settings.subtitleUseAssPosition,
                      // 已选第二字幕轨道 → 双字幕模式：主/副各占固定槽位，
                      // 避免某一路短暂为空时另一路"降下来"单行显示。
                      dualMode: live.secondaryTrackId != null ||
                          live.secondarySubtitle != null,
                    ),
                  ),
                );
              },
            ),
            // 弹出面板
            _buildPopupMenus(context, state),
            // 控制栏（玻璃动画）
            if (_showControls)
              // FadeTransition 直接驱动 RenderObject，不像 Opacity 那样
              // 每帧 saveLayer，也不像 AnimatedBuilder 那样每帧重建子树
              // （控制层里有两个全宽毛玻璃）
              RepaintBoundary(
                child: FadeTransition(
                  opacity: _controlsAnim,
                  child: Stack(
                    children: [
                      _buildGlassTopBar(context, state, isLarge: isLarge),
                      _buildGlassBottomControls(
                        context,
                        state,
                        scale: buttonScale,
                      ),
                      _buildCenterPlayButton(state, scale: buttonScale),
                    ],
                  ),
                ),
              ),
            // 缓冲
            if (state.isBuffering)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: GlassTheme.accentPurple,
                      strokeWidth: isLarge ? 4 : 3,
                    ),
                    // 长时间缓冲（>8s）时说明原因，避免用户对着转圈干等
                    if (state.isSlowSource && state.slowSourceHint.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16, left: 32, right: 32),
                        child: Text(
                          state.slowSourceHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: GlassTheme.textSecondary,
                            fontSize: isLarge ? 15 : 13,
                            height: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ═══════════════ 玻璃顶栏 ═══════════════

  Widget _buildGlassTopBar(
    BuildContext context,
    PlayerState state, {
    bool isLarge = false,
  }) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ClipRect(
        child: SafeBackdropFilter(
          blurSigma: 18,
          child: Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withOpacity(0.6), Colors.transparent],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                  onPressed: _exitPlayer,
                ),
                // 只显示文件名，详细参数放在「详情」弹窗里
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
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
                      // HDR / 杜比视界角标：识别到就显示，紧贴文件名右侧
                      if (_hdrBadgeText(state) != null) ...[
                        const SizedBox(width: 8),
                        _buildHdrBadge(state),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '视频详情',
                  icon: const Icon(
                    Icons.info_outline_rounded,
                    color: Colors.white70,
                  ),
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
                // 小窗（画中画）：不支持则整个按钮不显示，避免出现点不动的按钮
                if (_pipSupported == true)
                  IconButton(
                    tooltip: '小窗播放',
                    icon: const Icon(
                      Icons.picture_in_picture_rounded,
                      color: Colors.white70,
                    ),
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
            : '未知',
      ],
      [
        '视频编码',
        (state.videoCodec?.isNotEmpty == true) ? state.videoCodec! : '未知',
      ],
      [
        '帧率',
        (state.videoFps != null && state.videoFps! > 0)
            ? '${_fmtFps(state.videoFps!)}'
            : '未知',
      ],
      [
        'HDR',
        state.hdrType ??
            ((state.colorPrimaries?.isNotEmpty == true)
                ? '${_hdrLabel(state.colorPrimaries!, state.transferFunction)}'
                : 'SDR'),
      ],
      [
        '色彩',
        (state.colorPrimaries?.isNotEmpty == true)
            ? '${state.colorPrimaries} · ${state.transferFunction ?? "未知传递"}'
            : '未知',
      ],
      ['音频', _audioTrackDesc(state)],
      [
        '时长',
        state.duration > Duration.zero ? _fmtDuration(state.duration) : '未知',
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
              }).join(' / '),
      ],
      ['解码方式', AppSettingsService.instance.hardwareDecoding ? '硬件解码' : '软件解码'],
      ['播放次数', v != null ? '${v.playCount} 次' : '0 次'],
      [
        '上次播放到',
        (v != null && v.lastPosition > 0)
            ? _fmtDuration(Duration(milliseconds: v.lastPosition.toInt()))
            : '从头开始',
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
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GlassTheme.radiusXl),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          // 用 bottomSheetInset 而不是 viewPadding：Android 8/9 上
          // viewPadding.bottom 为 0，弹窗底部按钮会被导航栏压住
          28 + SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '视频详情',
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              // 刮削到的影片信息（海报/年份/评分/简介）+ 手动匹配入口。
              // 之前刮削结果没有任何界面展示，用户看不到匹配结果。
              ScrapeInfoSection(
                videoPath: widget.videoPath,
                initialQuery: MediaNamer.parse(widget.videoPath).fullTitle,
              ),
              const SizedBox(height: 6),
              ...rows.map(
                (r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Text(
                          r[0],
                          style: const TextStyle(
                            color: GlassTheme.textTertiary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          r[1],
                          style: const TextStyle(
                            color: GlassTheme.textPrimary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GlassTheme.radiusXl),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '字幕',
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '点右侧 ⇅ 可把字幕设为「第二字幕」，与主字幕同屏显示（如中英对照）',
                style: TextStyle(
                  color: GlassTheme.textTertiary.withOpacity(0.95),
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),

              // 关闭字幕
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.subtitles_off_rounded,
                  size: 20,
                  color: GlassTheme.textSecondary,
                ),
                title: const Text(
                  '关闭字幕',
                  style: TextStyle(color: GlassTheme.textPrimary, fontSize: 14),
                ),
                trailing:
                    (st.activeSubtitle == null && st.activeTrackId == null)
                        ? const Icon(
                            Icons.check_rounded,
                            color: GlassTheme.accentPurple,
                            size: 18,
                          )
                        : null,
                onTap: () {
                  notifier.disableSubtitles();
                  Navigator.pop(ctx);
                },
              ),

              // 关闭第二字幕（设置了才显示）
              if (st.secondaryTrackId != null || st.secondarySubtitle != null)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.vertical_split_rounded,
                    size: 20,
                    color: GlassTheme.accentTeal,
                  ),
                  title: const Text(
                    '关闭第二字幕',
                    style: TextStyle(
                      color: GlassTheme.accentTeal,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: Text(
                    st.secondarySubtitle?.title ?? '内嵌字幕轨',
                    style: const TextStyle(
                      color: GlassTheme.textTertiary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    notifier.clearSecondarySubtitle();
                    Navigator.pop(ctx);
                  },
                ),

              // 内嵌字幕
              _subSectionHeader('内嵌字幕 (${st.embeddedSubtitles.length})'),
              if (st.embeddedSubtitles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    '该视频没有内嵌字幕',
                    style: TextStyle(
                      color: GlassTheme.textTertiary,
                      fontSize: 12,
                    ),
                  ),
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
                    leading: const Icon(
                      Icons.closed_caption_rounded,
                      size: 20,
                      color: GlassTheme.accentTeal,
                    ),
                    title: Text(
                      label,
                      style: TextStyle(
                        color: isActive
                            ? GlassTheme.accentPurple
                            : GlassTheme.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: extra.isEmpty
                        ? null
                        : Text(
                            extra,
                            style: const TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                    trailing: _subTrailing(
                      isPrimary: isActive,
                      isSecondary: st.secondaryTrackId == t.id,
                      onSecondary: () {
                        notifier.setSecondaryEmbedded(t);
                        Navigator.pop(ctx);
                      },
                    ),
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
                    leading: const Icon(
                      Icons.description_rounded,
                      size: 20,
                      color: GlassTheme.accentPurple,
                    ),
                    title: Text(
                      s.title,
                      style: TextStyle(
                        color: isActive
                            ? GlassTheme.accentPurple
                            : GlassTheme.textPrimary,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _subTrailing(
                      isPrimary: isActive,
                      isSecondary: st.secondarySubtitle?.path == s.path,
                      onSecondary: () {
                        notifier.setSecondaryExternal(s);
                        Navigator.pop(ctx);
                      },
                    ),
                    onTap: () {
                      notifier.loadExternalSubtitle(
                        s.path,
                        language: s.language,
                        title: s.title,
                      );
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
                      st.currentVideo?.path ?? widget.videoPath,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 音轨切换面板：多音轨时点按钮弹出。
  void _showAudioTrackSheet() {
    final st = ref.read(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final tracks = st.audioTracks;
    if (tracks.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.6,
        ),
        decoration: const BoxDecoration(
          color: Color(0xF2FFFFFF),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GlassTheme.radiusXl),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '音轨',
              style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${tracks.length} 条音轨，点选即切换',
              style: TextStyle(
                color: GlassTheme.textTertiary.withValues(alpha: 0.95),
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in tracks) _audioTrackTile(t, st, notifier),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _audioTrackTile(
    AudioTrack t,
    PlayerState st,
    PlayerNotifier notifier,
  ) {
    final isActive = st.activeAudioTrackId == t.id ||
        (st.activeAudioTrackId == null && (t.isDefault ?? false));

    final desc = _audioTrackSingleDesc(t);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isActive
            ? GlassTheme.accentPurple.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
        border: Border.all(
          color: isActive
              ? GlassTheme.accentPurple.withValues(alpha: 0.4)
              : Colors.black.withValues(alpha: 0.06),
          width: 0.8,
        ),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          Icons.audiotrack_rounded,
          size: 20,
          color: isActive ? GlassTheme.accentPurple : GlassTheme.textTertiary,
        ),
        title: Text(
          t.title?.isNotEmpty == true
              ? t.title!
              : (t.language?.isNotEmpty == true ? t.language! : '音轨'),
          style: TextStyle(
            color: GlassTheme.textPrimary,
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        subtitle: desc.isNotEmpty
            ? Text(desc,
                style: const TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 11))
            : null,
        trailing: isActive
            ? const Icon(Icons.check_rounded,
                color: GlassTheme.accentPurple, size: 20)
            : null,
        onTap: () {
          Navigator.pop(context);
          notifier.selectAudioTrack(t);
        },
      ),
    );
  }

  String _audioTrackSingleDesc(AudioTrack t) {
    final parts = <String>[
      if (t.codec?.isNotEmpty == true) t.codec!,
      if (t.channelscount != null && t.channelscount! > 0)
        '${t.channelscount}声道',
      if (t.samplerate != null && t.samplerate! > 0)
        '${(t.samplerate! / 1000).toStringAsFixed(1)}kHz',
    ];
    return parts.join(' · ');
  }

  /// 字幕行的尾部操作：设为主字幕状态 + 设为第二字幕按钮
  Widget? _subTrailing({
    required bool isPrimary,
    required bool isSecondary,
    required VoidCallback onSecondary,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '设为第二字幕（可与主字幕同屏）',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.vertical_split_rounded,
            size: 20,
            color:
                isSecondary ? GlassTheme.accentTeal : GlassTheme.textTertiary,
          ),
          onPressed: onSecondary,
        ),
        if (isPrimary)
          const Icon(
            Icons.check_rounded,
            color: GlassTheme.accentPurple,
            size: 18,
          ),
      ],
    );
  }

  Widget _subSectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: GlassTheme.textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
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
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GlassTheme.radiusXl),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          24 + SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '选择字幕文件',
              style: TextStyle(
                color: GlassTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
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
                      height: 1.6,
                    ),
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
                      leading: const Icon(
                        Icons.subtitles_rounded,
                        size: 20,
                        color: GlassTheme.accentPurple,
                      ),
                      title: Text(
                        f.title,
                        style: const TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        f.path,
                        style: const TextStyle(
                          color: GlassTheme.textTertiary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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

  Widget _buildGlassBottomControls(
    BuildContext context,
    PlayerState state, {
    double scale = 1.0,
  }) {
    return Positioned(
      // 整块再往下挪一点（用户反馈「还是太高」）。
      //
      // 这里只吃掉原来底部 padding 里的 +8 余量：把 padding 的 +8 去掉，
      // 同时用负 bottom 让容器向下探 12px，净下移 12px。
      //
      // 安全区仍是 MediaQuery.padding.bottom（全面屏约 34px），
      // 内容不会压到 Home Indicator / 手势条上。
      bottom: -12,
      left: 0,
      right: 0,
      child: ClipRect(
        child: SafeBackdropFilter(
          blurSigma: 18,
          child: Container(
            padding: EdgeInsets.only(
              // 原来的 +8 余量让位给上面的 -12 下移
              bottom: MediaQuery.of(context).padding.bottom,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
              ),
            ),
            child: _LivePosition(
              builder: (context, live) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 进度条
                  //
                  // 关键：拖动期间**不回灌 value**。
                  // GlassSlider 内部已有 `_dragValue` 跟手渲染；如果外层再把
                  // `_seekPreviewMs` 的变化推回 `value`，就会形成
                  //   onPanUpdate → setState → onChanged → valueListenable 变化
                  //   → ValueListenableBuilder 重建 → 再 setState …
                  // 的每帧双重重建，滑条就会发涩。
                  //
                  // 做法：传入的 value 只在**未拖动**时跟随真实播放位置；
                  // 拖动中传 null，让 GlassSlider 完全由内部 _dragValue 驱动。
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16 * scale),
                    child: ValueListenableBuilder<double?>(
                      valueListenable: _seekPreviewMs,
                      builder: (context, seekPreview, _) {
                        return GlassSlider(
                          value: seekPreview ??
                              live.position.inMilliseconds.toDouble(),
                          min: 0,
                          max: live.duration.inMilliseconds.toDouble(),
                          activeColor: GlassTheme.accentPink,
                          height: 3,
                          showThumb: true,
                          onChanged: (v) => _onSeekPreview(v.round()),
                          onChangeEnd: (v) {
                            _onSeekCommit(v.round());
                          },
                          onDragStart: _onSliderDragStart,
                          onDragEnd: _onSliderDragEnd,
                        );
                      },
                    ),
                  ),
                  SizedBox(height: 2 * scale),
                  // 时间行：从 _LivePosition 实时取，不用 ValueListenableBuilder
                  // 否则非拖动时位置文字冻结在最后一次 rebuild 的值上
                  if (live.duration > Duration.zero)
                    Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 20 * scale),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          // 拖动中显示粉色预览时间，否则白色实时位置
                          ValueListenableBuilder<double?>(
                            valueListenable: _seekPreviewMs,
                            builder: (_, pv, __) {
                              final showMs = pv ?? live.position
                                  .inMilliseconds.toDouble();
                              return Text(
                                _fmtDuration(Duration(
                                    milliseconds: showMs.round())),
                                style: TextStyle(
                                  color: pv != null
                                      ? GlassTheme.accentPink
                                      : Colors.white70,
                                  // 字号设下限 10px：横屏 scale=0.85 时
                                  // 11*0.85=9.35 偏小，钳到 10 保证可读
                                  fontSize: (11 * scale).clamp(10.0, 14.0),
                                  // 行高压到 1.0：默认字体行高约 1.2~1.4，
                                  // 会额外撑出 3~5px 空白，让时间行显得"太高"
                                  height: 1.0,
                                  fontWeight: pv != null
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              );
                            },
                          ),
                          Text(
                            _fmtDuration(live.duration),
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: (11 * scale).clamp(10.0, 14.0),
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  SizedBox(height: 4 * scale),
                  // 按钮行
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // 倍速（label 显示当前值，让用户一眼知道选了什么）
                        GlassButton(
                          label: _fmtSpeed(state.speed),
                          compact: true,
                          foregroundColor: Colors.white,
                          onTap: () => setState(
                            () => _showSpeedSelector = !_showSpeedSelector,
                          ),
                        ),
                        // 字幕（内嵌 / 外挂 / 手动添加）
                        GlassButton(
                          icon: Icons.subtitles_rounded,
                          compact: true,
                          foregroundColor: Colors.white,
                          onTap: _showSubtitleSheet,
                        ),
                        // 音轨切换：仅多音轨时显示（单轨没得切，不占位置）
                        if (state.audioTracks.length > 1)
                          GlassButton(
                            icon: Icons.audiotrack_rounded,
                            compact: true,
                            foregroundColor: Colors.white,
                            onTap: _showAudioTrackSheet,
                          ),
                        GlassButton(
                          icon: Icons.skip_previous_rounded,
                          compact: true,
                          foregroundColor: Colors.white,
                          onTap: () =>
                              ref.read(playerProvider.notifier).playPrevious(),
                        ),
                        GlassButton(
                          icon: state.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          compact: true,
                          foregroundColor: Colors.white,
                          onTap: () => ref
                              .read(playerProvider.notifier)
                              .togglePlayPause(),
                        ),
                        GlassButton(
                          icon: Icons.skip_next_rounded,
                          compact: true,
                          foregroundColor: Colors.white,
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
      ),
    );
  }

  Widget _buildCenterPlayButton(PlayerState state, {double scale = 1.0}) {
    return Center(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: state.isPlaying ? 0 : 1,
          // 只要一个干净的白色三角，不要毛玻璃底 —— 带背景压在画面上很突兀
          child: Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            size: (76 * scale).clamp(56, 96),
            shadows: const [
              Shadow(color: Colors.black54, blurRadius: 12),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════ 弹出面板 ═══════════════

  Widget _buildPopupMenus(BuildContext context, PlayerState state) {
    final isLarge = AppBreakpoints.isLargeScreen(context);
    return Stack(
      children: [
        if (_showSpeedSelector)
          // 倍速选择面板：右下角浮层，深色毛玻璃，适配横屏/平板。
          // 用 Align + Padding（而非写死坐标），底部间距随控制栏高度/屏幕尺寸自适应。
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              // 底部留出控制栏空间：手机/平板分别给不同间距，避免与控制栏重叠
              padding: EdgeInsets.only(
                right: isLarge ? 32 : 20,
                bottom: isLarge ? 200 : 170,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isLarge ? 360 : 260,
                ),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.15),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 标题 + 当前倍速
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.speed_rounded,
                                size: 18, color: Colors.white70),
                            const SizedBox(width: 6),
                            Text(
                              '播放速度',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: isLarge ? 15 : 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _fmtSpeed(state.speed),
                              style: TextStyle(
                                color: GlassTheme.accentTeal,
                                fontSize: isLarge ? 15 : 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 倍速选项
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: AppConstants.playbackSpeeds.map((s) {
                          final isActive = state.speed == s;
                          return GestureDetector(
                            onTap: () {
                              ref.read(playerProvider.notifier).setSpeed(s);
                              setState(() => _showSpeedSelector = false);
                            },
                            child: Container(
                              width: isLarge ? 64 : 56,
                              height: isLarge ? 42 : 38,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isActive
                                    ? GlassTheme.accentTeal.withOpacity(0.85)
                                    : Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: isActive
                                    ? null
                                    : Border.all(
                                        color: Colors.white.withOpacity(0.2),
                                        width: 1,
                                      ),
                              ),
                              child: Text(
                                _fmtSpeed(s),
                                style: TextStyle(
                                  color:
                                      isActive ? Colors.white : Colors.white70,
                                  fontSize: isLarge ? 14 : 13,
                                  fontWeight: isActive
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // 面板打开时，点其它区域关闭（透明遮罩）
        if (_showSpeedSelector)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _showSpeedSelector = false),
              behavior: HitTestBehavior.translucent,
            ),
          ),
      ],
    );
  }

  // ═══════════════ Video Layer ═══════════════

  Widget _buildVideoLayer(PlayerState state, {bool rounded = true}) {
    final video = Video(
      controller: _videoController,
      fit: BoxFit.contain,
      controls: NoVideoControls,
      // 关闭 media_kit 内置的 Flutter 字幕层（SubtitleView）。
      //
      // 这是「字幕显示两个」的根因：SubtitleView 由
      // subtitleViewConfiguration.visible 控制，**默认 true**，
      // 和 mpv 的 libass 是两套独立的绘制路径。
      // 只关 mpv 的 sub-visibility 不够，SubtitleView 仍会画一份，
      // 叠加上本项目自绘的字幕浮层就是双字幕。
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        visible: false,
      ),
    );

    // 视频纹理层单独包 RepaintBoundary：控制栏/字幕/进度条等上层重建时，
    // 不会连带重绘视频纹理（media_kit 的 Video 是每帧推送的外接纹理，
    // 被上层重建连带触发合成是播放卡顿的常见来源）。
    final bounded = RepaintBoundary(child: video);

    // 播放页全屏沉浸：不做圆角裁剪（ClipRRect 会让视频纹理每帧都被
    // 裁剪重绘）。只有 mini player 等需要圆角的场景才裁剪。
    if (!rounded) return Positioned.fill(child: bounded);
    return Positioned.fill(
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(GlassTheme.radiusLg),
          topRight: Radius.circular(GlassTheme.radiusLg),
        ),
        child: bounded,
      ),
    );
  }

  void _enterPiP() async {
    final ok = await NativeBridgeService.instance.enterPiP();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前设备/系统不支持小窗播放'),
          duration: Duration(seconds: 2),
        ),
      );
    }
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

  /// 倍速显示：1.0 → "1x"，1.5 → "1.5x"，2.0 → "2x"
  String _fmtSpeed(double speed) {
    if (speed == speed.roundToDouble()) {
      return '${speed.toInt()}x';
    }
    return '${speed}x';
  }

  /// 帧率显示：整数去掉 .0，如 60 → "60 fps"，23.976 → "23.98 fps"
  String _fmtFps(double fps) {
    if (fps == fps.roundToDouble()) {
      return '${fps.toInt()} fps';
    }
    return '${fps.toStringAsFixed(2)} fps';
  }

  /// HDR 标签：把 mpv 的 primaries/transfer 翻译成可读名称
  String _hdrLabel(String primaries, String? transfer) {
    final tf = (transfer ?? '').toLowerCase();
    final cp = primaries.toLowerCase();
    if (tf.contains('pq')) return 'PQ (HDR10)';
    if (tf.contains('hlg')) return 'HLG';
    if (cp.contains('2020')) return 'BT.2020 色域';
    if (cp.contains('709')) return 'BT.709 (SDR)';
    return primaries;
  }

  /// 角标文案：杜比视界 > HDR10 > HLG，SDR 返回 null（不显示角标）。
  String? _hdrBadgeText(PlayerState state) {
    if (state.dolbyVision) return '杜比视界';
    final t = state.hdrType;
    if (t == 'HDR10') return 'HDR10';
    if (t == 'HLG') return 'HLG';
    return null;
  }

  /// HDR / 杜比视界角标（顶栏文件名旁）。
  ///
  /// 统一白色小字 + 半透明黑底，低调不遮挡画面。
  Widget _buildHdrBadge(PlayerState state) {
    final label = _hdrBadgeText(state);
    if (label == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
          height: 1.1,
        ),
      ),
    );
  }
}

// ═══════════════ 投屏设备面板（播放页内） ═══════════════
//
// 用轮询 + mounted 保护读取 castProvider：
// 直接在弹窗里 watch 会在弹窗关闭瞬间对已卸载的元素触发重建断言。

/// 只订阅「播放位置 / 时长」的小部件
///
/// 播放中位置每秒更新多次，如果让整页 watch playerProvider，
/// 视频层、控制层、字幕层都会跟着重建（发热 + 掉帧）。
/// 把需要实时位置的节点拆到这里，重建范围就只剩进度条/时间文字。
class _LivePosition extends ConsumerWidget {
  final Widget Function(BuildContext context, PlayerState live) builder;
  const _LivePosition({required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 记录类型按值比较：位置或时长变化才会触发重建
    ref.watch(
      playerProvider.select(
        (p) => (p.position.inMilliseconds, p.duration.inMilliseconds),
      ),
    );
    return builder(context, ref.read(playerProvider));
  }
}

/// 只订阅「当前字幕行 + 第二字幕命中下标」的字幕浮层包装。
///
/// 主字幕文本来自 `currentSubtitleLines`；第二字幕文本来自
/// `secondarySubtitleLines`（内嵌第二字幕，mpv 文本）或 `secondaryEntries`
/// 的命中下标（外挂第二字幕）。三者都订阅，保证任一变化都触发重建。
class _LiveSubtitle extends ConsumerWidget {
  final Widget Function(BuildContext context, PlayerState live) builder;
  const _LiveSubtitle({required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(
      playerProvider.select(
        (p) => (
          p.activeSubtitleIndex,
          p.secondarySubtitleIndex,
          // 按「对象身份」比较（List 未重写 ==），换文件会重建
          p.secondaryEntries,
          // 主字幕文本：mpv sub-text 每次推送新 List，这里直接比较内容
          p.currentSubtitleLines,
          // 内嵌第二字幕文本：mpv secondary-sub-text
          p.secondarySubtitleLines,
        ),
      ),
    );
    return builder(context, ref.read(playerProvider));
  }
}

class _CastDeviceSheet extends ConsumerStatefulWidget {
  const _CastDeviceSheet();

  @override
  ConsumerState<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends ConsumerState<_CastDeviceSheet> {
  late CastState _castState;
  Timer? _timer;

  /// 手动添加投屏设备：填 IP[:端口]，自动探测常见设备描述路径
  Future<void> _showManualCastDialog() async {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '');
    final result = await showDialog<bool>(
      context: context,
      // 两个输入框 + 说明文字，键盘弹出后在小屏上会被顶出屏幕，
      // 收到 insetPadding 并让内容可滚动。
      builder: (ctx) => AlertDialog(
        backgroundColor: GlassTheme.bg,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: const Text(
          '手动添加投屏设备',
          style: TextStyle(color: GlassTheme.textPrimary, fontSize: 17),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                style: const TextStyle(color: GlassTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '设备 IP',
                  hintText: '例如 192.168.1.20',
                  hintStyle: TextStyle(color: GlassTheme.textTertiary),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: GlassTheme.textPrimary),
                decoration: const InputDecoration(
                  labelText: '端口（可留空，默认 80/1400）',
                  hintStyle: TextStyle(color: GlassTheme.textTertiary),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '会依次尝试 /description.xml、/dmr.xml、/rootDesc.xml',
                style: TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              '取消',
              style: TextStyle(color: GlassTheme.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '添加并投屏',
              style: TextStyle(color: GlassTheme.accentTeal),
            ),
          ),
        ],
      ),
    );

    if (result != true) return;
    final host = hostCtrl.text.trim();
    if (host.isEmpty) return;
    final port = int.tryParse(portCtrl.text.trim());

    const paths = ['/description.xml', '/dmr.xml', '/rootDesc.xml', '/'];
    final ports = port != null ? [port] : <int>[80, 1400, 8080];

    final castNotifier = ref.read(castProvider.notifier);
    for (final p in ports) {
      for (final path in paths) {
        final location = 'http://$host:$p$path';
        final device = CastDevice(
          id: 'manual:$location',
          name: '$host:$p',
          protocol: CastProtocol.dlna,
          host: host,
          port: p,
          location: location,
          lastSeen: DateTime.now(),
          supportsVideo: true,
        );
        await castNotifier.connect(device);
        if (!mounted) return;
        final st = ref.read(castProvider);
        if (st.isConnected) {
          await _castCurrentTo(device.name);
          return;
        }
      }
    }
    if (mounted) {
      final st = ref.read(castProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(st.errorMessage ?? '未找到可用的投屏服务，请检查 IP')),
      );
    }
  }

  /// 把当前播放的文件投到已连接设备
  Future<void> _castCurrentTo(String deviceName) async {
    final messenger = ScaffoldMessenger.of(context);
    final castNotifier = ref.read(castProvider.notifier);
    final path = ref.read(playerProvider).currentVideo?.path;
    if (path == null || path.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('已连接，未找到可投的视频')));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('正在投屏到 $deviceName…')));
    final ok = await castNotifier.castLocalFile(path, title: deviceName);
    if (!mounted) return;
    // 投屏成功后必须**停掉本地播放**：
    // 否则手机扬声器 + 电视同时出声、且两条播放进度各自走，
    // 用户听到的是错位的双声道。
    if (ok && ref.read(playerProvider).isPlaying) {
      try {
        await ref.read(playerProvider.notifier).togglePlayPause();
      } catch (_) {}
      if (!mounted) return;
    }
    final after = ref.read(castProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '已投屏到 $deviceName' : (after.errorMessage ?? '投屏失败')),
      ),
    );
  }

  /// 连接某台设备并投当前视频
  Future<void> _castToDevice(CastDevice d) async {
    final messenger = ScaffoldMessenger.of(context);
    final castNotifier = ref.read(castProvider.notifier);
    await castNotifier.connect(d);
    if (!mounted) return;
    final st = ref.read(castProvider);
    if (!st.isConnected) {
      messenger.showSnackBar(
        SnackBar(content: Text(st.errorMessage ?? '连接失败')),
      );
      return;
    }
    await _castCurrentTo(d.name);
  }

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
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(GlassTheme.radiusXl),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        28 + SystemUiPolicy.bottomSheetInset(MediaQuery.of(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '投屏到设备',
                style: TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_castState.isDiscovering)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GlassTheme.accentPurple,
                  ),
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
              leading: const Icon(
                Icons.cast_connected_rounded,
                color: GlassTheme.accentTeal,
              ),
              title: Text(
                '已连接：${_castState.activeDevice!.name}',
                style: const TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 14,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 投屏遥控面板（连上后可控制电视端播放/音量）
                  TextButton(
                    onPressed: () {
                      final router = GoRouter.of(context);
                      Navigator.pop(context);
                      router.pushNamed('cast');
                    },
                    child: const Text(
                      '控制',
                      style: TextStyle(color: GlassTheme.accentPurple),
                    ),
                  ),
                  TextButton(
                    onPressed: notifier.disconnect,
                    child: const Text(
                      '断开',
                      style: TextStyle(color: GlassTheme.accentPink),
                    ),
                  ),
                ],
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
                          strokeWidth: 3,
                          color: GlassTheme.accentPurple,
                        ),
                      )
                    else
                      const Icon(
                        Icons.cast_rounded,
                        size: 40,
                        color: GlassTheme.textTertiary,
                      ),
                    const SizedBox(height: 10),
                    Text(
                      _castState.isDiscovering ? '正在搜索设备…' : '未发现投屏设备',
                      style: const TextStyle(
                        color: GlassTheme.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '请确保设备与手机在同一 Wi-Fi',
                      style: TextStyle(
                        color: GlassTheme.textTertiary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 有些路由器会屏蔽 SSDP 组播，允许手动填 IP
                    GlassButton.outlined(
                      icon: Icons.add_rounded,
                      label: '手动添加设备',
                      height: 38,
                      foregroundColor: GlassTheme.accentPurple,
                      onTap: () => _showManualCastDialog(),
                    ),
                  ],
                ),
              ),
            )
          else
            ..._castState.devices.map(
              (d) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  d.protocol == CastProtocol.chromecast
                      ? Icons.cast_rounded
                      : Icons.tv_rounded,
                  color: GlassTheme.accentPurple,
                ),
                title: Text(
                  d.name,
                  style: const TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  d.host.isNotEmpty ? d.host : d.protocol.name,
                  style: const TextStyle(
                    color: GlassTheme.textTertiary,
                    fontSize: 12,
                  ),
                ),
                trailing: d.status == CastDeviceStatus.connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: GlassTheme.accentPurple,
                        ),
                      )
                    : const Icon(
                        Icons.chevron_right_rounded,
                        color: GlassTheme.textTertiary,
                      ),
                // 连接成功后立刻把当前视频投过去（本地文件通过内置
                // HTTP 服务暴露成局域网地址，电视才能读到）
                onTap: () => _castToDevice(d),
              ),
            ),
        ],
      ),
    );
  }
}
