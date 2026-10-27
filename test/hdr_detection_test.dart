import 'package:flutter_test/flutter_test.dart';

/// HDR 类型判定的回归测试。
///
/// 背景：v1.1.6 存在「有的视频色彩不对」的问题，根因是 `hdrType` 判定把
/// 「bt.2020 色域 + SDR 传递函数」的片源误判成 HDR10，进而套上 bt.2390
/// 色调映射 —— 画面发灰、对比度变低。
///
/// 这里把判定规则固化成纯函数复刻，锁住以下行为：
///   * PQ → HDR10，PQ + 杜比 codec → 杜比视界
///   * HLG → HLG
///   * 明确的 SDR 传递函数（bt.1886/bt.709/...) → null，**即使色域是 bt.2020**
///   * 只有「传递函数缺失 + bt.2020 色域」才兜底成 HDR10
void main() {
  // 与 PlayerState.hdrType 保持一致的判定逻辑
  String? hdrType({
    String? transferFunction,
    String? colorPrimaries,
    String? videoCodec,
  }) {
    final tf = (transferFunction ?? '').toLowerCase();
    final cp = (colorPrimaries ?? '').toLowerCase();
    final codec = (videoCodec ?? '').toLowerCase();
    bool codecIsDolby() =>
        codec.startsWith('dvhe') ||
        codec.startsWith('dvh1') ||
        codec.startsWith('dav1');

    if (tf.contains('pq')) return codecIsDolby() ? '杜比视界' : 'HDR10';
    // HLG 的简称与标准技术名（arib-std-b67 不含 "hlg" 字样）
    if (tf.contains('hlg') || tf.contains('arib-std-b67')) return 'HLG';
    if (codecIsDolby()) return '杜比视界';

    if (tf.contains('1886') ||
        tf.contains('709') ||
        tf.contains('170m') ||
        tf.contains('240m') ||
        tf.contains('srgb') ||
        tf.contains('linear')) {
      return null;
    }

    if (cp.contains('2020')) return 'HDR10';
    return null;
  }

  group('HDR 判定', () {
    test('PQ 传递函数 → HDR10', () {
      expect(
        hdrType(transferFunction: 'pq', colorPrimaries: 'bt.2020'),
        'HDR10',
      );
    });

    test('PQ + 杜比 codec → 杜比视界', () {
      expect(
        hdrType(
          transferFunction: 'pq',
          colorPrimaries: 'bt.2020',
          videoCodec: 'dvhe.05',
        ),
        '杜比视界',
      );
    });

    test('HLG → HLG', () {
      expect(
        hdrType(transferFunction: 'arib-std-b67', colorPrimaries: 'bt.2020'),
        'HLG',
      );
    });

    test('杜比 codec（tf 未到）→ 杜比视界', () {
      expect(hdrType(videoCodec: 'dvh1.08'), '杜比视界');
    });
  });

  group('SDR 判定（色彩问题的核心）', () {
    test('bt.1886 + bt.709 → SDR', () {
      expect(
        hdrType(transferFunction: 'bt.1886', colorPrimaries: 'bt.709'),
        isNull,
      );
    });

    test('smpte170m（老 DV/电视源）→ SDR', () {
      expect(
        hdrType(transferFunction: 'smpte170m', colorPrimaries: 'bt.601'),
        isNull,
      );
    });

    test('⭐ bt.2020 色域 + SDR 传递函数 → 必须判 SDR，不能误判 HDR10', () {
      // 这是修复的 bug：UHD 广播允许 bt.2020 + SDR，
      // 旧逻辑会因为 cp 含 2020 而误判成 HDR10，套上 bt.2390 后画面发灰。
      expect(
        hdrType(transferFunction: 'bt.1886', colorPrimaries: 'bt.2020'),
        isNull,
      );
      expect(
        hdrType(transferFunction: 'bt.709', colorPrimaries: 'bt.2020'),
        isNull,
      );
    });

    test('元数据未到（tf/cp 都空）→ SDR（不猜）', () {
      expect(hdrType(), isNull);
    });

    test('只有 bt.2020、无传递函数 → 弱兜底 HDR10', () {
      expect(hdrType(colorPrimaries: 'bt.2020'), 'HDR10');
    });
  });
}
