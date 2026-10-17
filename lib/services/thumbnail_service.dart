import 'dart:io';
import 'package:flutter_video_thumbnail_plus/flutter_video_thumbnail_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 视频缩略图生成 + 存放位置
class ThumbnailService {
  static const _quality = 80;
  static const _size = 360;

  /// 缩略图子目录名
  static const _folderName = 'thumbnails';

  Future<String?> generate(String videoPath) async {
    try {
      final thumbnailPath = await FlutterVideoThumbnailPlus.thumbnailFile(
        video: videoPath,
        thumbnailPath: await _outputDirectory(),
        imageFormat: ImageFormat.jpeg,
        maxWidth: _size,
        quality: _quality,
      );
      return thumbnailPath;
    } catch (_) {
      return null;
    }
  }

  /// 缩略图路径是否还能直接用（有路径，且文件真的还在）
  ///
  /// 系统清缓存 / 用户清数据后数据库里的路径还在、文件没了，
  /// 这时既不能直接 Image.file（会渲染成一片空白），也不该再解码生成 ——
  /// 由调用方决定重新生成。
  static bool isUsable(String path) =>
      path.isNotEmpty && File(path).existsSync();

  /// 删除某个视频的缩略图文件（视频被移出影库后它就没用了）
  ///
  /// 只删 `thumbnails/` 目录里的文件：路径来自数据库，理论上都由 [generate]
  /// 产出，但库可能被迁移/手改过，删错文件的代价太大，先按目录挡住。
  Future<void> deleteThumbnail(String path) async {
    if (path.isEmpty) return;
    try {
      if (p.basename(File(path).parent.path) != _folderName) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 缩略图清理失败不该影响"移除视频"本身
    }
  }

  /// 缩略图输出目录
  ///
  /// 以前写在 `Directory.systemTemp`（应用缓存目录）里：系统一清缓存，
  /// 图片就没了，而数据库里的路径还在 —— 界面只能显示空白占位。
  /// 现在放到应用支持目录（卸载才清），路径依然可能因为清缓存/清数据而失效，
  /// 所以渲染侧仍然必须做「文件不存在就回退占位」的判断（见 CoverThumb）。
  Future<String> _outputDirectory() async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      // 拿不到持久目录时退回缓存目录：缩略图是"有更好、没有也能用"的东西，
      // 不该因为路径问题让整个扫描流程断掉。
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}${Platform.pathSeparator}$_folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }
}
