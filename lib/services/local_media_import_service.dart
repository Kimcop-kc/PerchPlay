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
import '../models/video_model.dart';

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
/// 3. **照片库**：`photo_manager` 枚举相册视频（需照片库权限）。
///    **只读元数据建库，绝不复制视频文件** —— 早期实现为了绕开
///    media_kit 的渲染问题，把整个相册都 copy 进 Documents，
///    等于把用户视频库翻倍，存储直接爆炸。现在影库里存的是
///    `phasset://<资产ID>` 这样的虚拟路径，只有**真正播放时**才把
///    那一个资产导出到临时缓存目录，并做 LRU 淘汰（只留最近 1~2 个）。
///
/// 这些方法在 Android/桌面平台上调用时返回空或走原本的 MediaStore/文件系统
/// 扫描，不影响既有逻辑。
class LocalMediaImportService {
  LocalMediaImportService._();
  static final instance = LocalMediaImportService._();

  final _uuid = const Uuid();

  /// 导入文件存放的子目录名（Documents 下）。
  static const _importDirName = 'Imported';

  /// 照片库资产的虚拟路径协议。
  ///
  /// 形如 `phasset://A1B2C3...`。影库里只存这个，不落地文件。
  static const photoAssetScheme = 'phasset://';

  /// 播放时按需导出的缓存目录名（在系统临时目录下，不进 Documents）。
  static const _playbackCacheDirName = 'phplayback';

  /// 播放缓存最多保留几个文件。
  ///
  /// 固定为 1：只留「当前正在播的那一个」，切下一个视频时立刻删掉旧的。
  /// 相册视频在 iOS 上必须导出才能播（PHAsset 没有可读路径），这一份是
  /// 平台下限、省不掉；那至少让它**只在播放期间存在**，不额外积累。
  static const int _playbackCacheMaxFiles = 1;

  /// 播放缓存总大小上限（超过就按最久未访问淘汰）。
  /// 单个超大文件因为要用来播放，会被保留（淘汰逻辑永远不删 keep）。
  static const int _playbackCacheMaxBytes = 800 * 1024 * 1024; // 800MB

  /// 是否是照片库资产的虚拟路径。
  static bool isPhotoAssetPath(String path) =>
      path.startsWith(photoAssetScheme);

  /// 由资产 ID 构造影库里的虚拟路径。
  static String photoAssetPath(String assetId) =>
      '$photoAssetScheme$assetId';

  /// 从虚拟路径取回资产 ID；不是照片库路径则返回 null。
  static String? assetIdFromPath(String path) {
    if (!isPhotoAssetPath(path)) return null;
    final id = path.substring(photoAssetScheme.length);
    return id.isEmpty ? null : id;
  }

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

  /// 播放缓存目录：系统临时目录/phplayback（自动创建）。
  ///
  /// 用临时目录而非 Documents：① 不占用户可见空间、不进 iCloud 备份；
  /// ② 系统空间紧张时可以自己回收，最多只是下次重导一个文件。
  Future<Directory> _playbackCacheDir() async {
    Directory base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, _playbackCacheDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 是否 iOS（照片库/文件导入只在 iOS 有意义；Android 走 MediaStore）。
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// 是否是照片库扫描得到的文件（用于清理时避免误删用户自己放的文件）。
  static bool isPhotoExportPath(String path) =>
      path.contains('/$_importDirName/PhotoLibrary/');

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

  /// 扫描照片库视频资产，**只读元数据、不复制任何文件**。
  ///
  /// 返回的路径是 `phasset://<资产ID>` 虚拟路径，真正播放时才按需导出
  /// （见 [resolveAssetForPlayback]）。
  ///
  /// 为什么改：早期为了绕开 media_kit 的渲染问题，把整个相册 copy 进
  /// Documents/Imported/PhotoLibrary，等于把用户视频库翻倍 —— 相册几十 GB
  /// 的用户存储直接爆炸。现在影库里只存虚拟路径，磁盘占用与相册大小无关。
  ///
  /// [progress] 可选回调（已处理数, 总数），用于 UI 显示进度。
  Future<List<VideoModel>> scanPhotoLibraryAssets({
    void Function(int done, int total)? progress,
  }) async {
    if (!_isIOS) return const [];
    final hasPerm = await hasPhotoLibraryPermission();
    if (!hasPerm) {
      debugPrint('[LocalImport] 无照片库权限，跳过');
      return const [];
    }

    try {
      final pathList = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        onlyAll: true,
      );
      if (pathList.isEmpty) return const [];

      // 分页遍历全部视频资产（只为拿元数据，开销很小）
      final allAssets = <AssetEntity>[];
      for (final path in pathList) {
        final count = await path.assetCountAsync;
        const pageSize = 200;
        for (var start = 0; start < count; start += pageSize) {
          final end = (start + pageSize) < count ? start + pageSize : count;
          final page = await path.getAssetListRange(start: start, end: end);
          allAssets.addAll(page);
        }
      }

      final out = <VideoModel>[];
      var done = 0;
      for (final asset in allAssets) {
        done++;
        progress?.call(done, allAssets.length);
        if (asset.type != AssetType.video) continue;

        final virtualPath = photoAssetPath(asset.id);
        final title = asset.title?.trim() ?? '';
        final name = title.isNotEmpty
            ? p.basenameWithoutExtension(title)
            : '相册视频_${_shortId(asset.id)}';

        out.add(VideoModel(
          id: _uuid.v5(Namespace.url.value, virtualPath),
          path: virtualPath,
          name: name,
          // 统一归到「照片库」，来源分类会识别成个人视频
          folderPath: '照片库',
          // 相册接口拿不到精确字节数，置 0（详情页显示未知）
          size: 0,
          durationMs: asset.duration * 1000,
          dateAdded: asset.createDateTime,
          dateModified: asset.modifiedDateTime,
          thumbnailPath: '',
        ));
      }
      debugPrint('[LocalImport] 照片库扫描到 ${out.length} 个视频（未复制文件）');
      return out;
    } catch (e, st) {
      debugPrint('[LocalImport] 照片库扫描失败: $e\n$st');
      return const [];
    }
  }

  /// 把照片库资产按需导出到**临时缓存**，返回可播放的本地文件路径。
  ///
  /// 只在真正要播放时调用。缓存做了双重上限（文件数 + 总字节）的 LRU 淘汰，
  /// 所以磁盘上最多只有正在播的那 1~2 个文件，不会随相册大小增长。
  ///
  /// 返回 null 表示拿不到文件（资产已删 / iCloud 未下载 / 无权限）。
  Future<String?> resolveAssetForPlayback(String assetId) async {
    if (!_isIOS) return null;
    try {
      final cacheDir = await _playbackCacheDir();
      final prefix = _assetFilePrefix(assetId);

      // 1) 缓存命中：文件名以资产哈希前缀开头
      final entries = await cacheDir.list().toList();
      final cached = entries
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith(prefix))
          .toList();
      if (cached.isNotEmpty) {
        final f = cached.first;
        // 触碰 mtime，标记「最近使用」，避免被 LRU 淘汰
        try {
          await f.setLastModified(DateTime.now());
        } catch (_) {}
        return f.path;
      }

      // 2) 未命中：导出这一个资产
      final asset = await AssetEntity.fromId(assetId);
      if (asset == null) {
        debugPrint('[LocalImport] 资产不存在: $assetId');
        return null;
      }

      try {
        final available = await asset.isLocallyAvailable();
        if (!available) {
          debugPrint('[LocalImport] 资产在 iCloud 未下载: $assetId');
        }
      } catch (_) {}

      final file = await asset.file;
      if (file == null || !await file.exists()) {
        debugPrint('[LocalImport] 取不到资产文件（可能 iCloud 未下载）: $assetId');
        return null;
      }

      final ext = _videoExtOf(asset) ?? 'mp4';
      final dest = File(p.join(cacheDir.path, '$prefix$ext'));

      // 优先 rename 而不是 copy：
      //  asset.file 返回的是 photo_manager 自己导出的临时文件，和我们的缓存
      //  目录都在 App 容器内、同一文件系统，所以 rename 是原子改名（不搬数据）。
      //  好处：① 播放期间不会出现「两份副本」（原来 copy 会让占用翻倍）；
      //        ② 首次播放不用读写整片，大文件几乎瞬时就位。
      //  失败（跨卷等极端情况）再退回 copy。
      var moved = false;
      try {
        await file.rename(dest.path);
        moved = true;
        debugPrint('[LocalImport] 缓存就位(rename): ${p.basename(dest.path)}');
      } catch (e) {
        debugPrint('[LocalImport] rename 失败，退回 copy: $e');
      }
      if (!moved) {
        await file.copy(dest.path);
        // copy 成功后再删掉 photo_manager 那份，避免两份并存占双倍空间
        try {
          await file.delete();
        } catch (_) {}
        debugPrint('[LocalImport] 缓存就位(copy): ${p.basename(dest.path)}');
      }

      // 3) 导出成功后再淘汰（keep 保证不删刚写的这个）
      await _evictPlaybackCache(keep: dest.path);
      return dest.path;
    } catch (e, st) {
      debugPrint('[LocalImport] 资产导出失败 $assetId: $e\n$st');
      return null;
    }
  }

  /// 照片库资产的缩略图字节。
  ///
  /// 直接让系统生成，不用解码视频，比 flutter_video_thumbnail_plus 快得多，
  /// 也不需要在磁盘上留视频副本。
  Future<Uint8List?> photoAssetThumbnail(
    String assetId, {
    int width = 360,
    int height = 360,
  }) async {
    if (!_isIOS) return null;
    try {
      final asset = await AssetEntity.fromId(assetId);
      if (asset == null) return null;
      return await asset.thumbnailDataWithSize(
        ThumbnailSize(width, height),
        quality: 85,
      );
    } catch (e) {
      debugPrint('[LocalImport] 缩略图失败 $assetId: $e');
      return null;
    }
  }

  /// 清理旧版本遗留的「照片库整库副本」（Documents/Imported/PhotoLibrary）。
  ///
  /// 升级到新方案后必须删掉，否则那些重复文件会一直占着用户存储。
  /// 只删这个子目录，不动 Imported 根下用户自己通过「文件」App 导入的视频。
  Future<int> cleanupLegacyPhotoExports() async {
    try {
      final docs = await documentsDirectory();
      final dir = Directory(p.join(docs.path, _importDirName, 'PhotoLibrary'));
      if (!await dir.exists()) return 0;
      var count = 0;
      await for (final e in dir.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
          count++;
        } catch (_) {}
      }
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      debugPrint('[LocalImport] 已清理旧版照片库副本 $count 项');
      return count;
    } catch (e) {
      debugPrint('[LocalImport] 清理旧版照片库副本失败: $e');
      return 0;
    }
  }

  /// 清空播放缓存（关闭播放 / 退出小窗时调用）。
  ///
  /// 相册视频的临时副本只在播放期间有用，停止播放就删，
  /// 这样「不播相册视频时」临时目录是空的。
  Future<void> clearPlaybackCache() async {
    try {
      final dir = await _playbackCacheDir();
      if (!await dir.exists()) return;
      var count = 0;
      await for (final e in dir.list(followLinks: false)) {
        try {
          if (e is File) await e.delete();
          count++;
        } catch (_) {}
      }
      if (count > 0) {
        debugPrint('[LocalImport] 播放缓存已清空 $count 项');
      }
    } catch (e) {
      debugPrint('[LocalImport] 清空播放缓存失败: $e');
    }
  }

  /// 按「最久未修改」淘汰播放缓存，保证不超过文件数与总字节上限。
  Future<void> _evictPlaybackCache({required String keep}) async {
    try {
      final dir = await _playbackCacheDir();
      final files =
          (await dir.list().toList()).whereType<File>().toList();
      if (files.isEmpty) return;

      final stats = <({File file, DateTime mtime, int size})>[];
      for (final f in files) {
        try {
          final st = await f.stat();
          stats.add((file: f, mtime: st.modified, size: st.size));
        } catch (_) {}
      }
      // 新的在前
      stats.sort((a, b) => b.mtime.compareTo(a.mtime));

      var kept = 0;
      var total = 0;
      for (final s in stats) {
        final isKeep = s.file.path == keep;
        final overCount = kept >= _playbackCacheMaxFiles;
        final overBytes = (total + s.size) > _playbackCacheMaxBytes;
        if (!isKeep && (overCount || overBytes)) {
          try {
            await s.file.delete();
            debugPrint('[LocalImport] 淘汰播放缓存: ${p.basename(s.file.path)}');
          } catch (_) {}
        } else {
          kept++;
          total += s.size;
        }
      }
    } catch (e) {
      debugPrint('[LocalImport] 清理播放缓存失败: $e');
    }
  }

  /// 由照片库资产 ID 派生一个稳定的文件名前缀。
  ///
  /// 用哈希而不是原始 ID：ID 里可能带 `/`、`:` 等文件名非法字符，长度也不可控。
  String _assetFilePrefix(String assetId) {
    final digest = sha1.convert(utf8.encode(assetId)).toString();
    return 'ph_${digest.substring(0, 12)}_';
  }

  /// 取 ID 末尾几位做兜底显示名。
  String _shortId(String id) =>
      id.length <= 6 ? id : id.substring(id.length - 6);

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
  ///
  /// 只给「文件 App 导入」用：用户可能真的选了同名但内容不同的两个文件。
  /// 照片库走资产哈希命名，不需要它。
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
