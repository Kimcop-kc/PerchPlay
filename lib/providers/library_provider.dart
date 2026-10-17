import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/database_service.dart';
import '../services/library_prune_service.dart';
import '../services/thumbnail_service.dart';
import '../services/video_scanner_service.dart';
import 'playlist_provider.dart';
import 'scrape_provider.dart';

// 视频列表
final videoListProvider =
    AsyncNotifierProvider<VideoListNotifier, List<VideoModel>>(
  VideoListNotifier.new,
);

class VideoListNotifier extends AsyncNotifier<List<VideoModel>> {
  final _scanner = VideoScannerService();
  final _db = DatabaseService.instance;
  final _thumbService = ThumbnailService();

  /// 正在后台生成缩略图的视频 id：同一个视频不会被排队生成两次
  /// （扫描可以被手动刷新多次触发，不挡的话会重复解码同一批文件）
  final Set<String> _thumbInFlight = <String>{};

  /// 已经生成好、但还没刷给界面的缩略图（id → 路径）
  final Map<String, String> _thumbPending = <String, String>{};

  /// 合并刷新的计时器
  Timer? _thumbFlushTimer;

  /// 一批缩略图最多攒这么久就刷一次界面
  static const _thumbFlushDelay = Duration(milliseconds: 300);

  /// 攒够这么多张就立刻刷新，不等计时器
  static const _thumbFlushBatch = 4;

  /// 后台生成缩略图的并发数
  ///
  /// 解码是原生调用、吃 CPU：串行要等 N 次，开太多又会和滚动/首帧抢资源，
  /// 3 个是"进度看得见又不卡"的折中。
  static const _thumbConcurrency = 3;

  /// Provider 已销毁：后台任务不能再写 state（会抛 StateError）
  bool _disposed = false;

  @override
  Future<List<VideoModel>> build() async {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _thumbFlushTimer?.cancel();
      _thumbFlushTimer = null;
      _thumbPending.clear();
      _thumbInFlight.clear();
    });
    // 先返回数据库中的缓存
    final cached = await _db.getAllVideos();
    if (cached.isNotEmpty) return cached;
    return [];
  }

  Future<void> scan() async {
    state = const AsyncLoading();
    try {
      // 首选 MediaStore 索引：毫秒级出结果，且自带时长
      final viaMediaStore = await _scanner.scanViaMediaStore();
      final videos =
          viaMediaStore ?? await _scanner.scanCommonDirectories();

      // ── 列表先出 ──
      // 扫描器内部已经把结果写库（并保留了进度/收藏/缩略图），这里读回来
      // **立刻**交给 UI。
      // 以前是在这里对每个视频顺序 await 生成缩略图，N 个视频就串行等 N 次
      // 原生解码，进首页要等十几秒；现在缩略图交给 [_backfillThumbnails]
      // 在后台补，卡片先显示「灰底 + 影片图标」占位（见 CoverThumb/_localThumb）。
      state = AsyncData(await _db.getAllVideos());

      // 缩略图后台补：不 await，别挡住下面的分组与刮削
      unawaited(_backfillThumbnails());

      // 扫描完成后按文件名自动分组（剧集列表）
      if (videos.isNotEmpty) {
        await ref
            .read(playlistListProvider.notifier)
            .syncAutoPlaylists(videos);
      }
      // 后台自动刮削（不阻塞 UI，逐个处理）
      // 注意：状态要从 provider 读，不能读 notifier 的 .state
      // （那是 StateNotifier 的 protected 成员，analyze 会报 warning → CI 挂）
      if (ref.read(scrapeProvider).isEnabled) {
        final paths = videos.map((v) => v.path).toList();
        // 不 await：刮削在后台慢慢跑
        ref.read(scrapeProvider.notifier).scrapeBatch(paths);
      }
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// 后台补齐缩略图，每完成一小批就刷新一次 provider
  ///
  /// 生成一张要原生解码一帧（几十~几百毫秒）。串行等完整个影库才显示列表，
  /// 用户看到的就是首页长时间空白/转圈，所以改成「列表先出、缩略图后补」。
  Future<void> _backfillThumbnails() async {
    // x86_64 模拟器上 flutter_video_thumbnail_plus 的 native 解码会
    // SIGILL/SIGABRT 崩溃（无法用 try-catch 捕获），故 debug 构建跳过，
    // 卡片回退显示默认图标。
    if (kDebugMode) return;
    final videos = state.valueOrNull;
    if (videos == null || videos.isEmpty) return;

    // 已有缩略图路径且文件还在的 → 直接复用，不再解码
    final todo = <VideoModel>[
      for (final v in videos)
        if (!ThumbnailService.isUsable(v.thumbnailPath) &&
            !_thumbInFlight.contains(v.id))
          v,
    ];
    if (todo.isEmpty) return;
    for (final v in todo) {
      _thumbInFlight.add(v.id);
    }

    // 有限并发：多个 worker 抢同一个游标，谁空谁取下一个
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < todo.length) {
        if (_disposed) return;
        final video = todo[cursor++];
        try {
          final thumbPath = await _thumbService.generate(video.path);
          if (thumbPath != null) _enqueueThumb(video.id, thumbPath);
        } catch (e) {
          debugPrint('[Thumbnail] 生成失败 ${video.name}: $e');
        } finally {
          _thumbInFlight.remove(video.id);
        }
      }
    }

    final workers = <Future<void>>[];
    final count =
        todo.length < _thumbConcurrency ? todo.length : _thumbConcurrency;
    for (var i = 0; i < count; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    // 收尾：把最后不足一批的结果也刷出去
    await _flushThumbs();
  }

  /// 攒批刷新
  ///
  /// 每生成一张就 `state = ...` 会让首页每秒重建几十次（整个网格 +
  /// 图片解码全部重来）。所以攒够 [_thumbFlushBatch] 张，或者过了
  /// [_thumbFlushDelay]，才真正刷新一次。
  void _enqueueThumb(String videoId, String thumbPath) {
    if (_disposed) return;
    _thumbPending[videoId] = thumbPath;
    if (_thumbPending.length >= _thumbFlushBatch) {
      _thumbFlushTimer?.cancel();
      _thumbFlushTimer = null;
      unawaited(_flushThumbs());
      return;
    }
    _thumbFlushTimer ??= Timer(_thumbFlushDelay, () {
      _thumbFlushTimer = null;
      unawaited(_flushThumbs());
    });
  }

  Future<void> _flushThumbs() async {
    _thumbFlushTimer?.cancel();
    _thumbFlushTimer = null;
    if (_thumbPending.isEmpty || _disposed) return;
    final batch = Map<String, String>.from(_thumbPending);
    _thumbPending.clear();

    final current = state.valueOrNull;
    if (current == null) {
      // 列表正在重新加载（AsyncLoading）：这次先不刷，
      // 等这一轮扫描后的 _backfillThumbnails 再处理，别把结果塞到别人的 state 上
      _thumbPending.addAll(batch);
      return;
    }

    final updated = <VideoModel>[];
    for (final v in current) {
      final thumbPath = batch[v.id];
      updated.add(
        thumbPath == null ? v : v.copyWith(thumbnailPath: thumbPath),
      );
    }
    state = AsyncData(updated);
    // 落库：下次启动直接复用，不用再解码一遍
    try {
      await _db.updateThumbnailPaths(batch);
    } catch (e) {
      // 写库失败不影响界面：缩略图文件还在，下一轮扫描会重新判定并落库
      debugPrint('[Thumbnail] 缩略图路径落库失败: $e');
    }
  }

  Future<void> toggleFavorite(String videoId) async {
    final videos = state.value ?? await _db.getAllVideos();
    final idx = videos.indexWhere((v) => v.id == videoId);
    if (idx == -1) return;
    final video = videos[idx];
    final updated = video.copyWith(isFavorite: !video.isFavorite);
    await _db.insertVideos([updated]);
    state = AsyncData(await _db.getAllVideos());
  }

  /// 删除视频（仅移除影库记录，不删磁盘文件）
  ///
  /// 必须**先改内存列表**：首页整块靠 provider 的列表渲染，只删数据库记录的话
  /// 界面要等下一次重新读库才变（旧的实现就是这样），用户看到的就是
  /// 「点移除后视频还在」。所以这里先把 id 从 state 里摘掉，再落库。
  Future<void> deleteVideo(String videoId) async {
    final current = state.valueOrNull;
    if (current == null) {
      await _db.deleteVideo(videoId);
      state = AsyncData(await _db.getAllVideos());
      return;
    }
    VideoModel? target;
    for (final v in current) {
      if (v.id == videoId) {
        target = v;
        break;
      }
    }
    if (target == null) return; // 已经不在列表里，不重复删

    state = AsyncData([
      for (final v in current)
        if (v.id != videoId) v,
    ]);

    // 刮削缓存（按路径）会跟着记录一起清掉，见 DatabaseService.deleteVideos
    await _db.deleteVideos([videoId], videoPaths: [target.path]);
    // 缩略图文件也没人用了，留着只是占空间
    await _thumbService.deleteThumbnail(target.thumbnailPath);
  }

  /// 剔除「文件已经不在磁盘上」的视频（回前台 / 冷启动时调用），返回剔除数量
  ///
  /// 只做 `existsSync` 的轻量检查，**不触发全盘重新扫描**：扫描要遍历整棵
  /// 目录树（几秒到几十秒），每次切回前台都跑一遍体验是灾难。
  /// 剔除数为 0 时直接返回，不碰 state —— 避免无谓的整页重建。
  Future<int> pruneMissingFiles() async {
    final current = state.valueOrNull;
    if (current == null || current.isEmpty) return 0;

    final missing = LibraryPruneService.findMissing(current);
    if (missing.isEmpty) return 0;

    // 整库都判为"不存在"更像是权限/存储问题（读权限被撤、SD 卡没挂载），
    // 照着删就是清空整个影库。这种情况宁可不动，让用户自己重扫。
    if (missing.length == current.length) {
      debugPrint('[Library] 全部 ${missing.length} 个视频都判为不存在，'
          '疑似权限/存储异常，跳过清理');
      return 0;
    }

    final missingIds = <String>{for (final v in missing) v.id};
    state = AsyncData([
      for (final v in current)
        if (!missingIds.contains(v.id)) v,
    ]);
    // 缩略图文件不删：可能只是外部存储暂时不可用，视频回来时能立刻显示
    await _db.deleteVideos(
      [for (final v in missing) v.id],
      videoPaths: [for (final v in missing) v.path],
    );
    debugPrint('[Library] 已剔除 ${missing.length} 个已不存在的视频');
    return missing.length;
  }
}

// 文件夹列表
final folderListProvider = FutureProvider<List<String>>((ref) async {
  return DatabaseService.instance.getAllFolders();
});

// 向后兼容别名
final libraryProvider = videoListProvider;

// 按文件夹筛选的视频
final folderVideosProvider =
    FutureProvider.family<List<VideoModel>, String>((ref, folderPath) async {
  return DatabaseService.instance.getVideosByFolder(folderPath);
});

// 播放历史
final playHistoryProvider = FutureProvider<List<VideoModel>>((ref) async {
  final db = DatabaseService.instance;
  final history = await db.getPlayHistory();
  // Convert back to VideoModel list
  return history.map((map) => VideoModel.fromJson(map)).toList();
});

// 说明：这里原来还有一个 playPositionProvider，它调用
// DatabaseService.updatePlayPosition —— 那个方法里含 playCount = playCount + 1。
// 它没有任何调用点，属于死代码，且一旦被误用会让播放次数重复累加。
// 进度落盘统一走 PlayerNotifier._persistProgress → saveProgress（不计数）。
