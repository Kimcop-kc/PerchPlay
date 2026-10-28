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
      // ⚠ 注意 Upscale_Denoise 这个文件名里同时含 "Upscale" 和 "Denoise"，
      // 它本身就承担「降噪 + 放大」两件事，所以判断「第一个纯 Upscale」
      // 时要把它排除掉，否则会误判成「Upscale 出现在 Denoise 之前」。
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

    test('每个链至少有一个 Upscale（模式定义要求）', () {
      for (final m in Anime4kMode.values) {
        if (m == Anime4kMode.off) continue;
        expect(m.shaderChain.any((s) => s.contains('Upscale')), isTrue,
            reason: '${m.id} 没有放大步骤');
      }
    });

    test('AutoDownscalePre 只能出现在两次 Upscale 之间', () {
      // 上游：它的作用是把第一次放大后的结果先缩到屏宽，
      // 让第二次放大正好命中屏幕，省 GPU。
      // 放在别处只会白白多一次缩放。
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

    test('链内没有重复 shader', () {
      // 上游明确说：同一个文件用两次会导致 bug 和性能损失
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

    test('只用了 S/M/L 三档，没有 VL/UL/UUL/GAN', () {
      // 手机 GPU 带不动这些：单个 shader 就 143KB~1MB，且官方数据
      // （Vega64 桌面卡）显示它们在 1080p→4K 已吃满 24fps 预算。
      for (final m in Anime4kMode.values) {
        for (final s in m.shaderChain) {
          for (final banned in ['_VL', '_UL', '_UUL', '_GAN']) {
            expect(s.contains(banned), isFalse, reason: '$s 不该用 $banned 档');
          }
        }
      }
    });
  });

  group('档位语义', () {
    test('standard 用的是 Mode A（Restore_CNN，非 Soft）', () {
      final c = Anime4kMode.standard.shaderChain;
      expect(c.any((s) => s.contains('Restore_CNN_S.glsl')), isTrue);
      expect(c.any((s) => s.contains('Restore_CNN_Soft')), isFalse);
    });

    test('restoreSoft 用的是 Restore_CNN_Soft（Mode B）', () {
      final c = Anime4kMode.restoreSoft.shaderChain;
      expect(c.any((s) => s.contains('Restore_CNN_Soft_S.glsl')), isTrue);
    });

    test('clean 用的是 Upscale_Denoise（Mode C）', () {
      final c = Anime4kMode.clean.shaderChain;
      expect(c.any((s) => s.contains('Upscale_Denoise')), isTrue);
    });

    test('light 不含任何 CNN（非 CNN 的极轻量方案）', () {
      final c = Anime4kMode.light.shaderChain;
      expect(c.any((s) => s.contains('CNN')), isFalse,
          reason: 'light 档应该只用非 CNN shader');
      expect(c.any((s) => s.contains('DoG')), isTrue);
    });

    test('GPU 负载随画质档递增：light < standard < high < ultra', () {
      expect(Anime4kMode.light.gpuWeight,
          lessThan(Anime4kMode.standard.gpuWeight));
      expect(Anime4kMode.standard.gpuWeight,
          lessThan(Anime4kMode.high.gpuWeight));
      expect(Anime4kMode.high.gpuWeight,
          lessThan(Anime4kMode.ultra.gpuWeight));
    });

    test('high / ultra 用的 CNN 档位逐级更高', () {
      expect(Anime4kMode.high.shaderChain.any((s) => s.contains('_M.glsl')),
          isTrue);
      expect(Anime4kMode.ultra.shaderChain.any((s) => s.contains('_L.glsl')),
          isTrue);
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

    test('id 是稳定字符串', () {
      expect(Anime4kMode.off.id, 'off');
      expect(Anime4kMode.light.id, 'light');
      expect(Anime4kMode.standard.id, 'standard');
      expect(Anime4kMode.high.id, 'high');
      expect(Anime4kMode.ultra.id, 'ultra');
      expect(Anime4kMode.restoreSoft.id, 'restore_soft');
      expect(Anime4kMode.clean.id, 'clean');
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
  });
}
