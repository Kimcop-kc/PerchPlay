import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/online_subtitle.dart';
import '../../models/subtitle_model.dart';
import 'subtitle_file_name.dart';
import 'subtitle_source.dart';

/// 字幕下载结果。
class SubtitleDownloadResult {
  /// 下载并验证后的本地字幕文件路径（可能是解压后的单文件）。
  final String localPath;

  /// 字幕语言（用于构建 SubtitleModel）。
  final String language;

  /// 字幕标题（文件名）。
  final String title;

  const SubtitleDownloadResult({
    required this.localPath,
    required this.language,
    required this.title,
  });

  /// 转成本地 [SubtitleModel]，交给播放器加载。
  SubtitleModel toSubtitleModel() {
    return SubtitleModel(
      path: localPath,
      language: language,
      title: title,
    );
  }
}

/// 字幕下载与本地管理服务。
///
/// 负责：安全下载、格式/内容校验、zip 安全解压、编码识别、
/// 保存到持久化字幕目录、验证可解析。
class SubtitleDownloader {
  SubtitleDownloader._();

  static final SubtitleDownloader instance = SubtitleDownloader._();

  /// 单个字幕文件最大下载大小（2MB，正常字幕几百 KB）。
  static const int maxSubtitleBytes = 2 * 1024 * 1024;

  /// zip 解压后总大小上限（10MB）。
  static const int maxExtractBytes = 10 * 1024 * 1024;

  /// zip 解压文件数量上限。
  static const int maxExtractFiles = 20;

  /// 下载进度回调（0~1）。
  void Function(double progress)? onProgress;

  /// 下载并保存字幕。
  ///
  /// [source] 提供下载直链，[subtitle] 是搜索结果。
  /// 返回本地字幕模型，失败抛 [SubtitleServiceException]。
  Future<SubtitleDownloadResult> download(
    SubtitleSource source,
    OnlineSubtitle subtitle,
  ) async {
    // 1. 换取真实下载直链
    final url = await source.resolveDownloadUrl(subtitle);

    // 2. 下载（带超时 + 进度）
    final bytes = await _download(url);

    // 3. 校验大小
    if (bytes.isEmpty) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '下载内容为空',
      );
    }
    if (bytes.length > maxSubtitleBytes) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '字幕文件过大',
      );
    }

    // 4. 识别格式（zip 还是纯字幕）
    final isZip = _isZip(bytes);
    final extracted = isZip ? _extractZip(bytes) : bytes;
    if (extracted == null || extracted.isEmpty) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '解压失败或内容为空',
      );
    }

    // 5. 解码文本（处理编码）
    final text = _decodeText(extracted);
    if (text.trim().isEmpty) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '字幕内容为空',
      );
    }

    // 6. 验证是可解析的字幕格式
    final format = _detectFormat(subtitle.format, text);
    if (format == null) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '无法识别的字幕格式',
      );
    }

    // 7. 保存到持久化字幕目录
    final fileName = SubtitleFileName.sanitize(subtitle.name);
    final ext = _formatExtension(format);
    final safeName = fileName.endsWith(ext) ? fileName : '$fileName.$ext';
    final dir = await _subtitleDir();
    final file = File('${dir.path}${Platform.pathSeparator}$safeName');
    await file.writeAsBytes(extracted, flush: true);

    return SubtitleDownloadResult(
      localPath: file.path,
      language: subtitle.languageName,
      title: safeName,
    );
  }

  /// 下载字节（带超时 + 进度 + HTTP 状态检查）。
  Future<List<int>> _download(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'PerchPlay v1.0');
      final resp = await req.close().timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) {
        throw SubtitleServiceException(
          SubtitleErrorType.unknown,
          '下载失败 (HTTP ${resp.statusCode})',
          statusCode: resp.statusCode,
        );
      }

      // 检查 content-type，避免把 HTML 错误页当字幕
      final contentType = resp.headers.contentType?.mimeType ?? '';
      if (contentType.contains('text/html')) {
        throw const SubtitleServiceException(
          SubtitleErrorType.parseError,
          '下载到的是 HTML 页面而非字幕',
        );
      }

      final total = resp.contentLength;
      final bytes = <int>[];
      var received = 0;
      await for (final chunk in resp) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
        if (received > maxSubtitleBytes * 2) {
          throw const SubtitleServiceException(
            SubtitleErrorType.parseError,
            '字幕文件过大',
          );
        }
      }
      return bytes;
    } on SubtitleServiceException {
      rethrow;
    } catch (e) {
      throw SubtitleServiceException(
        SubtitleErrorType.network,
        '下载失败: $e',
      );
    } finally {
      client.close();
    }
  }

  /// 判断是否为 zip（PK 魔数）。
  static bool _isZip(List<int> bytes) {
    return bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
  }

  /// 安全解压 zip：防路径穿越、压缩炸弹、限制文件数/总大小。
  /// 返回第一个可识别的字幕文件字节，无则 null。
  List<int>? _extractZip(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      var totalSize = 0;
      var fileCount = 0;
      List<int>? firstSubtitle;

      for (final file in archive) {
        if (file.isFile) {
          fileCount++;
          if (fileCount > maxExtractFiles) {
            throw const SubtitleServiceException(
              SubtitleErrorType.parseError,
              '压缩包文件过多',
            );
          }
          final size = file.size;
          totalSize += size;
          if (totalSize > maxExtractBytes) {
            throw const SubtitleServiceException(
              SubtitleErrorType.parseError,
              '解压后体积过大',
            );
          }
          // 只接受字幕格式
          if (SubtitleFileName.isSupportedFormat(file.name) &&
              !file.name.toLowerCase().endsWith('.zip')) {
            firstSubtitle ??= file.content as List<int>;
          }
        }
      }
      return firstSubtitle;
    } catch (e) {
      if (e is SubtitleServiceException) rethrow;
      return null;
    }
  }

  /// 解码字幕字节为文本，处理常见编码。
  String _decodeText(List<int> bytes) {
    // 剥 UTF-8 BOM
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    // UTF-16 LE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes, littleEndian: true);
    }
    // UTF-16 BE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes, littleEndian: false);
    }

    final body = start == 0 ? bytes : bytes.sublist(start);
    try {
      return utf8.decode(body);
    } on FormatException {
      // 非 UTF-8，尝试 GBK（常见中文字幕）
      try {
        return gbk.decode(body);
      } catch (_) {
        // 最后兜底：宽松 UTF-8（至少显示可读部分）
        return utf8.decode(body, allowMalformed: true);
      }
    }
  }

  /// 解码 UTF-16（带 BOM 的字节）。
  String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    // 跳过 BOM（2 字节）
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      final lo = bytes[i];
      final hi = bytes[i + 1];
      final unit = littleEndian ? (lo | (hi << 8)) : ((lo << 8) | hi);
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }

  /// 识别字幕格式（srt/ass/ssa/vtt）。
  String? _detectFormat(String declaredFormat, String text) {
    final f = declaredFormat.toLowerCase();
    if (f == 'srt' || f == 'ass' || f == 'ssa' || f == 'vtt') {
      return f;
    }
    // 从内容特征推断
    final firstLine = text.trim().split('\n').first.trim().toLowerCase();
    if (firstLine.startsWith('webvtt')) return 'vtt';
    if (firstLine.startsWith('[script info]')) return 'ass';
    if (firstLine.startsWith('[events]') || firstLine.contains('dialogue:')) {
      return 'ass';
    }
    if (text.contains('-->')) return 'srt';
    return null;
  }

  /// 格式 → 扩展名。
  static String _formatExtension(String format) {
    switch (format) {
      case 'ass':
        return '.ass';
      case 'ssa':
        return '.ssa';
      case 'vtt':
        return '.vtt';
      case 'srt':
      default:
        return '.srt';
    }
  }

  /// 字幕持久化目录（应用支持目录下的 subtitles）。
  Future<Directory> _subtitleDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}subtitles');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
