import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'anime4k_mode.dart';

/// Anime4K 的自动降档监控。
///
/// ## 为什么需要
///
/// 上游只给了 Vega64 桌面显卡的性能数据，手机端没有任何参考 ——
/// 芯片型号、驱动优化、发热降频、片源帧率都会影响实际能不能跑。
/// 与其猜「你的机器该用哪档」，不如让播放器自己测：
/// **掉帧了就往下降，稳住了就停**。
///
/// ## 判定依据
///
/// mpv 的 `frame-drop-count`（累计丢帧数）。每隔几秒采样一次，
/// 算**这段时间内新增的丢帧**，而不是看总量 —— 总量只增不减，
/// 用绝对值判断会永远「超标」。
///
/// 阈值为什么这么定：
///   - 24fps 视频每秒 24 帧，3 秒 72 帧。丢帧超过 3 帧（约 4%）
///     肉眼就能看出卡顿。
///   - 片源开头几秒常有解码器预热、缓冲导致的丢帧，属于正常，
///     所以先跳过前 [warmupSamples] 次采样。
///
/// ## 只降不升
///
/// 自动**升档**风险大：某次采样没掉帧不代表稳定（缓存命中的一瞬），
/// 反复升降会让画面抖。所以只自动降，升档交给用户手动。
/// 这条规则也让行为可预测 —— 用户选了「最高画质」，最差结果是
/// 自动降到能跑的档，而不是来回横跳。
class Anime4kAutoDowngrade {
  Anime4kAutoDowngrade({
    required this.onDowngrade,
    this.interval = const Duration(seconds: 3),
    this.warmupSamples = 2,
    this.dropBudget = 3,
    this.consecutiveOverBudget = 2,
    this.maxDowngrades = 4,
  });

  /// 检测到持续掉帧时回调（参数是建议的新档位）。
  final void Function(Anime4kMode next) onDowngrade;

  /// 采样间隔。
  final Duration interval;

  /// 跳过前几次采样（解码器预热 / 缓冲期）。
  final int warmupSamples;

  /// 单次采样周期内允许的丢帧数上限。
  final int dropBudget;

  /// 连续多少次超预算才降档（避免偶发波动误判）。
  final int consecutiveOverBudget;

  /// 最多自动降几档（防止一路降到关）。
  final int maxDowngrades;

  Timer? _timer;
  NativePlayer? _player;

  /// 上一次采样的累计丢帧数。null 表示还没采过。
  int? _lastDropCount;

  int _samples = 0;
  int _overBudget = 0;
  int _downgrades = 0;

  /// 当前监控的档位（由外部同步，避免对已经关掉的档位做降档）。
  Anime4kMode _currentMode = Anime4kMode.off;

  bool get isRunning => _timer != null;

  /// 开始监控。[mode] 是当前生效的档位，用于计算降档目标。
  void start(Player player, Anime4kMode mode) {
    stop();
    _currentMode = mode;

    // 只有真正需要 GPU 的档位才值得监控
    if (!mode.needsGpuNext || mode.lowerTier == null) {
      debugPrint('[A4K-Auto] ${mode.id} 无需监控（已是最低档或已关闭）');
      return;
    }

    final platform = player.platform;
    if (platform is! NativePlayer) {
      debugPrint('[A4K-Auto] 非 NativePlayer，跳过');
      return;
    }
    _player = platform;

    _lastDropCount = null;
    _samples = 0;
    _overBudget = 0;
    _downgrades = 0;

    _timer = Timer.periodic(interval, (_) => _tick());
    debugPrint('[A4K-Auto] 开始监控 ${mode.id}'
        '（每 ${interval.inSeconds}s 采样，预算 $dropBudget 帧）');
  }

  /// 档位变化时同步（用户手动切档后要按新档位重新判断）。
  void updateMode(Anime4kMode mode) {
    if (_currentMode == mode) return;
    _currentMode = mode;
    // 重新给预热期，避免切档瞬间的掉帧被算到新档头上
    _samples = 0;
    _overBudget = 0;
    _lastDropCount = null;
    if (!mode.needsGpuNext || mode.lowerTier == null) {
      stop();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _player = null;
    _lastDropCount = null;
    _samples = 0;
    _overBudget = 0;
    _downgrades = 0;
  }

  Future<void> _tick() async {
    final player = _player;
    if (player == null) return;

    try {
      final raw = await player.getProperty('frame-drop-count');
      final total = int.tryParse(raw.trim());
      if (total == null) return;

      _samples++;

      // 首次采样只记录基准，不判断
      if (_lastDropCount == null) {
        _lastDropCount = total;
        return;
      }

      // 预热期：解码器刚起来、缓冲未满时常有丢帧，不算
      if (_samples <= warmupSamples) {
        _lastDropCount = total;
        return;
      }

      final delta = total - _lastDropCount!;
      _lastDropCount = total;

      if (delta > dropBudget) {
        _overBudget++;
        debugPrint('[A4K-Auto] 掉帧 $delta 帧'
            '（超预算 $dropBudget，连续 $_overBudget 次）');
      } else {
        _overBudget = 0;
        return; // 正常，不降档
      }

      if (_overBudget < consecutiveOverBudget) return;
      if (_downgrades >= maxDowngrades) {
        debugPrint('[A4K-Auto] 已自动降 $maxDowngrades 次，停止监控');
        stop();
        return;
      }

      final next = _currentMode.lowerTier;
      if (next == null) {
        stop();
        return;
      }

      _downgrades++;
      _currentMode = next;
      _samples = 0;
      _overBudget = 0;
      _lastDropCount = null;

      debugPrint('[A4K-Auto] 持续掉帧，自动降档 → ${next.id}');
      onDowngrade(next);

      if (next == Anime4kMode.light) {
        // 已经是最低档，再降就只能关了；到此为止
        debugPrint('[A4K-Auto] 已降到最低档，停止监控');
        stop();
      }
    } catch (e) {
      // 属性可能在某些状态下一时读不到（例如刚换片源），忽略即可
      debugPrint('[A4K-Auto] 采样失败（忽略）: $e');
    }
  }
}
