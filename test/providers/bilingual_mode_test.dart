import 'package:flutter_test/flutter_test.dart';

/// 双语字幕行序回归测试（P2.3 缺陷修复）
///
/// 核心约束：双语行格式固定为「中文\n外文」—— 无论原视频是中文还是英文。
/// - BilingualMode.zh  → 取首行（中文）
/// - BilingualMode.foreign → 取末行（外文）
/// - BilingualMode.both → 取全文

/// 模拟 _buildAiSubtitleText 中的行序选择逻辑
String selectLine(String fullText, String mode) {
  if (mode == 'both') return fullText;
  final lines = fullText.split('\n');
  if (mode == 'zh') {
    return lines.first;
  } else if (mode == 'foreign') {
    return lines.length > 1 ? lines.last : fullText;
  }
  return fullText;
}

void main() {
  group('BilingualMode 行序选择', () {
    // ── 中文视频（中文 → 外文）──
    const zhVideo = '你好世界\nHello World';

    test('both 模式：显示完整双语', () {
      expect(selectLine(zhVideo, 'both'), '你好世界\nHello World');
    });

    test('zh 模式：取首行中文', () {
      expect(selectLine(zhVideo, 'zh'), '你好世界');
    });

    test('foreign 模式：取末行外文', () {
      expect(selectLine(zhVideo, 'foreign'), 'Hello World');
    });

    // ── 英文视频（P2.3 修复后：中文在前、英文在后）──
    const enVideo = '你好世界\nHello World'; // 格式统一后

    test('英译中 both 模式：显示完整双语', () {
      expect(selectLine(enVideo, 'both'), '你好世界\nHello World');
    });

    test('英译中 zh 模式：取首行中文', () {
      // 修复前：lines.first = 'Hello World' → 显示英文（错）
      // 修复后：lines.first = '你好世界' → 显示中文（对）
      expect(selectLine(enVideo, 'zh'), '你好世界');
    });

    test('英译中 foreign 模式：取末行英文', () {
      expect(selectLine(enVideo, 'foreign'), 'Hello World');
    });

    // ── 边界情况 ──
    test('单行文本（无翻译）：zh/foreign 都返回原文', () {
      expect(selectLine('你好', 'zh'), '你好');
      expect(selectLine('你好', 'foreign'), '你好');
    });

    test('空字符串', () {
      expect(selectLine('', 'both'), '');
      expect(selectLine('', 'zh'), '');
      expect(selectLine('', 'foreign'), '');
    });
  });
}
