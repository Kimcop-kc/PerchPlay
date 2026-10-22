import 'package:flutter_test/flutter_test.dart';

/// 时间偏移计算测试（验证偏移方向）。
///
/// 偏移语义：正数 = 字幕延后（用更早的播放时间去匹配字幕），
/// 负数 = 字幕提前（用更晚的播放时间去匹配）。
/// 即：匹配时间 = 播放时间 - 偏移毫秒。
void main() {
  group('字幕时间偏移计算', () {
    Duration applyOffset(Duration playPos, int offsetMs) {
      return playPos - Duration(milliseconds: offsetMs);
    }

    test('零偏移：匹配时间等于播放时间', () {
      expect(
        applyOffset(const Duration(seconds: 10), 0),
        const Duration(seconds: 10),
      );
    });

    test('正偏移（字幕延后）：匹配时间提前', () {
      // 偏移 +1000ms = 字幕晚 1 秒，用播放时间 -1s 去匹配
      expect(
        applyOffset(const Duration(seconds: 10), 1000),
        const Duration(seconds: 9),
      );
    });

    test('负偏移（字幕提前）：匹配时间延后', () {
      // 偏移 -1000ms = 字幕早 1 秒，用播放时间 +1s 去匹配
      expect(
        applyOffset(const Duration(seconds: 10), -1000),
        const Duration(seconds: 11),
      );
    });

    test('偏移边界（±1000ms 内）', () {
      expect(
        applyOffset(const Duration(seconds: 5), 1000),
        const Duration(seconds: 4),
      );
      expect(
        applyOffset(const Duration(seconds: 5), -1000),
        const Duration(seconds: 6),
      );
    });
  });

  group('偏移显示格式', () {
    String formatOffset(int ms) {
      final sign = ms > 0 ? '+' : '';
      return '$sign${(ms / 1000).toStringAsFixed(2)}s';
    }

    test('正偏移带 + 号', () {
      expect(formatOffset(500), '+0.50s');
    });

    test('负偏移带 - 号', () {
      expect(formatOffset(-500), '-0.50s');
    });

    test('零偏移', () {
      expect(formatOffset(0), '0.00s');
    });
  });
}
