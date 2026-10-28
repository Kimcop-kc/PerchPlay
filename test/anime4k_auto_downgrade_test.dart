import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/anime4k_mode.dart';

/// 自动降档的**纯逻辑**测试。
///
/// [Anime4kAutoDowngrade] 本身依赖 mpv 属性（无法在单元测试里跑），
/// 但它的核心决策全部来自 [Anime4kMode.lowerTier] —— 那个是纯函数，
/// 可以完整覆盖。
///
/// 这里验证的是「降档路径本身是否安全」：
///   - 任何档位最终都能降到最低档，且不会死循环
///   - 负载严格递减（否则降档可能反而更卡）
///   - 不跨模式（A 不会突然变成 B）
void main() {
  group('降档路径安全性', () {
    test('从任何非 off 档出发都能终止', () {
      for (final start in Anime4kMode.values) {
        if (start == Anime4kMode.off) continue;
        var cur = start;
        var guard = 0;
        while (cur.lowerTier != null) {
          cur = cur.lowerTier!;
          if (++guard > 30) {
            fail('${start.id} 的降档链没有终点（可能有环）');
          }
        }
        expect(guard, lessThan(30));
      }
    });

    test('每一级降档 GPU 负载都严格下降', () {
      for (final m in Anime4kMode.values) {
        final lower = m.lowerTier;
        if (lower == null) continue;
        expect(lower.gpuWeight, lessThan(m.gpuWeight),
            reason: '${m.id}(${m.gpuWeight}) → ${lower.id}(${lower.gpuWeight})'
                ' 负载没有下降，降档就失去意义');
      }
    });

    test('最终都落到 light（或 off）', () {
      for (final start in Anime4kMode.values) {
        if (start == Anime4kMode.off) continue;
        var cur = start;
        while (cur.lowerTier != null) {
          cur = cur.lowerTier!;
        }
        expect(cur, Anime4kMode.light,
            reason: '${start.id} 最终降到了 ${cur.id}，应为 light');
      }
    });

    test('off 与 light 是终止态', () {
      expect(Anime4kMode.off.lowerTier, isNull);
      expect(Anime4kMode.light.lowerTier, isNull);
    });
  });

  group('降档不跨模式', () {
    test('Mode A 的降档目标只在 A 内或 light', () {
      for (final m in [
        Anime4kMode.modeAS,
        Anime4kMode.modeAM,
        Anime4kMode.modeAL,
        Anime4kMode.modeAVL,
        Anime4kMode.modeAUL,
      ]) {
        final lower = m.lowerTier!;
        final ok = lower == Anime4kMode.light || lower.id.startsWith('a_');
        expect(ok, isTrue, reason: '${m.id} 降到了 ${lower.id}');
      }
    });

    test('Mode B 的降档目标只在 B 内或 light', () {
      for (final m in [
        Anime4kMode.modeBS,
        Anime4kMode.modeBM,
        Anime4kMode.modeBL,
      ]) {
        final lower = m.lowerTier!;
        final ok = lower == Anime4kMode.light || lower.id.startsWith('b_');
        expect(ok, isTrue, reason: '${m.id} 降到了 ${lower.id}');
      }
    });

    test('Mode C 的降档目标只在 C 内或 light', () {
      for (final m in [
        Anime4kMode.modeCS,
        Anime4kMode.modeCM,
        Anime4kMode.modeCL,
      ]) {
        final lower = m.lowerTier!;
        final ok = lower == Anime4kMode.light || lower.id.startsWith('c_');
        expect(ok, isTrue, reason: '${m.id} 降到了 ${lower.id}');
      }
    });

    test('GAN 档降档时先留在 GAN 内，再退回 CNN 的标准档', () {
      // GAN 用户是从最高画质往下试的，应先把 GAN 档走完再换风格
      expect(Anime4kMode.ganUUL.lowerTier, Anime4kMode.ganL);
      expect(Anime4kMode.ganL.lowerTier, Anime4kMode.ganM);
      expect(Anime4kMode.ganM.lowerTier, Anime4kMode.ganS);
      // GAN-S 之后才落回 Mode A 的 S 档
      expect(Anime4kMode.ganS.lowerTier, Anime4kMode.modeAS);
    });
  });

  group('降档链逐级对应', () {
    test('Mode A 逐级降：UL → VL → L → M → S → light', () {
      expect(Anime4kMode.modeAUL.lowerTier, Anime4kMode.modeAVL);
      expect(Anime4kMode.modeAVL.lowerTier, Anime4kMode.modeAL);
      expect(Anime4kMode.modeAL.lowerTier, Anime4kMode.modeAM);
      expect(Anime4kMode.modeAM.lowerTier, Anime4kMode.modeAS);
      expect(Anime4kMode.modeAS.lowerTier, Anime4kMode.light);
    });

    test('Mode B 逐级降：L → M → S → light', () {
      expect(Anime4kMode.modeBL.lowerTier, Anime4kMode.modeBM);
      expect(Anime4kMode.modeBM.lowerTier, Anime4kMode.modeBS);
      expect(Anime4kMode.modeBS.lowerTier, Anime4kMode.light);
    });

    test('Mode C 逐级降：L → M → S → light', () {
      expect(Anime4kMode.modeCL.lowerTier, Anime4kMode.modeCM);
      expect(Anime4kMode.modeCM.lowerTier, Anime4kMode.modeCS);
      expect(Anime4kMode.modeCS.lowerTier, Anime4kMode.light);
    });
  });

  group('高负载标记', () {
    test('isHeavy 只标记 gpuWeight >= 16 的档', () {
      for (final m in Anime4kMode.values) {
        expect(m.isHeavy, m.gpuWeight >= 16, reason: m.id);
      }
    });

    test('轻量档不被标为 heavy', () {
      expect(Anime4kMode.light.isHeavy, isFalse);
      expect(Anime4kMode.modeAS.isHeavy, isFalse);
      expect(Anime4kMode.modeAM.isHeavy, isFalse);
      expect(Anime4kMode.modeCS.isHeavy, isFalse);
    });

    test('高档确实被标为 heavy', () {
      expect(Anime4kMode.modeAL.isHeavy, isTrue);
      expect(Anime4kMode.modeAUL.isHeavy, isTrue);
      expect(Anime4kMode.ganUUL.isHeavy, isTrue);
    });
  });
}
