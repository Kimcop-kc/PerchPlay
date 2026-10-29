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

  /// 生成一张纯色占位图，保证「解码彻底失败」的视频也有封面文件。
  ///
  /// 为什么需要：某些容器（实测 ProRes 编码的 .mov）解码器完全打不开，
  /// 采样点和首帧都失败。这时如果返回 null，UI 侧会走默认占位组件 ——
  /// 但每次列表重建都会**重新触发一次完整解码尝试**（几个采样点各解一次），
  /// 白白浪费 CPU。落一张极小的 jpg 到磁盘，下次直接命中缓存。
  ///
  /// 用最小合法 JPEG（1×1 深灰）：不依赖 image 包的编码器，常量字节
  /// 写入即可，几十字节，对存储无影响。
  Future<String?> _writePlaceholder(String dir, String videoPath) async {
    try {
      final path = _thumbPath(dir, videoPath);
      const jpeg1x1DarkGray = <int>[
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
        0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB,
        0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07,
        0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B,
        0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E,
        0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C,
        0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34,
        0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34,
        0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0x35, 0x10, 0x00, 0x02, 0x01,
        0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00,
        0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21,
        0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
        0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1,
        0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64,
        0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77,
        0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A,
        0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5,
        0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
        0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9,
        0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
        0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF,
        0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD5,
        0xDB, 0x9D, 0x8A, 0xA8, 0x6B, 0x34, 0x0B, 0x2A, 0xFF, 0xD9,
      ];
      await File(path).writeAsBytes(jpeg1x1DarkGray, flush: true);
      return path;
    } catch (e) {
      debugPrint('[Thumbnail] 写占位图失败: $e');
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
      // 所有采样点全失败了：退回到单帧生成。
      //
      // 注意这是**正常回退路径**，不是错误 —— 部分容器（如 ProRes .mov）
      // 的中间帧解码器支持不好，但首帧往往能出。措辞保持中性，避免
      // 用户看日志以为坏了。
      debugPrint('[Thumbnail] 采样点均失败，回退单帧: $videoPath');
      final single = await _generateSingle(videoPath, dir);
      debugPrint('[Thumbnail] 单帧回退${single == null ? '也失败' : '成功'}: '
          '$videoPath');
      // 单帧也失败时用占位图，保证列表不出现空白格
      if (single == null) return _writePlaceholder(dir, videoPath);
      return single;
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
