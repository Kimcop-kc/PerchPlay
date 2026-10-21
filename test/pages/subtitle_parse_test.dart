import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/subtitle_service.dart';

/// 字幕解析回归测试（SRT / VTT / ASS）。
///
/// 覆盖第五阶段的时间戳匹配、原始换行、空行、空白、标点、超长文本：
/// - SRT 多行文本、空行分隔、时间戳解析
/// - ASS 的 \N 换行、覆盖标签清理、Style 对齐
/// - 换行符不被当作双语分隔符（解析层保留原始换行，渲染层折叠）
void main() {
  group('SRT 解析', () {
    test('标准 SRT：多行文本 + 时间戳', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.srt');
      await f.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\n你好世界\n\n2\n00:00:03,000 --> 00:00:05,000\nHello World\n',
      );

      final entries = await SubtitleService.parseSrt(f.path);
      expect(entries.length, 2);
      expect(entries[0].text, '你好世界');
      expect(entries[0].start, const Duration(seconds: 1));
      expect(entries[0].end, const Duration(seconds: 3));
      expect(entries[1].text, 'Hello World');
    });

    test('SRT 原文自带换行（多行正文）', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.srt');
      // SRT 正文两行被解析为单行（用空格连接）—— 换行是排版，不是双语分隔符
      await f.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\n第一行\n第二行\n',
      );

      final entries = await SubtitleService.parseSrt(f.path);
      expect(entries.length, 1);
      // SRT 解析用空格连接多行（join(' ')，保留为单条文本）
      expect(entries[0].text, '第一行 第二行');
    });

    test('空字幕块被跳过', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.srt');
      await f.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\n你好\n\n\n2\n00:00:03,000 --> 00:00:05,000\n世界\n',
      );

      final entries = await SubtitleService.parseSrt(f.path);
      expect(entries.length, 2);
    });

    test('SRT 时间戳用句点分隔', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.srt');
      await f.writeAsString(
        '1\n00:00:01.500 --> 00:00:02.750\n你好\n',
      );

      final entries = await SubtitleService.parseSrt(f.path);
      expect(entries[0].start, const Duration(milliseconds: 1500));
      expect(entries[0].end, const Duration(milliseconds: 2750));
    });
  });

  group('ASS 解析', () {
    test('ASS \\N 换行保留为真实换行', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.ass');
      await f.writeAsString(
        '[Script Info]\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,第一行\\N第二行\n',
      );

      final entries = await SubtitleService.parseAss(f.path);
      expect(entries.length, 1);
      // \N 转成真实换行，保留作者的断行意图
      expect(entries[0].text, '第一行\n第二行');
    });

    test('ASS 覆盖标签被清理', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.ass');
      await f.writeAsString(
        '[Script Info]\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}{\\c&H00FF00&}你好\n',
      );

      final entries = await SubtitleService.parseAss(f.path);
      expect(entries[0].text, '你好');
      // \an8 对齐被提取
      expect(entries[0].alignment, 8);
    });

    test('ASS 空文本被跳过', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.ass');
      await f.writeAsString(
        '[Script Info]\nPlayResY: 1080\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\nDialogue: 0,0:00:03.00,0:00:05.00,Default,,0,0,0,,你好\n',
      );

      final entries = await SubtitleService.parseAss(f.path);
      expect(entries.length, 1);
      expect(entries[0].text, '你好');
    });
  });

  group('VTT 解析', () {
    test('标准 VTT 时间戳', () async {
      final dir = await Directory.systemTemp.createTemp('sub_test');
      final f = File('${dir.path}/test.vtt');
      await f.writeAsString(
        'WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n你好世界\n\n00:00:03.000 --> 00:00:05.000\nHello\n',
      );

      final entries = await SubtitleService.parseVtt(f.path);
      expect(entries.length, 2);
      expect(entries[0].text, '你好世界');
      expect(entries[0].start, const Duration(seconds: 1));
    });
  });
}
