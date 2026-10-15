import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/video_model.dart';
import '../core/constants/app_constants.dart';
import 'database_service.dart';

class VideoScannerService {
  final DatabaseService _db = DatabaseService.instance;
  final _uuid = const Uuid();

  /// 扫描指定目录列表中的所有视频
  ///
  /// [dirPaths] 内若存在父子目录重叠，会先去重为最外层目录，避免重复遍历。
  /// [removeMissing] 为 true 时，清理数据库中不在本次扫描范围内的记录；
  /// 调用方必须确保扫描范围与期望保留的范围一致，否则会误删范围外视频。
  ///
  /// 递归遍历对每个子目录单独容错：Android 的 Android/data、Android/obb
  /// 等目录无权限，若用 list(recursive: true) 一个异常会中断整条流。
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
      await _scanDirRecursive(dir, found, existingPaths, 0);
    }

    // 清理已删除的视频（仅当调用方明确要求，且范围一致时）
    if (removeMissing) {
      await _db.removeVideosNotInPaths(existingPaths);
    }
    // 保存新扫描结果（保留既有播放进度/收藏/缩略图）
    if (found.isNotEmpty) {
      await _db.upsertScannedVideos(found);
    }

    return found;
  }

  /// 最大递归深度，防止符号链接循环 / 超深层级卡死
  static const _maxDepth = 8;

  Future<void> _scanDirRecursive(
    Directory dir,
    List<VideoModel> found,
    List<String> existingPaths,
    int depth,
  ) async {
    if (depth > _maxDepth) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list().toList();
    } catch (e) {
      // 无权限等异常：跳过该目录，不影响其他目录
      debugPrint('[Scanner] 跳过无法访问的目录 ${dir.path}: $e');
      return;
    }
    for (final entity in entries) {
      if (entity is Directory) {
        // 跳过确定无权限/无意义的系统目录
        final name = p.basename(entity.path);
        if (name == 'Android' && depth == 0) continue;
        await _scanDirRecursive(entity, found, existingPaths, depth + 1);
      } else if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase().replaceAll('.', '');
        if (!AppConstants.supportedVideoFormats.contains(ext)) continue;
        // 过滤损坏/封面缓存等碎片文件（< 20KB 基本不是完整视频）
        try {
          final len = await entity.length();
          if (len < 20 * 1024) continue;
        } catch (_) {
          continue;
        }
        existingPaths.add(entity.path);
        final video = await _fileToModel(entity);
        if (video != null) found.add(video);
      }
    }
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
  /// 直接扫描共享存储根目录（包含 Movies/DCIM/Download/Pictures 等），
  /// 去重后只会保留最外层根目录，避免重复遍历。
  Future<List<VideoModel>> scanCommonDirectories() async {
    final dirs = <String>[
      '/storage/emulated/0',
    ];
    return scanDirectories(dirs, removeMissing: false);
  }

  Future<VideoModel?> _fileToModel(File file) async {
    try {
      final stat = await file.stat();
      return VideoModel(
        id: _uuid.v5(Namespace.url.value, file.path),
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
