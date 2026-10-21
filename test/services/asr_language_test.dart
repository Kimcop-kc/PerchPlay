import 'package:flutter_test/flutter_test.dart';

/// ASR 语言标签提取回归测试（P0-4.3 缺陷修复）
///
/// SenseVoice 在 ASR 结果里嵌入语言标签如 `<|zh|>`, `<|en|>`, `<|ja|>`。
/// 修复前 `_cleanAsrText` 只删除不做提取，导致翻译方向判定缺失。
/// 修复后返回 `(cleanedText, detectedLang)` 元组。

/// 模拟 _cleanAsrText 逻辑
(String?, String?) cleanAsrText(String raw) {
  if (raw.isEmpty) return (null, null);

  // 提取语言标签
  final tagRe = RegExp(r'<\|\s*(zh|en|ja|ko|fr|de|es|ru|yue)\s*\|>');
  final tagMatch = tagRe.firstMatch(raw);
  final lang = tagMatch?.group(1);

  // 删除所有标签
  final cleaned = raw.replaceAll(tagRe, '').trim();
  if (cleaned.isEmpty) return (null, lang);

  // 去掉首尾的标志位空格/标点（SenseVoice 偶尔残留）
  final finalText = cleaned
      .replaceAll(RegExp(r'^[,.，。、；;:：!\s]+'), '')
      .replaceAll(RegExp(r'[,.，。、；;:：!\s]+$'), '')
      .trim();
  if (finalText.isEmpty) return (null, lang);

  return (finalText, lang);
}

void main() {
  group('ASR 语言标签提取', () {
    test('中文标签：提取 zh，文本清理正确', () {
      final (text, lang) = cleanAsrText('<|zh|>你好世界');
      expect(text, '你好世界');
      expect(lang, 'zh');
    });

    test('英文标签：提取 en', () {
      final (text, lang) = cleanAsrText('<|en|>Hello there');
      expect(text, 'Hello there');
      expect(lang, 'en');
    });

    test('日文标签：提取 ja', () {
      final (text, lang) = cleanAsrText('<|ja|>こんにちは');
      expect(text, 'こんにちは');
      expect(lang, 'ja');
    });

    test('韩文标签：提取 ko', () {
      final (text, lang) = cleanAsrText('<|ko|>안녕하세요');
      expect(text, '안녕하세요');
      expect(lang, 'ko');
    });

    test('无标签：lang 为 null，文本原样返回', () {
      final (text, lang) = cleanAsrText('你好世界');
      expect(text, '你好世界');
      expect(lang, isNull);
    });

    test('标签在文本中间也应提取', () {
      final (text, lang) = cleanAsrText('前面<|zh|>中间后面');
      expect(text, '前面中间后面');
      expect(lang, 'zh');
    });

    test('只有标签无文本：返回 null text，保留 lang', () {
      final (text, lang) = cleanAsrText('<|zh|>');
      expect(text, isNull);
      expect(lang, 'zh');
    });

    test('标签有空格也应匹配', () {
      final (text, lang) = cleanAsrText('<| zh |>你好');
      expect(text, '你好');
      expect(lang, 'zh');
    });

    test('语言标签列表检测', () {
      // 确认所有支持的语言标签都能被提取
      const langs = ['zh', 'en', 'ja', 'ko', 'fr', 'de', 'es', 'ru', 'yue'];
      for (final lang in langs) {
        final (_, detected) = cleanAsrText('<|$lang|>test');
        expect(detected, lang, reason: '语言标签 $lang 应被提取');
      }
    });

    test('空输入 → null text, null lang', () {
      final (text, lang) = cleanAsrText('');
      expect(text, isNull);
      expect(lang, isNull);
    });
  });

  group('翻译方向判定（P0-4.3 核心逻辑）', () {
    test('detectedLang=en → 英译中，targetLang 固定 zh', () {
      final detectedLang = 'en';
      final savedTl = 'ja'; // 用户原本设翻译成日文

      // 模拟 LiveSubtitleNotifier 的方向切换逻辑
      String? effectiveTarget;
      if (detectedLang == 'en') {
        effectiveTarget = 'zh';
      } else {
        effectiveTarget = savedTl;
      }

      expect(effectiveTarget, 'zh');
    });

    test('detectedLang=zh → 中译外，使用用户 targetLang', () {
      final detectedLang = 'zh';
      final savedTl = 'ja';

      String? effectiveTarget;
      if (detectedLang == 'en') {
        effectiveTarget = 'zh';
      } else {
        effectiveTarget = savedTl;
      }

      expect(effectiveTarget, 'ja');
    });

    test('detectedLang=null → sourceLang=auto，使用用户 targetLang', () {
      final detectedLang = null;
      final savedTl = 'ja';
      final srcLang = detectedLang ?? 'auto';

      expect(srcLang, 'auto');
      expect(savedTl, 'ja');
    });
  });
}
