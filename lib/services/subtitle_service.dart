import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/subtitle_model.dart';
import '../core/constants/app_constants.dart';

class SubtitleService {
  /// 查找视频同目录下的外挂字幕文件
  static Future<List<SubtitleModel>> findExternalSubtitles(
      String videoPath) async {
    final subtitles = <SubtitleModel>[];
    final dir = Directory(p.dirname(videoPath));
    if (!await dir.exists()) return subtitles;

    final videoName = p.basenameWithoutExtension(videoPath);

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase().replaceAll('.', '');
      if (!AppConstants.supportedSubtitleFormats.contains(ext)) continue;

      final fileName = p.basenameWithoutExtension(entity.path);
      // 匹配：视频同名 或 视频名+语言后缀
      if (fileName == videoName || fileName.startsWith(videoName)) {
        final lang = _detectLanguage(fileName, videoName);
        subtitles.add(SubtitleModel(
          path: entity.path,
          language: lang,
          title: '$lang (${ext.toUpperCase()})',
        ));
      }
    }

    return subtitles;
  }

  static String _detectLanguage(String fileName, String videoName) {
    final suffix = fileName.replaceFirst(videoName, '').trim();
    const languageMap = {
      'chs': '简体中文',
      'cht': '繁体中文',
      'zh': '中文',
      'zh-cn': '简体中文',
      'zh-tw': '繁体中文',
      'en': 'English',
      'ja': '日本語',
      'ko': '한국어',
      'fr': 'Français',
      'de': 'Deutsch',
      'es': 'Español',
    };
    return languageMap[suffix.toLowerCase()] ?? 'Unknown';
  }

  /// 列出某个目录下的字幕文件
  static Future<List<SubtitleModel>> listSubtitleFilesInDir(
      String dirPath) async {
    final out = <SubtitleModel>[];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return out;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase().replaceAll('.', '');
        if (!AppConstants.supportedSubtitleFormats.contains(ext)) continue;
        out.add(SubtitleModel(
          path: entity.path,
          language: ext.toUpperCase(),
          title: p.basename(entity.path),
        ));
      }
    } catch (_) {}
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  /// 汇总候选字幕文件：视频同目录优先，其次常见下载/影片目录
  ///
  /// iOS 是沙盒系统，没有 `/storage/emulated/0`，改用沙盒 Documents
  /// （用户通过「文件」App 放入的字幕也在那里）。
  static Future<List<SubtitleModel>> findCandidateSubtitles(
      String videoPath) async {
    final dirs = <String>[p.dirname(videoPath)];
    if (!kIsWeb && Platform.isIOS) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        dirs.add(docs.path);
        dirs.add(p.join(docs.path, 'Imported'));
        dirs.add(p.join(docs.path, 'Imported', 'PhotoLibrary'));
      } catch (e) {
        debugPrint('[Subtitle] 读取 Documents 失败: $e');
      }
    } else {
      dirs.addAll(const [
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Documents',
      ]);
    }
    final out = <SubtitleModel>[];
    final seen = <String>{};
    for (final dir in dirs) {
      for (final sub in await listSubtitleFilesInDir(dir)) {
        if (seen.add(sub.path)) out.add(sub);
      }
    }
    return out;
  }

  /// 读字幕文件并做**容错解码**。
  ///
  /// 为什么不直接用 `readAsString()`：
  ///  - 国内大量中文字幕是 **GBK/GB2312** 编码，用 UTF-8 硬解会抛
  ///    `FormatException`，表现为「字幕文件存在却加载失败/字幕空白」；
  ///  - 部分文件带 **UTF-8 BOM**（EF BB BF），不剥掉会让第一行
  ///    （通常是 `1` 或 `[Script Info]`）解析错位。
  ///
  /// 策略：先按 UTF-8 严格解码；失败则用 allowMalformed 宽松解码
  /// （至少能显示出可读部分，而不是整个字幕加载失败）。
  static Future<String> _readText(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return '';

    // 剥掉 UTF-8 BOM
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }

    final body = start == 0 ? bytes : bytes.sublist(start);
    try {
      return utf8.decode(body);
    } on FormatException {
      // 非 UTF-8（多为 GBK）：宽松解码，保留能识别的字符。
      // 不追求完美还原中文，至少不会整个字幕加载失败。
      debugPrint('[Subtitle] 非 UTF-8 编码，使用宽松解码: ${file.path}');
      return utf8.decode(body, allowMalformed: true);
    }
  }

  /// 解析 ASS / SSA 字幕
  static Future<List<SubtitleEntry>> parseAss(String subtitlePath) async {
    final file = File(subtitlePath);
    final content = await _readText(file);
    final entries = <SubtitleEntry>[];
    int index = 0;

    // 先解析 [Script Info] 的 PlayResY 与 [V4+ Styles] 的对齐方式，
    // 用于还原字幕的垂直位置（ASS 用 MarginV + Alignment 表达）。
    final header = _AssHeader.parse(content);

    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('Dialogue:')) continue;
      // 用 limit 拆分：第 10 个字段之后的内容可能含逗号（字幕正文）
      final body = line.substring('Dialogue:'.length);
      final parts = body.split(',');
      if (parts.length < 10) continue;
      final start = _parseAssTime(parts[1].trim());
      final end = _parseAssTime(parts[2].trim());
      final styleName = parts[3].trim();
      var text = parts.sublist(9).join(',');

      // 行内覆盖标签：\pos(x,y) 优先；否则看 {\anN}
      double? vpos;
      int? align;
      final posMatch =
          RegExp(r'\\pos\(\s*([\d.]+)\s*,\s*([\d.]+)\s*\)').firstMatch(text);
      if (posMatch != null) {
        final y = double.tryParse(posMatch.group(2) ?? '');
        if (y != null && header.playResY > 0) {
          vpos = (y / header.playResY).clamp(0.0, 1.0);
        }
      }
      final anMatch = RegExp(r'\\an([1-9])').firstMatch(text);
      if (anMatch != null) align = int.tryParse(anMatch.group(1) ?? '');

      // 去标签：保留换行语义
      text = _cleanAssText(text);
      if (text.isEmpty) continue;

      // 样式表里定义的对齐/边距（没有行内覆盖时使用）
      if (align == null || vpos == null) {
        final st = header.styles[styleName];
        if (st != null) {
          align ??= st.alignment;
          if (vpos == null && header.playResY > 0 && st.marginV > 0) {
            // MarginV 是从对齐边算起的距离，粗略换算成画面比例
            vpos = (1.0 - (st.marginV / header.playResY)).clamp(0.0, 1.0);
          }
        }
      }

      index++;
      entries.add(SubtitleEntry(
        index: index,
        start: start,
        end: end,
        text: text,
        verticalPos: vpos,
        alignment: align,
      ));
    }
    return entries;
  }

  /// 清洗 ASS 正文：
  ///  - 去掉 `{...}` 覆盖标签（如 {\an8}{\c&H00FF00&}）
  ///  - `\N` / `\n` 转为真实换行（保留作者的断行意图）
  ///  - `\h` 转为不换行空格
  ///  - 合并多余空白
  static String _cleanAssText(String raw) {
    var s = raw
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ');
    // 逐行清理：去掉首尾空白，过滤空行
    final lines = s
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.join('\n');
  }

  /// "0:00:01.00" / "0:00:01.000"
  static Duration _parseAssTime(String time) {
    final parts = time.split(':');
    if (parts.length < 3) return Duration.zero;
    final seconds = double.tryParse(parts[2]) ?? 0;
    return Duration(
      hours: int.tryParse(parts[0]) ?? 0,
      minutes: int.tryParse(parts[1]) ?? 0,
      seconds: seconds.toInt(),
      milliseconds: ((seconds - seconds.toInt()) * 1000).round(),
    );
  }

  /// 解析 SRT 字幕文件
  static Future<List<SubtitleEntry>> parseSrt(String subtitlePath) async {
    final content = await _readText(File(subtitlePath));
    return _parseSrtContent(content);
  }

  static List<SubtitleEntry> _parseSrtContent(String content) {
    final entries = <SubtitleEntry>[];
    final blocks = content.trim().split(RegExp(r'\n\s*\n'));

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 3) continue;

      final index = int.tryParse(lines[0].trim()) ?? entries.length + 1;
      final timeMatch = RegExp(
              r'(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})')
          .firstMatch(lines[1].trim());

      if (timeMatch == null) continue;
      final text = lines.sublist(2).join(' ');

      entries.add(SubtitleEntry(
        index: index,
        start: _parseSrtTime(timeMatch.group(1)!),
        end: _parseSrtTime(timeMatch.group(2)!),
        text: text,
      ));
    }

    return entries;
  }

  /// 解析 VTT 字幕文件
  static Future<List<SubtitleEntry>> parseVtt(String subtitlePath) async {
    final content = await _readText(File(subtitlePath));
    return _parseVttContent(content);
  }

  static List<SubtitleEntry> _parseVttContent(String content) {
    final entries = <SubtitleEntry>[];
    final lines = content.split('\n');
    int index = 0;
    Duration? start;
    Duration? end;
    String text = '';

    for (final line in lines) {
      if (line.contains('-->')) {
        // 前一条闭合并入列
        if (start != null) {
          index++;
          entries.add(SubtitleEntry(
            index: index,
            start: start,
            end: end ?? const Duration(days: 1), // 上一行没 end，占位撑到片尾
            text: text.trim(),
          ));
        }
        final parts = line.split('-->');
        if (parts.length < 2) continue;
        start = _parseVttTime(parts[0].trim());
        end = _parseVttTime(parts[1].trim());
        text = '';
      } else if (line.trim().isEmpty && start != null) {
        // 空行 = 本条结束
        index++;
        entries.add(SubtitleEntry(
          index: index,
          start: start,
          end: end ?? const Duration(days: 1),
          text: text.trim(),
        ));
        start = null;
        end = null;
        text = '';
      } else if (start != null) {
        text += '$line ';
      }
    }

    // 文件末尾没有空行时，最后一条也入列
    if (start != null && text.trim().isNotEmpty) {
      index++;
      entries.add(SubtitleEntry(
        index: index,
        start: start,
        end: end ?? const Duration(days: 1),
        text: text.trim(),
      ));
    }

    return entries;
  }

  static Duration _parseSrtTime(String time) {
    final parts = time.replaceAll(',', '.').split(':');
    final seconds = double.parse(parts[2]);
    return Duration(
      hours: int.parse(parts[0]),
      minutes: int.parse(parts[1]),
      seconds: seconds.toInt(),
      milliseconds: ((seconds - seconds.toInt()) * 1000).round(),
    );
  }

  static Duration _parseVttTime(String time) {
    // "00:00:00.000" or "00:00.000"
    final parts = time.split(':');
    if (parts.length == 3) {
      final seconds = double.parse(parts[2]);
      return Duration(
        hours: int.parse(parts[0]),
        minutes: int.parse(parts[1]),
        seconds: seconds.toInt(),
        milliseconds: ((seconds - seconds.toInt()) * 1000).round(),
      );
    } else {
      final seconds = double.parse(parts[1]);
      return Duration(
        minutes: int.parse(parts[0]),
        seconds: seconds.toInt(),
        milliseconds: ((seconds - seconds.toInt()) * 1000).round(),
      );
    }
  }
}

/// ASS/SSA 文件的头部信息（PlayRes + 样式表）。
///
/// 只取「还原位置」必需的字段：
/// - PlayResY：画布高度，用于把像素坐标换算成画面比例
/// - Style.Alignment / MarginV：默认对齐边与底边距
class _AssHeader {
  final int playResY;

  /// 样式名 → (alignment, marginV)
  final Map<String, _AssStyle> styles;

  const _AssHeader({required this.playResY, required this.styles});

  static _AssHeader parse(String content) {
    var playResY = 0;
    final styles = <String, _AssStyle>{};

    for (final raw in content.split('\n')) {
      final line = raw.trim();

      if (line.startsWith('PlayResY:')) {
        playResY = int.tryParse(line.substring(9).trim()) ?? 0;
        continue;
      }

      // Format: Marked,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
      if (line.startsWith('Format:') && line.contains('MarginV')) {
        continue; // Dialogue 的 Format 行，样式表另有 Format
      }

      // Styles 的 Format 行：Name,...,Alignment,MarginL,MarginR,MarginV,...
      if (line.startsWith('Format:') && line.contains('Alignment')) {
        // 记录列索引，后面 Style: 行按它取值
        _styleFormat =
            line.substring(7).split(',').map((e) => e.trim()).toList();
        continue;
      }

      if (line.startsWith('Style:') && _styleFormat != null) {
        final vals = line.substring(6).split(',');
        int idx(String key) => _styleFormat!.indexOf(key);
        final name = vals.isNotEmpty ? vals[0].trim() : 'Default';
        final aIdx = idx('Alignment');
        final mvIdx = idx('MarginV');
        final align = (aIdx >= 0 && aIdx < vals.length)
            ? (int.tryParse(vals[aIdx].trim()) ?? 2)
            : 2;
        final mv = (mvIdx >= 0 && mvIdx < vals.length)
            ? (int.tryParse(vals[mvIdx].trim()) ?? 0)
            : 0;
        styles[name] = _AssStyle(alignment: align, marginV: mv);
      }
    }

    return _AssHeader(playResY: playResY, styles: styles);
  }

  /// Styles 段落的列顺序（静态临时，仅解析期间使用）
  static List<String>? _styleFormat;
}

class _AssStyle {
  final int alignment;
  final int marginV;
  const _AssStyle({required this.alignment, required this.marginV});
}
