import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// GBK 编解码能力测试（字幕下载的编码处理依赖此能力）。
void main() {
  group('GBK 编解码', () {
    test('GBK 编码中文，再解码还原', () {
      const original = '你好世界，中文字幕';
      final encoded = gbk.encode(original);
      final decoded = gbk.decode(encoded);
      expect(decoded, original);
    });

    test('GBK 编码与 UTF-8 不同', () {
      const text = '你好';
      expect(gbk.encode(text), isNot(equals(utf8.encode(text))));
    });

    test('UTF-8 解码 GBK 字节会抛 FormatException', () {
      const text = '你好世界';
      final gbkBytes = gbk.encode(text);
      // 确认 GBK 字节不是合法 UTF-8
      expect(
        () => utf8.decode(gbkBytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('GBK 解码含英文字符', () {
      const mixed = 'English 中文 mixed';
      final decoded = gbk.decode(gbk.encode(mixed));
      expect(decoded, mixed);
    });
  });
}
