import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/video_scanner_service.dart';
import '../services/database_service.dart';
import '../services/thumbnail_service.dart';
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

  @override
  Future<List<VideoModel>> build() async {
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
      // 生成缩略图并持久化。
      //
      // 两个要点：
      // 1) 扫描结果里 thumbnailPath 恒为空（MediaStore/文件系统都不带），
      //    直接遍历它们会导致**每次扫描都重新生成全部缩略图**。
      //    这里改成以数据库为准，只处理「数据库里也没有缩略图」的，
      //    并且缩略图文件已存在时直接复用。
      // 2) 收集完一次性批量写库，而不是每个视频一次全表读 + 一次事务。
      //
      // 注意：x86_64 模拟器上 flutter_video_thumbnail_plus 的 native 解码会
      // SIGILL/SIGABRT 崩溃（无法用 try-catch 捕获），故 debug 构建跳过，
      // 卡片回退显示默认图标。
      if (!kDebugMode) {
        final thumbnailService = ThumbnailService();
        final persisted = {
          for (final v in await _db.getAllVideos()) v.id: v,
        };
        final withThumbs = <VideoModel>[];
        for (final video in videos) {
          final existingThumb = persisted[video.id]?.thumbnailPath ?? '';
          if (existingThumb.isNotEmpty &&
              await File(existingThumb).exists()) {
            continue; // 已经生成过，跳过
          }
          try {
            final thumbPath = await thumbnailService.generate(video.path);
            if (thumbPath != null) {
              withThumbs.add(video.copyWith(thumbnailPath: thumbPath));
            }
          } catch (e) {
            debugPrint('[Thumbnail] 生成失败 ${video.name}: $e');
          }
        }
        if (withThumbs.isNotEmpty) {
          await _db.upsertScannedVideos(withThumbs);
        }
      }
      state = AsyncData(await _db.getAllVideos());
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
  Future<void> deleteVideo(String videoId) async {
    await _db.deleteVideo(videoId);
    state = AsyncData(await _db.getAllVideos());
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
