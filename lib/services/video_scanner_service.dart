import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/video_model.dart';
import '../core/constants/app_constants.dart';
import 'database_service.dart';
import 'thumbnail_service.dart';

class VideoScannerService {
  final DatabaseService _db = DatabaseService.instance;
  final ThumbnailService _thumbnail = ThumbnailService();
  final _uuid = const Uuid();

  /// 扫描指定目录列表中的所有视频
  Future<List<VideoModel>> scanDirectories(List<String> dirPaths) async {
    final List<VideoModel> found = [];
    final List<String> existingPaths = [];

    for (final dirPath in dirPaths) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;

      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase().replaceAll('.', '');
        if (!AppConstants.supportedVideoFormats.contains(ext)) continue;

        existingPaths.add(entity.path);
        final video = await _fileToModel(entity);
        if (video != null) found.add(video);
      }
    }

    // 清理已删除的视频
    await _db.removeVideosNotInPaths(existingPaths);
    // 保存新扫描结果
    if (found.isNotEmpty) {
      await _db.insertVideos(found);
    }

    return found;
  }

  /// 扫描手机常用视频目录
  Future<List<VideoModel>> scanCommonDirectories() async {
    final dirs = <String>[];
    // Android 常用视频目录
    dirs.add('/storage/emulated/0/Movies');
    dirs.add('/storage/emulated/0/DCIM');
    dirs.add('/storage/emulated/0/Download');
    dirs.add('/storage/emulated/0/Pictures');
    dirs.add('/storage/emulated/0/Android/media');
    // 额外存储
    dirs.add('/storage/emulated/0');

    return scanDirectories(dirs);
  }

  Future<VideoModel?> _fileToModel(File file) async {
    try {
      final stat = await file.stat();
      return VideoModel(
        id: _uuid.v5(Namespace.URL.value, file.path),
        path: file.path,
        name: p.basenameWithoutExtension(file.path),
        folderPath: p.dirname(file.path),
        size: stat.size,
        durationMs: 0, // media_kit 在播放时可获取准确时长
        dateAdded: stat.accessed,
        dateModified: stat.modified,
        thumbnailPath: '',
      );
    } catch (_) {
      return null;
    }
  }
}