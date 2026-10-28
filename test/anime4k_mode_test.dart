import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/anime4k_mode.dart';

/// [Anime4kMode] 的映射正确性测试。
///
/// Anime4K 的 shader 顺序是**有严格语义**的（上游 Advanced 文档明确定义），
/// 顺序错了不会报错，只会让画质变差或白耗性能 —— 这类问题几乎无法靠
/// 肉眼发现。所以把规则固化成测试。
void main() {
  group('基本属性', () {
    test('off 不需要 gpu-next', () {
      expect(Anime4kMode.off.needsGpuNext, isFalse);
    });

    test('其它档位都需要 gpu-next', () {
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.needsGpuNext, isTrue, reason: '${m.id} 应该需要 gpu-next');
      }
    });

    test('off 没有 shader、负载为 0', () {
      expect(Anime4kMode.off.shaderChain, isEmpty);
      expect(Anime4kMode.off.gpuWeight, 0);
    });

    test('非 off 档都有 shader 且负载 > 0', () {
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.shaderChain, isNotEmpty, reason: '${m.id} 没有 shader');
        expect(m.gpuWeight, greaterThan(0), reason: '${m.id} 负载应为正');
      }
    });
  });

  group('shader 链必须遵守上游规则', () {
    test('每个链都以 Clamp_Highlights 开头', () {
      // 上游 Best Practices：建议总是放在最前，防止 overshoot / ringing
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.shaderChain.first, 'Anime4K_Clamp_Highlights.glsl',
            reason: '${m.id} 的第一项应该是 Clamp_Highlights');
      }
    });

    test('Restore / Denoise 必须出现在第一个纯 Upscale 之前', () {
      // 上游规则：如果不是以 Restore 开头，就必须用 Upscale_Denoise 开头。
      // 先放大再修复是错的 —— 放大后的伪影更难修，且耗时 4 倍。
      //
      // ⚠ Upscale_Denoise 文件名里同时含 "Upscale" 和 "Denoise"，
      // 它本身承担「降噪 + 放大」两件事，判断「纯 Upscale」时要排除。
      bool isPureUpscale(String s) =>
          s.contains('Upscale') &&
          !s.contains('Denoise') &&
          !s.contains('Downscale') &&
          !s.contains('Restore');

      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        final chain = m.shaderChain;
        final firstPureUpscale = chain.indexWhere(isPureUpscale);
        if (firstPureUpscale < 0) continue;

        final firstRestoreOrDenoise = chain.indexWhere((s) =>
            s.contains('Restore') ||
            s.contains('Denoise') ||
            s.contains('Deblur'));
        expect(firstRestoreOrDenoise, greaterThanOrEqualTo(0),
            reason: '${m.id} 缺少 Restore/Denoise');
        expect(firstRestoreOrDenoise, lessThanOrEqualTo(firstPureUpscale),
            reason: '${m.id} 的 Restore/Denoise 必须在纯 Upscale 之前');
      }
    });

    test('每个链至少有一个 Upscale', () {
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.shaderChain.any((s) => s.contains('Upscale')), isTrue,
            reason: '${m.id} 没有放大步骤');
      }
    });

    test('AutoDownscalePre 只能出现在两次 Upscale 之间', () {
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        final chain = m.shaderChain;
        for (var i = 0; i < chain.length; i++) {
          if (!chain[i].contains('AutoDownscalePre')) continue;
          final hasUpscaleBefore = chain
              .take(i)
              .any((s) => s.contains('Upscale') && !s.contains('Downscale'));
          final hasUpscaleAfter = chain
              .skip(i + 1)
              .any((s) => s.contains('Upscale') && !s.contains('Downscale'));
          expect(hasUpscaleBefore && hasUpscaleAfter, isTrue,
              reason: '${m.id} 的 AutoDownscalePre(位置$i) 前后都必须有 Upscale');
        }
      }
    });

    test('链内没有重复 shader（上游硬规则）', () {
      // 上游原话："You can only use each shader file once. Using the same
      // file two or more times causes buggy behaviour and loss of
      // performance."
      for (final m in Anime4kMode.values) {
        final c = m.shaderChain;
        expect(c.length, c.toSet().length, reason: '${m.id} 有重复项');
      }
    });

    test('所有文件名都以 .glsl 结尾且不含路径分隔符', () {
      for (final m in Anime4kMode.values) {
        for (final s in m.shaderChain) {
          expect(s.endsWith('.glsl'), isTrue, reason: '$s 应该以 .glsl 结尾');
          expect(s.contains('/'), isFalse, reason: '$s 不该含路径分隔符');
        }
      }
    });

    test('GPU 负载不超过 512（避免算出离谱值）', () {
      for (final m in Anime4kMode.values) {
        expect(m.gpuWeight, lessThanOrEqualTo(512), reason: m.id);
      }
    });
  });

  group('档位语义', () {
    test('Mode A 档用 Restore_CNN（非 Soft）', () {
      for (final m in [
        Anime4kMode.modeAS,
        Anime4kMode.modeAM,
        Anime4kMode.modeAL,
        Anime4kMode.modeAVL,
        Anime4kMode.modeAUL,
      ]) {
        final c = m.shaderChain;
        expect(c.any((s) => s.contains('Restore_CNN_')), isTrue,
            reason: '${m.id} 应该有 Restore_CNN');
        expect(c.any((s) => s.contains('Restore_CNN_Soft')), isFalse,
            reason: '${m.id} 不该有 Restore_CNN_Soft');
      }
    });

    test('Mode B 档用 Restore_CNN_Soft', () {
      for (final m in [
        Anime4kMode.modeBS,
        Anime4kMode.modeBM,
        Anime4kMode.modeBL,
      ]) {
        expect(m.shaderChain.any((s) => s.contains('Restore_CNN_Soft')), isTrue,
            reason: '${m.id} 应该有 Restore_CNN_Soft');
      }
    });

    test('Mode C 档用 Upscale_Denoise', () {
      for (final m in [
        Anime4kMode.modeCS,
        Anime4kMode.modeCM,
        Anime4kMode.modeCL,
      ]) {
        expect(m.shaderChain.any((s) => s.contains('Upscale_Denoise')), isTrue,
            reason: '${m.id} 应该有 Upscale_Denoise');
      }
    });

    test('light 不含任何 CNN', () {
      final c = Anime4kMode.light.shaderChain;
      expect(c.any((s) => s.contains('CNN')), isFalse);
      expect(c.any((s) => s.contains('DoG')), isTrue);
    });

    test('GAN 档都含 GAN 变体 shader', () {
      for (final m in [
        Anime4kMode.ganS,
        Anime4kMode.ganM,
        Anime4kMode.ganL,
        Anime4kMode.ganUUL,
      ]) {
        expect(m.shaderChain.any((s) => s.contains('GAN')), isTrue,
            reason: '${m.id} 应该有 GAN shader');
      }
    });

    test('同一模式内 GPU 负载随 CNN 档递增', () {
      expect(Anime4kMode.modeAS.gpuWeight,
          lessThan(Anime4kMode.modeAM.gpuWeight));
      expect(Anime4kMode.modeAM.gpuWeight,
          lessThan(Anime4kMode.modeAL.gpuWeight));
      expect(Anime4kMode.modeAL.gpuWeight,
          lessThan(Anime4kMode.modeAVL.gpuWeight));
      expect(Anime4kMode.modeAVL.gpuWeight,
          lessThan(Anime4kMode.modeAUL.gpuWeight));

      expect(Anime4kMode.modeBS.gpuWeight,
          lessThan(Anime4kMode.modeBM.gpuWeight));
      expect(Anime4kMode.modeBM.gpuWeight,
          lessThan(Anime4kMode.modeBL.gpuWeight));

      expect(Anime4kMode.modeCS.gpuWeight,
          lessThan(Anime4kMode.modeCM.gpuWeight));
      expect(Anime4kMode.modeCM.gpuWeight,
          lessThan(Anime4kMode.modeCL.gpuWeight));
    });

    test('light 是最低档，负载最小', () {
      final others = Anime4kMode.values
          .where((m) => m != Anime4kMode.off && m != Anime4kMode.light);
      for (final m in others) {
        expect(Anime4kMode.light.gpuWeight, lessThanOrEqualTo(m.gpuWeight),
            reason: 'light 应该比 ${m.id} 轻');
      }
    });
  });

  group('自动降档路径', () {
    test('off 和 light 没有更低的档', () {
      expect(Anime4kMode.off.lowerTier, isNull);
      expect(Anime4kMode.light.lowerTier, isNull);
    });

    test('从任意非 off 档一直降都能到 light 且不死循环', () {
      for (final start in Anime4kMode.values) {
        if (start == Anime4kMode.off) continue;
        var cur = start;
        var steps = 0;
        while (cur.lowerTier != null) {
          final next = cur.lowerTier!;
          expect(next.gpuWeight, lessThan(cur.gpuWeight),
              reason: '${cur.id} → ${next.id} 负载必须下降');
          cur = next;
          if (++steps > 20) fail('降档链过长，可能有环: ${start.id}');
        }
        expect(cur, Anime4kMode.light,
            reason: '${start.id} 最终应降到 light');
      }
    });

    test('降档不跨模式（A 不会直接跳到 B）', () {
      // 跨模式会改变画质风格，用户会困惑
      for (final m in [
        Anime4kMode.modeAM,
        Anime4kMode.modeAL,
        Anime4kMode.modeAVL,
        Anime4kMode.modeAUL,
      ]) {
        final lower = m.lowerTier!;
        expect(lower == Anime4kMode.light || lower.id.startsWith('a_'), isTrue,
            reason: '${m.id} 降到了 ${lower.id}，不该跨模式');
      }
      for (final m in [Anime4kMode.modeBM, Anime4kMode.modeBL]) {
        final lower = m.lowerTier!;
        expect(lower == Anime4kMode.light || lower.id.startsWith('b_'), isTrue,
            reason: '${m.id} 降到了 ${lower.id}');
      }
    });

    test('isHeavy 与 gpuWeight 阈值一致', () {
      for (final m in Anime4kMode.values) {
        expect(m.isHeavy, m.gpuWeight >= 16, reason: m.id);
      }
      expect(Anime4kMode.light.isHeavy, isFalse);
      expect(Anime4kMode.modeAS.isHeavy, isFalse);
      expect(Anime4kMode.modeAL.isHeavy, isTrue);
    });
  });

  group('id 与持久化', () {
    test('每个档位 id 唯一', () {
      final ids = Anime4kMode.values.map((m) => m.id).toSet();
      expect(ids.length, Anime4kMode.values.length);
    });

    test('fromId 能还原所有档位', () {
      for (final m in Anime4kMode.values) {
        expect(Anime4kModeX.fromId(m.id), m);
      }
    });

    test('未知 id / null 回退到 off', () {
      expect(Anime4kModeX.fromId('nonsense'), Anime4kMode.off);
      expect(Anime4kModeX.fromId(null), Anime4kMode.off);
      expect(Anime4kModeX.fromId(''), Anime4kMode.off);
    });

    test('id 是稳定字符串（改了会让老用户设置失效）', () {
      expect(Anime4kMode.off.id, 'off');
      expect(Anime4kMode.light.id, 'light');
      expect(Anime4kMode.modeAS.id, 'a_s');
      expect(Anime4kMode.modeAM.id, 'a_m');
      expect(Anime4kMode.modeAL.id, 'a_l');
      expect(Anime4kMode.modeAVL.id, 'a_vl');
      expect(Anime4kMode.modeAUL.id, 'a_ul');
      expect(Anime4kMode.modeBS.id, 'b_s');
      expect(Anime4kMode.modeCS.id, 'c_s');
      expect(Anime4kMode.ganS.id, 'gan_s');
      expect(Anime4kMode.ganUUL.id, 'gan_uul');
    });
  });

  group('平台可用性', () {
    test('off 在所有平台可用', () {
      expect(Anime4kMode.off.isAvailable, isTrue);
    });

    test('测试环境（非 Android）下非 off 档不可用', () {
      expect(anime4kSupported, isFalse);
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.isAvailable, isFalse, reason: '${m.id} 不该在非 Android 可用');
      }
    });
  });

  group('展示文案', () {
    test('三种文案都非空', () {
      for (final m in Anime4kMode.values) {
        expect(m.label, isNotEmpty);
        expect(m.shortLabel, isNotEmpty);
        expect(m.description, isNotEmpty);
      }
    });

    test('shortLabel 不比 label 长', () {
      for (final m in Anime4kMode.values) {
        expect(m.shortLabel.length, lessThanOrEqualTo(m.label.length),
            reason: m.id);
      }
    });

    test('label 全都不重复（选择器里要能区分）', () {
      final labels = Anime4kMode.values.map((m) => m.label).toList();
      expect(labels.length, labels.toSet().length);
    });
  });
}
