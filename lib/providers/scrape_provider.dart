import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/scrape_cache_service.dart';
import 'package:perchplay/services/database_service.dart';
import 'package:perchplay/services/app_settings_service.dart';
import 'package:perchplay/services/video_source_service.dart';
import 'package:perchplay/services/playback_busy.dart';

/// 刮削状态
class ScrapeState {
  final Map<String, ScrapeResult?> results; // videoPath → result
  final bool isEnabled;
  final int queueLength; // 还有几个在排队（含当前正在处理的）
  final String? error;

  const ScrapeState({
    this.results = const {},
    this.isEnabled = false,
    this.queueLength = 0,
    this.error,
  });

  ScrapeState copyWith({
    Map<String, ScrapeResult?>? results,
    bool? isEnabled,
    int? queueLength,
    String? error,
  }) {
    return ScrapeState(
      results: results ?? this.results,
      isEnabled: isEnabled ?? this.isEnabled,
      queueLength: queueLength ?? this.queueLength,
      error: error,
    );
  }
}

/// 刮削 Provider
///
/// 核心流程：
/// 1. 用户设置 TMDB API key → enable → loadCache（恢复已有结果）
/// 2. 扫描完成后调用 [scrapeBatch] → 后台逐个刮削，每次间隔 1s
/// 3. 结果通过 [scrapeResultProvider] 按 videoPath 查询
class ScrapeNotifier extends StateNotifier<ScrapeState> {
  ScrapeNotifier() : super(const ScrapeState());

  final List<String> _queue = [];
  bool _processing = false;

  /// 初始化：有保存的 API key 就立即启用（同步设 isEnabled），缓存异步加载
  Future<void> boot() async {
    final key = AppSettingsService.instance.tmdbApiKey;
    if (key.isEmpty) {
      // 没有 Key 也要把**已有缓存**读回来。
      // 否则用户一旦清掉 Key（或换了设备恢复数据），之前刮到的
      // 海报/简介会全部从界面消失，看起来像"刮削结果丢了"。
      await _loadCache();
      return;
    }
    ScrapeCacheService.instance.init(apiKey: key);
    // isEnabled = true 必须在 await 之前，否则 scan() 的 scrapeBatch 会被跳过
    state = state.copyWith(isEnabled: true);
    await _loadCache();
  }

  /// 设置 API key 并启用刮削
  Future<void> enable(String apiKey) async {
    ScrapeCacheService.instance.init(apiKey: apiKey);
    state = state.copyWith(isEnabled: true, error: null);
    await _loadCache();
  }

  void disable() {
    _queue.clear();
    _processing = false;
    state = state.copyWith(isEnabled: false, queueLength: 0);
  }

  /// 批量刮削（后台串行，不阻塞 UI，TMDB 限流友好）
  ///
  /// 只刮「能判定为电影 / 剧集」的视频：随手拍、录屏、测试片段这类
  /// 判定不出来的，直接用视频自己的缩略图 —— 既不发无谓的请求，
  /// 也避免把无关视频匹配到错误的影片上。
  void scrapeBatch(List<String> paths) {
    if (!state.isEnabled) return;
    for (final path in _movieOrTvOnly(paths)) {
      if (state.results.containsKey(path) && state.results[path] != null) {
        continue;
      }
      // 不在队列里也不再处理中才加
      if (!_queue.contains(path)) _queue.add(path);
    }
    state = state.copyWith(queueLength: _queue.length);
    _drain();
  }

  /// 先用**文件名分组规则**判断"是不是电影/剧集"，只放行这些路径。
  /// 判定为 fallback / personal 的（没有年份、没有集数、没有片源标记的
  /// 随手拍或录屏）一律不刮削。
  List<String> _movieOrTvOnly(List<String> paths) {
    if (paths.isEmpty) return const [];
    try {
      final groups = VideoSourceService.groupAll(paths);
      final out = <String>[];
      for (final g in groups) {
        if (!(g.isSeries || g.isMovie)) continue;
        for (final i in g.indices) {
          if (i >= 0 && i < paths.length) out.add(paths[i]);
        }
      }
      return out;
    } catch (_) {
      // 分组异常时宁可照旧全刮，也不要因此一个都不刮
      return paths;
    }
  }

  void _drain() {
    if (_processing || _queue.isEmpty) return;
    _processing = true;
    _next();
  }

  Future<void> _next() async {
    while (_queue.isNotEmpty) {
      // 播放中暂停刮削：网络请求 + JSON 解析会占资源，和播放器抢 CPU/网络，
      // 导致播放中「突然卡一下」。等播放停止/暂停后再继续。
      while (PlaybackBusy.playing) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final path = _queue.removeAt(0);
      state = state.copyWith(queueLength: _queue.length, error: null);
      try {
        final result = await ScrapeCacheService.instance.scrapeForVideo(path);
        if (result != null) {
          state = state.copyWith(
            results: {...state.results, path: result},
          );
        }
        // null = 网络/TMDB 故障，不缓存；下次扫描重试
      } catch (e) {
        debugPrint('[Scrape] $path error: $e');
        state = state.copyWith(error: e.toString());
      }
      // TMDB 免费 API 限流 ≈ 50 req/s，1 秒间隔绰绰有余
      if (_queue.isNotEmpty)
        await Future<void>.delayed(const Duration(seconds: 1));
    }
    _processing = false;
    ScrapeCacheService.instance.clearSeriesInfoCache();
  }

  /// 按系列名刮削（播放列表用）
  Future<ScrapeResult?> scrapeSeries(String seriesTitle) async {
    if (!state.isEnabled) return null;
    try {
      return await ScrapeCacheService.instance.scrapeForSeries(seriesTitle);
    } catch (e) {
      debugPrint('[Scrape] series $seriesTitle error: $e');
      return null;
    }
  }

  /// 手动搜索
  Future<List<ScrapeResult>> search(String query) async {
    if (!state.isEnabled) return [];
    try {
      return await ScrapeCacheService.instance.search(query);
    } catch (e) {
      debugPrint('[Scrape] search error: $e');
      return [];
    }
  }

  /// 绑定刮削结果到视频路径
  Future<ScrapeResult?> bindResult(
      String videoPath, ScrapeResult result) async {
    final row = result.toRow();
    row['search_key'] = result.title.toLowerCase();
    row['video_path'] = videoPath;
    await DatabaseService.instance.upsertScrapeCache(row);
    state = state.copyWith(
      results: {...state.results, videoPath: result},
    );
    return result;
  }

  // ── private ──

  Future<void> _loadCache() async {
    try {
      final rows = await DatabaseService.instance.getAllScrapeCache();
      final fromDb = <String, ScrapeResult?>{};
      for (final row in rows) {
        final path = row['video_path'] as String?;
        if (path != null && path.isNotEmpty) {
          fromDb[path] = ScrapeResult.fromRow(row);
        }
      }
      // 合并：正在跑的 scrapeBatch 可能已产出结果，内存中的优先
      fromDb.addAll(state.results);
      state = state.copyWith(results: fromDb);
    } catch (e) {
      debugPrint('[Scrape] loadCache error: $e');
    }
  }
}

final scrapeProvider =
    StateNotifierProvider<ScrapeNotifier, ScrapeState>((ref) {
  return ScrapeNotifier();
});

/// 按视频路径取刮削结果
final scrapeResultProvider =
    Provider.family<ScrapeResult?, String>((ref, videoPath) {
  final state = ref.watch(scrapeProvider);
  return state.results[videoPath];
});
