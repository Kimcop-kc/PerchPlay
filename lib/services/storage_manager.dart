import 'dart:io';

import 'package:path_provider/path_provider.dart';
// 仅用 sqflite 的 getDatabasesPath 定位 DatabaseService 写入的 vidflow.db 真实位置
//（sqflite 为项目既有依赖，非新增；数据库文件不在 path_provider 任一目录内）
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

/// 存储空间与缓存管理服务。
///
/// 负责统计应用各类缓存 / 数据占用的磁盘空间，供设置页展示与清理。
/// 覆盖项对应目录约定：
/// - AI 模型：`<documents>/ai_models`（见 model_downloader.dart 的 modelsDir）
/// - AI 字幕缓存：`<documents>/ai_subtitles`（见 batch_subtitle_service.dart）
/// - 缩略图缓存：`<support>/thumbnails`（见 thumbnail_service.dart）
/// - 临时文件：`getTemporaryDirectory()` 整目录
/// - 应用数据库：`<databases>/vidflow.db`（见 database_service.dart）
///
/// 本类只负责「算大小 / 删文件」，不弹窗、不做二次确认；AI 模型的二次确认由调用方处理。
class StorageManager {
  StorageManager._();

  /// 全局单例。
  static final StorageManager instance = StorageManager._();

  // ── 缓存项 id 常量（供设置页 / 清理逻辑引用，避免硬编码字符串） ──

  /// AI 本地模型。
  static const String idAiModels = 'ai_models';

  /// AI 全片离线字幕缓存。
  static const String idAiSubtitles = 'ai_subtitles';

  /// 视频缩略图缓存。
  static const String idThumbnails = 'thumbnails';

  /// 系统临时目录。
  static const String idTemp = 'temp';

  /// 应用数据库（不可清理）。
  static const String idDatabase = 'database';

  /// 应用数据库文件名（与 database_service.dart 保持一致）。
  static const String _dbFileName = 'vidflow.db';

  /// 扫描所有缓存 / 数据项，返回每项的路径与磁盘占用。
  ///
  /// 目录不存在、单个文件读取失败等情况一律按 0 / 静默跳过处理，不抛异常，
  /// 保证设置页随时可以安全调用。
  Future<List<StorageItem>> scan() async {
    // 并发解析三个基础目录（path_provider 调用互相独立）
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final temp = await getTemporaryDirectory();

    final aiModelsPath = '${docs.path}${Platform.pathSeparator}ai_models';
    final aiSubtitlesPath = '${docs.path}${Platform.pathSeparator}ai_subtitles';
    final thumbnailsPath = '${support.path}${Platform.pathSeparator}thumbnails';
    final dbPath = await _databasePath();

    // 并发算大小，减少串行等待
    final sizes = await Future.wait(<Future<int>>[
      _dirSize(Directory(aiModelsPath)),
      _dirSize(Directory(aiSubtitlesPath)),
      _dirSize(Directory(thumbnailsPath)),
      _dirSize(Directory(temp.path)),
      _dbSize(dbPath),
    ]);

    return <StorageItem>[
      StorageItem(
        id: idAiModels,
        label: 'AI 模型',
        path: aiModelsPath,
        sizeBytes: sizes[0],
        canClear: true,
        description: '本地语音识别模型文件，清理后需重新下载才能离线转写。',
      ),
      StorageItem(
        id: idAiSubtitles,
        label: 'AI 字幕缓存',
        path: aiSubtitlesPath,
        sizeBytes: sizes[1],
        canClear: true,
        description: '全片离线生成的字幕缓存（.srt），清理后下次可重新生成。',
      ),
      StorageItem(
        id: idThumbnails,
        label: '缩略图缓存',
        path: thumbnailsPath,
        sizeBytes: sizes[2],
        canClear: true,
        description: '视频封面缩略图，清理后浏览影库时会自动重新生成。',
      ),
      StorageItem(
        id: idTemp,
        label: '临时文件',
        path: temp.path,
        sizeBytes: sizes[3],
        canClear: true,
        description: '应用运行产生的临时文件，可安全清理。',
      ),
      StorageItem(
        id: idDatabase,
        label: '应用数据库',
        path: dbPath,
        sizeBytes: sizes[4],
        canClear: false,
        description: '影库、播放列表与播放进度等数据，清理会导致数据丢失，不建议清理。',
      ),
    ];
  }

  /// 清空对应缓存项的目录内容。
  ///
  /// - 只删除目录内的文件与子目录，保留目录本身；
  /// - 不可清理项（应用数据库）直接忽略，不会误删；
  /// - AI 模型的二次确认提示由调用方负责，本方法只执行删除。
  Future<void> clearItem(String id) async {
    if (id == idDatabase) return; // 不可清理项
    final path = await _pathFor(id);
    if (path.isEmpty) return;
    await _clearDirectoryContents(Directory(path));
  }

  /// 把字节数格式化为可读文本，如 `8.0 MB` / `1.50 GB`。
  String formatSize(int bytes) {
    var b = bytes < 0 ? 0 : bytes;
    if (b < 1024) return '$b B';
    final kb = b / 1024;
    if (kb < 1024) return '${_trim(kb, 1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${_trim(mb, 1)} MB';
    final gb = mb / 1024;
    if (gb < 1024) return '${_trim(gb, 2)} GB';
    final tb = gb / 1024;
    return '${_trim(tb, 2)} TB';
  }

  /// 去掉浮点尾部多余的 0（1.0 → 1，1.50 → 1.5）。
  static String _trim(double v, int digits) {
    final s = v.toStringAsFixed(digits);
    if (!s.contains('.')) return s;
    var end = s.length;
    while (end > 1 && s[end - 1] == '0') {
      end--;
    }
    if (s[end - 1] == '.') end--;
    return s.substring(0, end);
  }

  /// 递归计算目录下所有文件的字节总数。
  ///
  /// 目录不存在返回 0；枚举失败或单个文件读失败均静默跳过，不向上抛异常。
  Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 单个文件读取失败：跳过，不影响其它文件的统计
        }
      }
    } catch (_) {
      // 目录枚举失败：按 0 处理
    }
    return total;
  }

  /// 计算数据库文件（含 WAL / SHM 附属文件）的字节总数。
  Future<int> _dbSize(String dbPath) async {
    if (dbPath.isEmpty) return 0;
    var total = 0;
    for (final suffix in const <String>['', '-wal', '-shm']) {
      total += await _fileSize('$dbPath$suffix');
    }
    return total;
  }

  /// 单个文件大小，不存在 / 读取失败返回 0。
  Future<int> _fileSize(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) return await f.length();
    } catch (_) {}
    return 0;
  }

  /// 删除目录内所有内容（文件 + 子目录），保留目录本身。
  Future<void> _clearDirectoryContents(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await for (final entity
          in dir.list(recursive: false, followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {
          // 单个条目删除失败：跳过
        }
      }
    } catch (_) {
      // 目录枚举失败：无法清理，静默返回
    }
  }

  /// 根据 id 解析对应目录路径。
  Future<String> _pathFor(String id) async {
    switch (id) {
      case idAiModels:
        final docs = await getApplicationDocumentsDirectory();
        return '${docs.path}${Platform.pathSeparator}ai_models';
      case idAiSubtitles:
        final docs = await getApplicationDocumentsDirectory();
        return '${docs.path}${Platform.pathSeparator}ai_subtitles';
      case idThumbnails:
        final support = await getApplicationSupportDirectory();
        return '${support.path}${Platform.pathSeparator}thumbnails';
      case idTemp:
        final temp = await getTemporaryDirectory();
        return temp.path;
      default:
        return '';
    }
  }

  /// 解析数据库文件真实路径。
  ///
  /// sqflite 的 getDatabasesPath 在不支持的平台（如 Windows 无 ffi）会抛异常，
  /// 这里降级为空串，对应项按 0 字节处理。
  Future<String> _databasePath() async {
    try {
      final dbDir = await getDatabasesPath();
      return '$dbDir${Platform.pathSeparator}$_dbFileName';
    } catch (_) {
      return '';
    }
  }
}

/// 一项存储 / 缓存数据（不可变，供设置页列表展示）。
class StorageItem {
  /// 项唯一标识，对应 [StorageManager] 的 id 常量。
  final String id;

  /// 中文显示名。
  final String label;

  /// 该项在磁盘上的路径（目录或单个文件）。
  final String path;

  /// 占用字节数。
  final int sizeBytes;

  /// 是否可安全清理。
  final bool canClear;

  /// 中文说明文案。
  final String description;

  const StorageItem({
    required this.id,
    required this.label,
    required this.path,
    required this.sizeBytes,
    required this.canClear,
    required this.description,
  });
}