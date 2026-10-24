import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_video_thumbnail_plus/flutter_video_thumbnail_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'frame_scorer.dart';
import 'local_media_import_service.dart';

/// 视频缩略图生成 + 存放位置 + 智能选帧
///
/// 以前只在一个固定位置（默认片头 ~10%）拿帧，刚好是黑帧/片头字幕的高发区，
/// 导致大量视频的封面是纯黑或纯色占位。现在如果传了 [durationMs]，就从视频
/// 中间等距取样 3~5 个位置，用 [FrameScorer] 打分（亮度方差 × 拉普拉斯锐度），
/// 选得分最高的那一帧写入文件。
///
/// 纯算法、零模型依赖：[nima-frame-quality] 是可选增强，没有时照常工作。
class ThumbnailService {
  static const _quality = 80;
  static const _size = 360;

  /// 缩略图子目录名
  static const _folderName = 'thumbnails';

  /// 视频头尾各跳过的比例：片头 5%（片头字幕/渐入/黑屏），片尾 5%（演职员表）
  static const double _skipHeadRatio = 0.05;
  static const double _skipTailRatio = 0.95;

  /// 采样点数：≤10 分钟的短片 3 点，否则 5 点。更多点会拖慢生成，但对于
  /// 「全片都是黑帧」（纯音频文件）再多点也没用，需要靠分数上限提早终止。
  static const int _samplePointsShort = 3;
  static const int _samplePointsLong = 5;

  /// 生成缩略图。
  ///
  /// [durationMs] 不为 0 且 ≥ 10 秒时启用多位置采样 + 智能选帧，
  /// 否则走原来的单帧生成（兼容性路径：扫描时还没 durationMs 的旧视频
  /// 或被裁剪过的极短视频）。
  Future<String?> generate(String videoPath, {int durationMs = 0}) async {
    try {
      // 照片库资产是虚拟路径（phasset://<id>），磁盘上没有视频文件。
      // 直接用系统缩略图，既不用导出视频、也不用解码，快得多。
      final assetId = LocalMediaImportService.assetIdFromPath(videoPath);
      if (assetId != null) {
        return await _generateFromPhotoAsset(assetId);
      }

      final dir = await _outputDirectory();
      if (durationMs >= 10000) {
        return await _generateWithScore(videoPath, durationMs, dir);
      }
      return await _generateSingle(videoPath, dir);
    } catch (e) {
      debugPrint('[Thumbnail] 生成失败 $videoPath: $e');
      return null;
    }
  }

  /// 照片库资产缩略图：取系统生成的图，落盘成 jpg。
  Future<String?> _generateFromPhotoAsset(String assetId) async {
    try {
      final bytes = await LocalMediaImportService.instance
          .photoAssetThumbnail(assetId, width: _size, height: _size);
      if (bytes == null || bytes.isEmpty) return null;
      final dir = await _outputDirectory();
      final digest =
          sha1.convert(utf8.encode(assetId)).toString().substring(0, 12);
      final path = p.join(dir, 'ph_$digest.jpg');
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('[Thumbnail] 相册缩略图失败 $assetId: $e');
      return null;
    }
  }

  /// 单帧生成（兼容路径：没有时长信息，直接用 timeMs=0 给原生解码器）
  Future<String?> _generateSingle(String videoPath, String dir) async {
    try {
      return await FlutterVideoThumbnailPlus.thumbnailFile(
        video: videoPath,
        thumbnailPath: dir,
        imageFormat: ImageFormat.jpeg,
        maxWidth: _size,
        quality: _quality,
      );
    } catch (_) {
      return null;
    }
  }

  /// 多位置采样 → 打分 → 写胜者
  ///
  /// 用 [thumbnailData] 拿字节（不写磁盘），[FrameScorer.score] 评分，
  /// 最高分的帧才写文件。单帧解码失败不中止整个流程（噪音比"唯一帧失败了"小）。
  Future<String?> _generateWithScore(
      String videoPath, int durationMs, String dir) async {
    final sampleMs = _sampleTimestamps(durationMs);
    if (sampleMs.isEmpty) return null;

    Uint8List? bestBytes;
    double bestScore = -1;

    for (final ms in sampleMs) {
      Uint8List? jpeg;
      try {
        jpeg = await FlutterVideoThumbnailPlus.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.jpeg,
          maxWidth: _size,
          quality: _quality,
          timeMs: ms,
        );
      } catch (_) {
        // 单帧解码失败不中止：28 分钟的视频第 24 分钟解码器报错不影响
        continue;
      }
      if (jpeg == null || jpeg.isEmpty) continue;

      final s = FrameScorer.score(jpeg);
      if (s > bestScore) {
        bestScore = s;
        bestBytes = jpeg;
      }
    }

    if (bestBytes == null) {
      // 所有采样点全失败了：退回到单帧生成
      debugPrint('[Thumbnail] 全部采样点解码失败，退回默认帧: $videoPath');
      return await _generateSingle(videoPath, dir);
    }

    final path = _thumbPath(dir, videoPath);
    await File(path).writeAsBytes(bestBytes);
    return path;
  }

  /// 在视频的可用区间内均匀分布采样时间戳（毫秒）
  ///
  /// 跳过片头 [_skipHeadRatio] 和片尾 [_skipTailRatio] 之间的原因：
  /// 片头常有渐入/黑屏/片头字幕，片尾是演职员表。真正的内容在中间。
  List<int> _sampleTimestamps(int durationMs) {
    final start = (durationMs * _skipHeadRatio).round();
    final end = (durationMs * _skipTailRatio).round();
    if (end <= start) return []; // 视频太短，没有"中间段"

    final count = durationMs < 600000 /* 10 分钟 */
        ? _samplePointsShort
        : _samplePointsLong;
    final step = (end - start) / (count + 1); // count 个点在 start~end 内均匀分割
    return List.generate(count, (i) => (start + step * (i + 1)).round());
  }

  /// 生成缩略图文件名：videoPath 的 hash 后缀，避免同目录同名文件冲突
  static String _thumbPath(String dir, String videoPath) {
    final hash = videoPath.hashCode.abs().toRadixString(36);
    final base = p.basenameWithoutExtension(videoPath);
    // 文件名过长时截断 base（保留前 40 字符 + '_' + hash）
    final safe =
        base.length > 40 ? '${base.substring(0, 40)}_$hash' : '${base}_$hash';
    return p.join(dir, '$safe.jpg');
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
