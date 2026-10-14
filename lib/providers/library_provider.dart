import 'dart:async';
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
      // 生成缩略图
      final thumbnailService = ThumbnailService();
      for (final video in videos) {
        if (video.thumbnailPath.isEmpty) {
          final thumbPath = await thumbnailService.generate(video.path);
          if (thumbPath != null) {
            // 更新到数据库...
          }
        }
      }
      state = AsyncData(await _db.getAllVideos());
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> toggleFavorite(String videoId) async {
    // favorite logic
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
