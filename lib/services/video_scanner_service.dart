import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/video_model.dart';
import '../core/constants/app_constants.dart';
import 'app_settings_service.dart';
import 'database_service.dart';
import 'library_hidden_service.dart';
import 'local_media_import_service.dart';
import 'native_bridge_service.dart';

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
    // 必须先过一遍隐藏名单：写库之后才过滤的话，数据库里会重新长出记录，
    // 下次冷启动读缓存又冒出来（"删了又回来"）。
    final kept = await _dropHiddenVideos(found);
    if (kept.isNotEmpty) {
      await _db.upsertScannedVideos(kept);
    }

    return kept;
  }

  /// 按隐藏名单过滤扫描结果，并清掉命中项可能残留的数据库记录
  ///
  /// 正常流程里「仅从影库移除」已经删过记录了，这里是兜底：万一当时删库
  /// 失败（进程被杀 / 数据库忙），残留记录会让卡片一直挂在首页。
  Future<List<VideoModel>> _dropHiddenVideos(List<VideoModel> found) async {
    if (found.isEmpty) return found;
    await AppSettingsService.instance.ensureLoaded();
    final hidden = AppSettingsService.instance.hiddenVideoPaths;
    if (hidden.isEmpty) return found;

    final split = LibraryHiddenService.split(found, hidden);
    if (split.dropped.isEmpty) return found;

    try {
      await _db.deleteVideos(
        [for (final v in split.dropped) v.id],
        videoPaths: [for (final v in split.dropped) v.path],
      );
    } catch (e) {
      // 删不掉也不影响本次显示：至少界面上不会再出现
      debugPrint('[Scanner] 清理隐藏视频的残留记录失败: $e');
    }
    debugPrint('[Scanner] 跳过 ${split.dropped.length} 个已隐藏的视频');
    return split.kept;
  }

  /// 走系统媒体库索引扫描（首选，毫秒级）
  ///
  /// 相比逐目录遍历：不用 stat 每个文件、不用探测时长，
  /// 直接拿到 path / size / duration / 修改时间 / 分辨率。
  /// 返回 null 表示媒体库不可用（需回退到文件系统遍历）。
  Future<List<VideoModel>?> scanViaMediaStore({
    bool removeMissing = true,
  }) async {
    if (kIsWeb) return null;
    if (!Platform.isAndroid) return null;
    final rows = await _bridge.queryMediaStoreVideos();
    // 查不到任何记录：可能未授权，交给调用方回退到文件系统遍历
    if (rows.isEmpty) return null;

    final found = <VideoModel>[];
    final existingPaths = <String>[];
    final seen = <String>{};
    for (final row in rows) {
      final path = (row['path'] as String?)?.trim() ?? '';
      if (path.isEmpty) continue;
      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      if (!AppConstants.supportedVideoFormats.contains(ext)) continue;
      if (!seen.add(path)) continue;

      final size = (row['size'] as num?)?.toInt() ?? 0;
      if (size > 0 && size < 20 * 1024) continue; // 过滤碎片文件

      final modifiedMs = (row['dateModified'] as num?)?.toInt() ?? 0;
      final modified = modifiedMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(modifiedMs)
          : DateTime.now();
      final name = (row['name'] as String?)?.trim();
      existingPaths.add(path);
      found.add(VideoModel(
        id: _uuid.v5(Namespace.url.value, path),
        path: path,
        name: (name != null && name.isNotEmpty)
            ? p.basenameWithoutExtension(name)
            : p.basenameWithoutExtension(path),
        folderPath: p.dirname(path),
        size: size,
        // 媒体库直接给了时长，进度条/时长无需等播放才知道
        durationMs: (row['duration'] as num?)?.toInt() ?? 0,
        dateAdded: modified,
        dateModified: modified,
        thumbnailPath: '',
      ));
    }

    if (removeMissing) {
      await _db.removeVideosNotInPaths(existingPaths);
    }
    // 同上：隐藏名单必须在写库之前过滤
    final kept = await _dropHiddenVideos(found);
    if (kept.isNotEmpty) {
      await _db.upsertScannedVideos(kept);
    }
    return kept;
  }

  final _bridge = NativeBridgeService.instance;

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
  /// - Android：直接扫描共享存储根目录（包含 Movies/DCIM/Download/Pictures 等）
  /// - iOS：扫描沙盒 Documents（用户通过「文件」App/iTunes 放入的视频，
  ///   以及本 App 导入/导出的视频都在这里）
  Future<List<VideoModel>> scanCommonDirectories() async {
    if (!kIsWeb && Platform.isIOS) {
      final roots = await LocalMediaImportService.instance.localScanRoots();
      if (roots.isNotEmpty) {
        return scanDirectories(roots, removeMissing: false);
      }
      return [];
    }
    final dirs = <String>[
      '/storage/emulated/0',
    ];
    return scanDirectories(dirs, removeMissing: false);
  }

  /// iOS 综合本地扫描：扫描 Documents + 照片库导出。
  ///
  /// [exportPhotos] 为 true 时，若已授权照片库权限，会把相册视频导出到
  /// Documents/Imported/PhotoLibrary 一并入影库。Android/桌面返回空。
  Future<List<VideoModel>> scanIosLocalSources({
    bool exportPhotos = false,
    void Function(int done, int total)? photoProgress,
  }) async {
    if (kIsWeb || !Platform.isIOS) return const [];

    final found = <VideoModel>[];
    // 1) Documents（含文件共享放入 + 已导入/导出的文件）
    final docsVideos = await scanCommonDirectories();
    found.addAll(docsVideos);

    // 2) 照片库导出（可选）
    if (exportPhotos) {
      final exported = await LocalMediaImportService.instance
          .exportPhotoLibraryVideos(progress: photoProgress);
      if (exported.isNotEmpty) {
        final more = await scanDirectories(exported.map((e) => p.dirname(e)).toSet().toList(),
            removeMissing: false);
        found.addAll(more);
      }
    }
    return found;
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
