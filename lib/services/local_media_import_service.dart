import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' show sha1;
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
  ///
  /// 性能：多个文件**并发复制**（默认 3 路，避免同盘随机写互相拖慢），
  /// 比原来逐个 await 串行复制快很多；[progress] 可显示导入进度。
  Future<List<String>> importVideosFromFilesApp({
    void Function(int done, int total)? progress,
  }) async {
    if (!_isIOS) return const [];
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择视频（可多选）',
        type: FileType.custom,
        allowedExtensions: AppConstants.supportedVideoFormats,
      );
      if (result.isEmpty) return const [];

      // 先筛出真正要导入的（存在的、扩展名合法的）
      final picked = <(File, String)>[];
      for (final f in result) {
        final path = f.path;
        if (path == null) continue;
        final ext = p.extension(f.name).toLowerCase().replaceAll('.', '');
        if (!AppConstants.supportedVideoFormats.contains(ext)) continue;
        final src = File(path);
        if (!await src.exists()) continue;
        picked.add((src, f.name));
      }
      if (picked.isEmpty) {
        try {
          await FilePicker.clearTemporaryFiles();
        } catch (_) {}
        return const [];
      }

      final destDir = await _importRoot();
      final total = picked.length;
      final results = List<String?>.filled(total, null);
      var done = 0;

      // 并发复制：3 路并发在闪存上吞吐最好，过多反而互相拖慢
      const concurrency = 3;
      for (var start = 0; start < total; start += concurrency) {
        final end = (start + concurrency) < total ? start + concurrency : total;
        await Future.wait([
          for (var i = start; i < end; i++)
            () async {
              final (src, name) = picked[i];
              try {
                final fileName = await _uniqueFileName(destDir, name);
                final destPath = p.join(destDir.path, fileName);
                await src.copy(destPath);
                results[i] = destPath;
                debugPrint('[LocalImport] 已导入: $name -> $fileName');
              } catch (e) {
                debugPrint('[LocalImport] 导入失败 $name: $e');
              } finally {
                done++;
                progress?.call(done, total);
              }
            }(),
        ]);
      }

      // 清理 file_picker 留在 tmp 的缓存副本
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}
      return results.whereType<String>().toList();
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
  /// 性能要点：用「资产 ID → 已导出文件名」的持久化索引做去重，已导出过的
  /// 资产**不再重新 copy**（早期实现用「文件名冲突就加 _1/_2」的方式，导致
  /// 每次刷新都把整个相册重导一遍，越刷越慢、磁盘无限膨胀）。
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
      // 读索引：资产 id -> 文件名
      final index = await _loadPhotoIndex();
      final out = <String>[];
      var done = 0;
      var indexDirty = false;

      // 兼容旧数据：把同目录里「文件名以资产 id 前缀开头」的孤儿文件也认回来，
      // 避免旧版本中断留下的副本被当成新资产重复导出。
      // （旧实现导出成功才写索引，中途退出就会漏索引 → 下次生成 _1 副本。）

      for (final asset in allAssets) {
        done++;
        progress?.call(done, allAssets.length);
        try {
          if (asset.type != AssetType.video) continue;
          final assetId = asset.id;

          // 已导出且文件还在 -> 直接用，跳过昂贵的导出
          final known = index[assetId];
          if (known != null) {
            final knownPath = p.join(destDir.path, known);
            if (await File(knownPath).exists()) {
              out.add(knownPath);
              continue;
            }
            // 索引有但文件没了（用户清了 App 数据/被系统清理）：
            // 删掉这一条，下面按同一稳定文件名重新导出。
            index.remove(assetId);
            indexDirty = true;
          }

          final title = asset.title;
          final base = (title != null && title.trim().isNotEmpty)
              ? title.trim()
              : 'video_${_uuid.v4().substring(0, 8)}';
          final safeBase = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final ext = _videoExtOf(asset) ?? 'mp4';

          // 用资产 ID 派生**稳定**文件名，保证同一个资产永远落到同一个路径。
          //
          // 旧实现用 _uniqueFileName：中断一次没写索引，下次就生成 xxx_1.mp4，
          // 同一视频变成两条不同 path 的记录 → 界面上重复显示。
          // 现在文件名只由资产 ID 决定，重扫是幂等的。
          final stableName = '${_assetFilePrefix(assetId)}$safeBase.$ext';
          final destPath = p.join(destDir.path, stableName);

          // 稳定文件已存在（上次导出成功但没来得及写索引）→ 直接认领
          if (await File(destPath).exists()) {
            final len = await File(destPath).length();
            if (len > 20 * 1024) {
              out.add(destPath);
              index[assetId] = stableName;
              indexDirty = true;
              continue;
            }
            // 太小：上次可能只写了一部分，删掉重来
            try {
              await File(destPath).delete();
            } catch (_) {}
          }

          // iCloud 未下载到本地的资产：asset.file 会返回 null 或抛异常。
          try {
            final available = await asset.isLocallyAvailable();
            if (!available) {
              debugPrint('[LocalImport] 资产在 iCloud 未下载，尝试获取: $base');
            }
          } catch (_) {}

          final file = await asset.file; // iOS: 导出到应用缓存
          if (file == null) {
            debugPrint('[LocalImport] 取不到文件（可能 iCloud 未下载）: $base');
            continue;
          }
          if (!await file.exists()) {
            debugPrint('[LocalImport] 导出文件不存在: $base');
            continue;
          }
          await file.copy(destPath);
          out.add(destPath);
          index[assetId] = stableName;
          indexDirty = true;
          // 每个文件导出后立刻落盘索引：中途被杀也不会丢掉已完成的进度
          if (indexDirty && done % 5 == 0) {
            await _savePhotoIndex(index);
            indexDirty = false;
          }
          debugPrint('[LocalImport] 照片库导出: $base -> $stableName');
        } catch (e) {
          debugPrint('[LocalImport] 照片库导出失败 (${asset.title}): $e');
        }
      }
      if (indexDirty) await _savePhotoIndex(index);
      return out;
    } catch (e) {
      debugPrint('[LocalImport] 照片库扫描失败: $e');
      return const [];
    }
  }

  /// 由照片库资产 ID 派生一个稳定的文件名前缀。
  ///
  /// 目的：让「同一个资产」永远落到同一个文件名，重扫幂等。
  /// 取 ID 的稳定哈希（不用原始 ID：里面可能带 `/`、`:` 等文件名非法字符，
  /// 而且长度可能很长）。
  String _assetFilePrefix(String assetId) {
    final digest = sha1.convert(utf8.encode(assetId)).toString();
    return 'ph_${digest.substring(0, 12)}_';
  }

  /// 照片库导出索引文件（Documents/Imported/.photo_index.json）。
  static const _photoIndexName = '.photo_index.json';

  Future<Map<String, String>> _loadPhotoIndex() async {
    try {
      final root = await _importRoot();
      final f = File(p.join(root.path, _photoIndexName));
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e) {
      debugPrint('[LocalImport] 读取照片索引失败: $e');
    }
    return {};
  }

  Future<void> _savePhotoIndex(Map<String, String> index) async {
    try {
      final root = await _importRoot();
      final f = File(p.join(root.path, _photoIndexName));
      await f.writeAsString(jsonEncode(index), flush: true);
    } catch (e) {
      debugPrint('[LocalImport] 写入照片索引失败: $e');
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

  /// 目标目录下不冲突的**文件名**（不是完整路径）：同名则加 _1/_2…
  Future<String> _uniqueFileName(Directory dir, String name) async {
    if (!await File(p.join(dir.path, name)).exists()) return name;
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    for (var i = 1; i < 1000; i++) {
      final candidate = '${base}_$i$ext';
      if (!await File(p.join(dir.path, candidate)).exists()) return candidate;
    }
    return '${base}_${_uuid.v4().substring(0, 6)}$ext';
  }
}
