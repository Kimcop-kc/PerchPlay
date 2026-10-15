import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/video_model.dart';
import '../services/video_scanner_service.dart';
import '../services/database_service.dart';
import '../services/thumbnail_service.dart';

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
      final videos = await _scanner.scanCommonDirectories();
      // 生成缩略图并持久化到数据库。
      // 注意：x86_64 模拟器上 flutter_video_thumbnail_plus 的 native 解码会
      // SIGILL/SIGABRT 崩溃（无法用 try-catch 捕获），故模拟器上跳过缩略图，
      // 卡片回退显示默认图标。真机（ARM + GPU）才生成缩略图。
      final thumbnailService = ThumbnailService();
      for (final video in videos) {
        // debug 构建（模拟器/开发机）跳过缩略图生成：
        // flutter_video_thumbnail_plus 的 native 解码在 x86_64 模拟器上
        // 会 SIGILL/SIGABRT 崩溃（无法 try-catch 捕获），卡片回退默认图标。
        if (video.thumbnailPath.isEmpty && !kDebugMode) {
          try {
            final thumbPath = await thumbnailService.generate(video.path);
            if (thumbPath != null) {
              final updated = video.copyWith(thumbnailPath: thumbPath);
              // upsert 保留已有播放进度/收藏
              await _db.upsertScannedVideos([updated]);
            }
          } catch (e) {
            debugPrint('[Thumbnail] 生成失败 ${video.name}: $e');
          }
        }
      }
      state = AsyncData(await _db.getAllVideos());
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

// 播放位置更新
final playPositionProvider =
    FutureProvider.family<void, ({String videoId, double position})>(
  (ref, params) async {
    await DatabaseService.instance
        .updatePlayPosition(params.videoId, params.position);
  },
);
