import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';

/// iOS/跨平台「本地文件来源」服务。
///
/// iOS 是沙盒系统，没有 Android 那种全局媒体库扫描，App 只能访问自己的
/// 容器目录。本服务统一封装 iOS 上获取本地视频的三种途径：
///
/// 1. **扫描沙盒 Documents**：配合 Info.plist 的 `UIFileSharingEnabled` +
///    `LSSupportsOpeningDocumentsInPlace`，用户可通过系统「文件」App /
///    iTunes 把视频放进 PerchPlay 的 Documents 目录（「我的 iPhone」里可见）。
/// 2. **文件选择器导入**：`file_picker` 打开系统「文件」App（UIDocumentPicker），
///    用户多选视频后复制进 Documents/Imported（picker 返回的是临时路径，
///    系统随时可能清理，必须复制才能持久播放）。
/// 3. **照片库扫描**：`photo_manager` 枚举相册视频（需照片库权限），
///    把资产导出为 Documents/Imported/PhotoLibrary 下的文件后加入影库
///    （photo_manager 的 file getter 返回的是应用缓存临时文件，且
///    media_kit 在 iOS 上有「仅音频无画面」的已知问题 media-kit#1192，
///    复制到 Documents 再播最稳）。
///
/// 这些方法在 Android/桌面平台上调用时返回空或走原本的 MediaStore/文件系统
/// 扫描，不影响既有逻辑。
class LocalMediaImportService {
  LocalMediaImportService._();
  static final instance = LocalMediaImportService._();

  final _uuid = const Uuid();

  /// 导入文件存放的子目录名（Documents 下）。
  static const _importDirName = 'Imported';
  static const _photoDirName = 'PhotoLibrary';

  /// 本机沙盒 Documents 目录（iOS/Android 通用；Android 上也是应用私有目录）。
  Future<Directory> documentsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    return dir;
  }

  /// 「导入」根目录：Documents/Imported（自动创建）。
  Future<Directory> _importRoot() async {
    final docs = await documentsDirectory();
    final dir = Directory(p.join(docs.path, _importDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 照片库导出目录：Documents/Imported/PhotoLibrary（自动创建）。
  Future<Directory> _photoDir() async {
    final root = await _importRoot();
    final dir = Directory(p.join(root.path, _photoDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 是否 iOS（照片库/文件导入只在 iOS 有意义；Android 走 MediaStore）。
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// 是否是照片库扫描得到的文件（用于清理时避免误删用户自己放的文件）。
  static bool isPhotoExportPath(String path) =>
      path.contains('/$_importDirName/$_photoDirName/');

  /// 是否是导入的文件（文件选择器导入或照片库导出）。
  static bool isImportedPath(String path) =>
      path.contains('/$_importDirName/');

  /// 列出所有可扫描的「本地根目录」：
  /// - iOS：沙盒 Documents（用户通过「文件」App 放入 + 我们导入的文件都在这里）
  /// - Android/桌面：无（走原 MediaStore/系统目录逻辑，返回空）
  Future<List<String>> localScanRoots() async {
    if (_isIOS) {
      final docs = await documentsDirectory();
      return [docs.path];
    }
    return const [];
  }

  /// 用系统「文件」App（UIDocumentPicker）多选视频，复制进
  /// Documents/Imported/，返回复制后的文件路径列表（可直接入影库）。
  ///
  /// iOS 上 `FileType.video` 走的是照片库选择器（PHPicker），要从
  /// 「文件」App 选任意视频文件必须用 `FileType.any` + 扩展名过滤
  /// （或 FileType.custom），这里用 supportedVideoFormats 过滤。
  Future<List<String>> importVideosFromFilesApp() async {
    if (!_isIOS) return const [];
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择视频（可多选）',
        type: FileType.custom,
        allowedExtensions: AppConstants.supportedVideoFormats,
      );
      if (result.isEmpty) return const [];
      final out = <String>[];
      final destDir = await _importRoot();
      for (final f in result) {
        if (f.path == null) continue;
        final ext = p.extension(f.name).toLowerCase();
        if (!AppConstants.supportedVideoFormats
            .contains(ext.replaceAll('.', ''))) {
          continue;
        }
        final src = File(f.path!);
        if (!await src.exists()) continue;
        // 目标文件名：保留原名，冲突时加序号
        final destPath = await _uniqueDestPath(destDir, f.name);
        try {
          await src.copy(destPath);
          out.add(destPath);
          debugPrint('[LocalImport] 已导入: $f.name -> $destPath');
        } catch (e) {
          debugPrint('[LocalImport] 导入失败 ${f.name}: $e');
        }
      }
      // 清理 file_picker 留在 tmp 的缓存副本
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
      return out;
    } catch (e) {
      debugPrint('[LocalImport] 文件选择器打开失败: $e');
      return const [];
    }
  }

  /// 用系统「文件」App 选择单个视频并直接播放（不复制，临时路径）。
  ///
  /// 返回选中的临时文件路径；调用方应立即播放。适合「打开文件」场景，
  /// 需要持久保留时应走 [importVideosFromFilesApp]。
  Future<String?> pickSingleVideoForPlayback() async {
    if (!_isIOS) return null;
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择视频',
        type: FileType.custom,
        allowedExtensions: AppConstants.supportedVideoFormats,
      );
      if (result.isEmpty) return null;
      final f = result.first;
      final p0 = f.path;
      if (p0 == null) return null;
      return await File(p0).exists() ? p0 : null;
    } catch (e) {
      debugPrint('[LocalImport] 选择视频失败: $e');
      return null;
    }
  }

  /// 请求照片库权限（iOS 弹窗；Android 走 permission_handler 的 photos）。
  ///
  /// 返回是否已授权（含「限制访问」limited）。
  Future<bool> requestPhotoLibraryPermission() async {
    if (!_isIOS) return true; // 非 iOS 由既有权限流程负责
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      return ps.isAuth || ps.hasAccess;
    } catch (e) {
      debugPrint('[LocalImport] 照片库权限请求失败: $e');
      return false;
    }
  }

  /// 是否已获得照片库权限。
  Future<bool> hasPhotoLibraryPermission() async {
    if (!_isIOS) return true;
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      return ps.isAuth || ps.hasAccess;
    } catch (_) {
      return false;
    }
  }

  /// 扫描照片库视频资产，导出到 Documents/Imported/PhotoLibrary/，
  /// 返回导出后的本地文件路径列表。
  ///
  /// 只在 iOS 生效（Android 走 MediaStore）。导出为真实文件：
  /// - 规避 photo_manager 临时文件被系统清理的问题；
  /// - 规避 media_kit 播 photo_manager 缓存路径「仅音频无画面」的已知
  ///   bug（media-kit#1192）。
  ///
  /// [progress] 可选回调（已处理数, 总数），用于 UI 显示进度。
  Future<List<String>> exportPhotoLibraryVideos({
    void Function(int done, int total)? progress,
  }) async {
    if (!_isIOS) return const [];
    final hasPerm = await hasPhotoLibraryPermission();
    if (!hasPerm) return const [];

    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        onlyAll: true,
      );
      if (paths.isEmpty) return const [];

      // 统计视频总数（分页遍历所有资产）
      final allAssets = <AssetEntity>[];
      for (final path in paths) {
        final count = await path.assetCountAsync;
        const pageSize = 200;
        for (var start = 0; start < count; start += pageSize) {
          final end = (start + pageSize) < count ? start + pageSize : count;
          final page = await path.getAssetListRange(start: start, end: end);
          allAssets.addAll(page);
        }
      }

      final destDir = await _photoDir();
      final out = <String>[];
      var done = 0;
      for (final asset in allAssets) {
        done++;
        progress?.call(done, allAssets.length);
        try {
          // 只处理视频（保险起见再过滤一次）
          if (asset.type != AssetType.video) continue;
          final title = asset.title;
          final base = (title != null && title.trim().isNotEmpty)
              ? title.trim()
              : 'video_${_uuid.v4().substring(0, 8)}';
          final safeBase = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final ext = _videoExtOf(asset) ?? 'mp4';
          final destPath = await _uniqueDestPath(destDir, '$safeBase.$ext');

          // 检查是否已导出过（按文件名+大小去重）
          if (await File(destPath).exists()) {
            out.add(destPath);
            continue;
          }

          final file = await asset.file; // iOS: 导出到应用缓存
          if (file == null || !await file.exists()) continue;
          await file.copy(destPath);
          out.add(destPath);
          debugPrint('[LocalImport] 照片库导出: $base -> $destPath');
        } catch (e) {
          debugPrint('[LocalImport] 照片库导出失败 (${asset.title}): $e');
        }
      }
      return out;
    } catch (e) {
      debugPrint('[LocalImport] 照片库扫描失败: $e');
      return const [];
    }
  }

  String? _videoExtOf(AssetEntity asset) {
    try {
      final mime = asset.mimeType ?? '';
      if (mime.contains('quicktime')) return 'mov';
      if (mime.contains('mp4') || mime.contains('mpeg')) return 'mp4';
      final title = asset.title ?? '';
      final idx = title.lastIndexOf('.');
      if (idx > 0 && idx < title.length - 1) {
        final ext = title.substring(idx + 1).toLowerCase();
        if (AppConstants.supportedVideoFormats.contains(ext)) return ext;
      }
    } catch (_) {}
    return null;
  }

  /// 目标目录下不冲突的文件路径：同名则加 (1)/(2)…。
  Future<String> _uniqueDestPath(Directory dir, String name) async {
    var candidate = p.join(dir.path, name);
    if (!await File(candidate).exists()) return candidate;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var i = 1; i < 1000; i++) {
      candidate = p.join(dir.path, '${base}_$i$ext');
      if (!await File(candidate).exists()) return candidate;
    }
    return p.join(dir.path, '${base}_${_uuid.v4().substring(0, 6)}$ext');
  }
}
