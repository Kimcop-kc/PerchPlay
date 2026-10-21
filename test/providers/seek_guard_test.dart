import 'package:flutter_test/flutter_test.dart';

/// Seek 竞态保护与钳位回归测试（P1-5/P1-7 缺陷修复）

/// 模拟 seekToken 竞态保护
class SeekGuard {
  int _seekToken = 0;

  int get token => _seekToken;

  int nextToken() => ++_seekToken;

  bool isValid(int token) => token == _seekToken;
}

/// seekTo 钳位逻辑
Duration clampSeekTarget(Duration target, Duration duration) {
  if (duration <= Duration.zero) return target;
  if (target < Duration.zero) return Duration.zero;
  if (target > duration) return duration;
  return target;
}

/// seekRelative 目标计算
Duration seekRelativeTarget(
  Duration currentPosition,
  int seconds,
  Duration duration,
) {
  if (duration <= Duration.zero) return currentPosition; // 时长未知，不跳
  final raw = currentPosition + Duration(seconds: seconds);
  if (raw < Duration.zero) return Duration.zero;
  if (raw > duration) return duration;
  return raw;
}

void main() {
  group('seekToken 竞态保护', () {
    test('旧 token 在新 seek 后无效', () {
      final guard = SeekGuard();
      final t1 = guard.nextToken(); // 1
      guard.nextToken(); // 2（新 seek 进来）
      expect(guard.isValid(t1), false);
    });

    test('最新 token 有效', () {
      final guard = SeekGuard();
      guard.nextToken(); // 1
      final t2 = guard.nextToken(); // 2
      expect(guard.isValid(t2), true);
    });
  });

  group('seekTo 钳位', () {
    final tenMin = const Duration(minutes: 10);

    test('目标在范围内 → 不钳位', () {
      expect(
        clampSeekTarget(const Duration(minutes: 5), tenMin),
        const Duration(minutes: 5),
      );
    });

    test('目标 > duration → 钳位到 duration', () {
      expect(
        clampSeekTarget(const Duration(minutes: 20), tenMin),
        tenMin,
      );
    });

    test('负目标 → 钳位到 0', () {
      expect(
        clampSeekTarget(const Duration(seconds: -3), tenMin),
        Duration.zero,
      );
    });

    test('duration=0（未知）→ 不钳位', () {
      expect(
        clampSeekTarget(const Duration(seconds: 30), Duration.zero),
        const Duration(seconds: 30),
      );
    });
  });

  group('seekRelative 目标计算', () {
    final fiveMin = const Duration(minutes: 5);
    final tenMin = const Duration(minutes: 10);

    test('前进 10s', () {
      expect(
        seekRelativeTarget(fiveMin, 10, tenMin),
        const Duration(minutes: 5, seconds: 10),
      );
    });

    test('后退 10s', () {
      expect(
        seekRelativeTarget(fiveMin, -10, tenMin),
        const Duration(minutes: 4, seconds: 50),
      );
    });

    test('后退超出开头 → 钳位到 0', () {
      expect(
        seekRelativeTarget(const Duration(seconds: 3), -10, tenMin),
        Duration.zero,
      );
    });

    test('前进超出结尾 → 钳位到 duration', () {
      expect(
        seekRelativeTarget(
          const Duration(minutes: 9, seconds: 50),
          30,
          tenMin,
        ),
        tenMin,
      );
    });

    test('duration=0 → 返回当前位置（不跳）', () {
      expect(
        seekRelativeTarget(fiveMin, 10, Duration.zero),
        fiveMin,
      );
    });
  });
}
