import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vidflow/models/scrape_result.dart';
import 'package:vidflow/services/scrape_cache_service.dart';
import 'package:vidflow/services/database_service.dart';
import 'package:vidflow/services/app_settings_service.dart';

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
    if (key.isEmpty) return;
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
  void scrapeBatch(List<String> paths) {
    if (!state.isEnabled) return;
    for (final path in paths) {
      if (state.results.containsKey(path) && state.results[path] != null) {
        continue;
      }
      // 不在队列里也不再处理中才加
      if (!_queue.contains(path)) _queue.add(path);
    }
    state = state.copyWith(queueLength: _queue.length);
    _drain();
  }

  void _drain() {
    if (_processing || _queue.isEmpty) return;
    _processing = true;
    _next();
  }

  Future<void> _next() async {
    while (_queue.isNotEmpty) {
      final path = _queue.removeAt(0);
      state = state.copyWith(queueLength: _queue.length);
      try {
        final result = await ScrapeCacheService.instance.scrapeForVideo(path);
        state = state.copyWith(
          results: {...state.results, path: result},
        );
      } catch (e) {
        debugPrint('[Scrape] $path error: $e');
        state = state.copyWith(error: e.toString());
      }
      // TMDB 免费 API 限流 ≈ 50 req/s，1 秒间隔绰绰有余
      if (_queue.isNotEmpty) await Future<void>.delayed(const Duration(seconds: 1));
    }
    _processing = false;
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
  Future<ScrapeResult?> bindResult(String videoPath, ScrapeResult result) async {
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
      final results = <String, ScrapeResult?>{};
      for (final row in rows) {
        final path = row['video_path'] as String?;
        if (path != null && path.isNotEmpty) {
          results[path] = ScrapeResult.fromRow(row);
        }
      }
      state = state.copyWith(results: results);
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