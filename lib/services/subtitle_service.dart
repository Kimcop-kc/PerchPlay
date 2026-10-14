import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
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

  /// 解析 SRT 字幕文件
  static Future<List<SubtitleEntry>> parseSrt(String subtitlePath) async {
    final file = File(subtitlePath);
    final content = await file.readAsString(encoding: utf8);
    return _parseSrtContent(content);
  }

  static List<SubtitleEntry> _parseSrtContent(String content) {
    final entries = <SubtitleEntry>[];
    final blocks = content.trim().split(RegExp(r'\n\s*\n'));

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 3) continue;

      final index = int.tryParse(lines[0].trim()) ?? entries.length + 1;
      final timeMatch =
          RegExp(r'(\d{2}:\d{2}:\d{2}[,\.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,\.]\d{3})')
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
    final file = File(subtitlePath);
    final content = await file.readAsString(encoding: utf8);
    return _parseVttContent(content);
  }

  static List<SubtitleEntry> _parseVttContent(String content) {
    final entries = <SubtitleEntry>[];
    final lines = content.split('\n');
    int index = 0;
    Duration? start;
    String text = '';

    for (final line in lines) {
      if (line.contains('-->')) {
        final parts = line.split('-->');
        if (parts.length < 2) continue;
        start = _parseVttTime(parts[0].trim());
        text = '';
      } else if (line.trim().isEmpty && start != null) {
        index++;
        entries.add(SubtitleEntry(
          index: index,
          start: start,
          end: Duration(seconds: 0), // simplified
          text: text.trim(),
        ));
        start = null;
        text = '';
      } else if (start != null) {
        text += '$line ';
      }
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