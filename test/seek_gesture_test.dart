import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/widgets/player/player_gesture_layer.dart';

/// 横向手势快进/快退的换算回归测试。
///
/// 背景：这里曾经两次调歪 ——
///  1. 「12% 时长 + 夹取」：长片划不动；
///  2. 「整屏 = 整个时长」：长片无法精调（2 小时片子 1px ≈ 18s，
///     用户反馈「只能一分钟起步」）。
///
/// 这些用例把「长片必须能按秒微调」钉死，避免以后又被改回去。
void main() {
  const screenWidth = 400.0; // 常见手机逻辑宽度
  const twoHours = 2 * 60 * 60 * 1000; // 7200s
  const tenMin = 10 * 60 * 1000; // 600s
  const fiveMin = 5 * 60 * 1000; // 300s

  group('seekDeltaSeconds - 长片（2 小时）按秒可调', () {
    test('轻微右滑 20px 只跳几秒，不是一分钟', () {
      final delta = seekDeltaSeconds(20, screenWidth, twoHours);
      expect(delta, greaterThan(0));
      // 20px 应该是个位数秒（0.22s/px × 20 ≈ 4.5s）
      expect(delta, lessThan(10));
    });

    test('滑到半屏（200px）约 45 秒', () {
      final delta = seekDeltaSeconds(screenWidth / 2, screenWidth, twoHours);
      expect(delta, closeTo(45, 1));
    });

    test('精细段是线性的：位移翻倍，跳转也翻倍', () {
      final d1 = seekDeltaSeconds(50, screenWidth, twoHours);
      final d2 = seekDeltaSeconds(100, screenWidth, twoHours);
      expect(d2 / d1, closeTo(2.0, 0.01));
    });

    test('左滑为负（快退）', () {
      final delta = seekDeltaSeconds(-20, screenWidth, twoHours);
      expect(delta, lessThan(0));
    });

    test('滑 2 屏足以覆盖整个时长', () {
      final delta = seekDeltaSeconds(screenWidth * 2, screenWidth, twoHours);
      // 允许略小于总时长（曲线渐近），但必须能到 95% 以上
      expect(delta, greaterThan(twoHours / 1000 * 0.95));
    });
  });

  group('seekDeltaSeconds - 短片（整屏 = 全长）', () {
    test('5 分钟视频滑满整屏 = 300 秒', () {
      final delta = seekDeltaSeconds(screenWidth, screenWidth, fiveMin);
      expect(delta, closeTo(300, 0.01));
    });

    test('10 分钟视频滑满整屏 = 600 秒（阈值内）', () {
      final delta = seekDeltaSeconds(screenWidth, screenWidth, tenMin);
      expect(delta, closeTo(600, 0.01));
    });

    test('短片 1px 精度仍在秒级（<2s/px）', () {
      final delta = seekDeltaSeconds(1, screenWidth, tenMin);
      expect(delta, lessThan(2));
    });
  });

  group('seekDeltaSeconds - 边界', () {
    test('屏宽为 0 时返回 0（避免除零）', () {
      expect(seekDeltaSeconds(50, 0, twoHours), 0);
    });

    test('时长为 0 时返回 0', () {
      expect(seekDeltaSeconds(50, screenWidth, 0), 0);
    });

    test('位移为 0 时返回 0', () {
      expect(seekDeltaSeconds(0, screenWidth, twoHours), 0);
    });
  });
}
