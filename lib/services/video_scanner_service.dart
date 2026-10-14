import 'dart:io';
import 'package:flutter/foundation.dart';
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
  ///
  /// [dirPaths] 内若存在父子目录重叠，会先去重为最外层目录，避免重复遍历。
  /// [removeMissing] 为 true 时，清理数据库中不在本次扫描范围内的记录；
  /// 调用方必须确保扫描范围与期望保留的范围一致，否则会误删范围外视频。
  Future<List<VideoModel>> scanDirectories(
    List<String> dirPaths, {
    bool removeMissing = true,
  }) async {
    final List<VideoModel> found = [];
    final List<String> existingPaths = [];

    // 去重：去掉被其他目录包含的子目录，避免重复扫描
    final normalized = _dedupeDirs(dirPaths);

    for (final dirPath in normalized) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;

      try {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final ext =
              p.extension(entity.path).toLowerCase().replaceAll('.', '');
          if (!AppConstants.supportedVideoFormats.contains(ext)) continue;

          existingPaths.add(entity.path);
          final video = await _fileToModel(entity);
          if (video != null) found.add(video);
        }
      } catch (e) {
        // 单个目录读取失败不能中断整次扫描，记录日志后跳过
        debugPrint('[Scanner] 跳过无法访问的目录 $dirPath: $e');
      }
    }

    // 清理已删除的视频（仅当调用方明确要求，且范围一致时）
    if (removeMissing) {
      await _db.removeVideosNotInPaths(existingPaths);
    }
    // 保存新扫描结果
    if (found.isNotEmpty) {
      await _db.insertVideos(found);
    }

    return found;
  }

  /// 去掉被其他目录包含的子目录，保留最外层目录
  List<String> dedupeDirsForTest(List<String> dirs) => _dedupeDirs(dirs);

  List<String> _dedupeDirs(List<String> dirs) {
    final normalized = dirs
        .map((d) => p.normalize(d).replaceAll('\\', '/'))
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => a.length.compareTo(b.length));

    final result = <String>[];
    for (final dir in normalized) {
      final isNested = result.any((r) => dir.startsWith('$r/') || dir == r);
      if (!isNested) result.add(dir);
    }
    return result;
  }

  /// 扫描手机常用视频目录
  ///
  /// 只在用户授权后调用；不额外扫描整盘，避免重复遍历子目录。
  Future<List<VideoModel>> scanCommonDirectories() async {
    final dirs = <String>[
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Android/media',
    ];
    return scanDirectories(dirs, removeMissing: false);
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