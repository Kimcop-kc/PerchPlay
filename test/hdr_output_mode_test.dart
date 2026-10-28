import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/hdr_output_mode.dart';

/// [HdrOutputMode] 的映射正确性测试。
///
/// 这些参数直接决定 mpv 的渲染行为，写错会导致偏色/过曝，
/// 而且**很难通过肉眼发现**（画面「看起来还行」但实际不对）。
/// 所以把官方 hdr-toys.conf 的取值固化成测试。
void main() {
  group('HdrOutputMode 基本属性', () {
    test('off 不需要 gpu-next', () {
      expect(HdrOutputMode.off.needsGpuNext, isFalse);
    });

    test('其它所有档位都需要 gpu-next', () {
      for (final m in HdrOutputMode.values) {
        if (m == HdrOutputMode.off) continue;
        expect(m.needsGpuNext, isTrue, reason: '${m.id} 应该需要 gpu-next');
      }
    });

    test('off 不设 target-prim / target-trc', () {
      expect(HdrOutputMode.off.targetPrim, isNull);
      expect(HdrOutputMode.off.targetTrc, isNull);
    });

    test('所有非 off 档位都设成 bt.2020 色域', () {
      for (final m in HdrOutputMode.values) {
        if (m == HdrOutputMode.off) continue;
        expect(m.targetPrim, 'bt.2020', reason: '${m.id} 的 target-prim');
      }
    });

    test('传递函数与档位一致', () {
      expect(HdrOutputMode.bt2100Pq.targetTrc, 'pq');
      expect(HdrOutputMode.bt2100Hlg.targetTrc, 'hlg');
      expect(HdrOutputMode.bt2020.targetTrc, 'bt.1886');
      expect(HdrOutputMode.linear.targetTrc, 'linear');
    });
  });

  group('colorspace-hint 只在真 HDR 传递函数上开启', () {
    test('PQ 开启', () {
      expect(HdrOutputMode.bt2100Pq.colorspaceHint, isTrue);
    });

    test('HLG 开启', () {
      expect(HdrOutputMode.bt2100Hlg.colorspaceHint, isTrue);
    });

    test('bt2020（SDR 伽马）不开启', () {
      // 开了会让系统误以为要输出 HDR，状态栏/亮度行为异常
      expect(HdrOutputMode.bt2020.colorspaceHint, isFalse);
    });

    test('linear 不开启', () {
      expect(HdrOutputMode.linear.colorspaceHint, isFalse);
    });

    test('off 不开启', () {
      expect(HdrOutputMode.off.colorspaceHint, isFalse);
    });
  });

  group('shader 链', () {
    test('off 没有 shader', () {
      expect(HdrOutputMode.off.shaderChain, isEmpty);
    });

    test('PQ 链先 clip 再 pq_inv（PQ → 线性）', () {
      // 顺序与上游 hdr-toys.conf 一致：先裁到合法范围，再做传递函数反转。
      // 反过来的话超范围值会在 pq_inv 里被放大成 NaN/溢出。
      final chain = HdrOutputMode.bt2100Pq.shaderChain;
      expect(chain.first, 'utils/clip_both.glsl');
      expect(chain[1], 'transfer-function/pq_inv.glsl');
    });

    test('HLG 链先 clip 再 hlg_inv', () {
      final chain = HdrOutputMode.bt2100Hlg.shaderChain;
      expect(chain.first, 'utils/clip_both.glsl');
      expect(chain[1], 'transfer-function/hlg_inv.glsl');
    });

    test('PQ 与 HLG 只有传递函数反转那一步不同', () {
      final pq = HdrOutputMode.bt2100Pq.shaderChain;
      final hlg = HdrOutputMode.bt2100Hlg.shaderChain;
      expect(pq.length, hlg.length);
      final diff = <int>[];
      for (var i = 0; i < pq.length; i++) {
        if (pq[i] != hlg[i]) diff.add(i);
      }
      expect(diff.length, 1, reason: '只应有 1 处差异，实际: $diff');
      expect(pq[diff.first], contains('pq_inv'));
      expect(hlg[diff.first], contains('hlg_inv'));
    });

    test('PQ / HLG 链的最后一步都是 bt1886（回到 SDR 伽马）', () {
      expect(HdrOutputMode.bt2100Pq.shaderChain.last,
          'transfer-function/bt1886.glsl');
      expect(HdrOutputMode.bt2100Hlg.shaderChain.last,
          'transfer-function/bt1886.glsl');
    });

    test('PQ 链包含 tone-mapping + gamut-mapping', () {
      final chain = HdrOutputMode.bt2100Pq.shaderChain;
      expect(chain.any((s) => s.startsWith('tone-mapping/')), isTrue);
      expect(chain.any((s) => s.startsWith('gamut-mapping/')), isTrue);
    });

    test('所有链里的路径都是相对路径（不含前导 /）', () {
      for (final m in HdrOutputMode.values) {
        for (final s in m.shaderChain) {
          expect(s.startsWith('/'), isFalse, reason: '$s 应该是相对路径');
          expect(s.endsWith('.glsl'), isTrue, reason: '$s 应该是 .glsl');
        }
      }
    });

    test('没有重复的 shader', () {
      for (final m in HdrOutputMode.values) {
        final chain = m.shaderChain;
        expect(chain.length, chain.toSet().length,
            reason: '${m.id} 的链里有重复项');
      }
    });
  });

  group('shader 参数', () {
    test('off 没有参数', () {
      expect(HdrOutputMode.off.shaderOpts, isEmpty);
    });

    test('PQ 带上游推荐的 auto_exposure_limit_positive', () {
      expect(HdrOutputMode.bt2100Pq.shaderOpts,
          contains('auto_exposure_limit_positive=1.02'));
    });

    test('linear 关闭 metering 的时间/空间稳定（及时响应）', () {
      final opts = HdrOutputMode.linear.shaderOpts;
      expect(opts, contains('spatial_stable_level=0'));
      expect(opts, contains('temporal_stable_duration=0'));
      expect(opts, contains('enable_metering=1'));
    });
  });

  group('id 映射与持久化', () {
    test('每个档位的 id 唯一', () {
      final ids = HdrOutputMode.values.map((m) => m.id).toSet();
      expect(ids.length, HdrOutputMode.values.length);
    });

    test('fromId 能还原所有档位', () {
      for (final m in HdrOutputMode.values) {
        expect(HdrOutputModeX.fromId(m.id), m, reason: 'id=${m.id}');
      }
    });

    test('未知 id 回退到 off', () {
      expect(HdrOutputModeX.fromId('nonsense'), HdrOutputMode.off);
      expect(HdrOutputModeX.fromId(null), HdrOutputMode.off);
      expect(HdrOutputModeX.fromId(''), HdrOutputMode.off);
    });

    test('id 是稳定字符串，不随枚举顺序变化', () {
      // 持久化靠这个值，改了会让老用户的设置失效
      expect(HdrOutputMode.off.id, 'off');
      expect(HdrOutputMode.bt2100Pq.id, 'bt2100_pq');
      expect(HdrOutputMode.bt2100Hlg.id, 'bt2100_hlg');
      expect(HdrOutputMode.bt2020.id, 'bt2020');
      expect(HdrOutputMode.linear.id, 'linear');
    });
  });

  group('平台可用性', () {
    test('off 在所有平台都可用', () {
      // 关档不能禁用，否则用户没法退回安全状态
      expect(HdrOutputMode.off.isAvailable, isTrue);
    });

    test('非 off 档的可用性跟随 hdrOutputModeSupported', () {
      // 测试环境（dart vm on Windows）不是 Android，所以应当全部不可用
      for (final m in HdrOutputMode.values) {
        if (m == HdrOutputMode.off) continue;
        expect(m.isAvailable, hdrOutputModeSupported,
            reason: '${m.id}.isAvailable 应与 hdrOutputModeSupported 一致');
      }
    });

    test('测试环境下（非 Android）hdrOutputModeSupported 为 false', () {
      // 这台机器跑 flutter test 是 Windows/Linux/macOS，不是 Android
      expect(hdrOutputModeSupported, isFalse);
    });

    test('非 off 档在非 Android 上不可用', () {
      for (final m in HdrOutputMode.values) {
        if (m == HdrOutputMode.off) continue;
        expect(m.isAvailable, isFalse, reason: '${m.id} 不该在非 Android 可用');
      }
    });
  });

  group('展示文案', () {
    test('label / shortLabel / description 都非空', () {
      for (final m in HdrOutputMode.values) {
        expect(m.label, isNotEmpty);
        expect(m.shortLabel, isNotEmpty);
        expect(m.description, isNotEmpty);
      }
    });

    test('shortLabel 比 label 短（设置页放得下）', () {
      for (final m in HdrOutputMode.values) {
        expect(m.shortLabel.length, lessThanOrEqualTo(m.label.length),
            reason: '${m.id}: shortLabel="${m.shortLabel}" '
                'label="${m.label}"');
      }
    });
  });
}
