import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vidflow/models/scrape_result.dart';
import 'package:vidflow/services/scrape_cache_service.dart';
import 'package:vidflow/services/database_service.dart';

/// 刮削状态
class ScrapeState {
  final Map<String, ScrapeResult?> results; // videoPath → result
  final Set<String> pending; // 正在刮削的 videoPath
  final bool isEnabled;
  final String? error;

  const ScrapeState({
    this.results = const {},
    this.pending = const {},
    this.isEnabled = false,
    this.error,
  });

  ScrapeState copyWith({
    Map<String, ScrapeResult?>? results,
    Set<String>? pending,
    bool? isEnabled,
    String? error,
  }) {
    return ScrapeState(
      results: results ?? this.results,
      pending: pending ?? this.pending,
      isEnabled: isEnabled ?? this.isEnabled,
      error: error,
    );
  }
}

/// 刮削 Provider
///
/// 核心流程：
/// 1. 用户设置 TMDB API key → isEnabled 变为 true
/// 2. 扫描完成后调用 [scrapeBatch] → 后台逐个刮削
/// 3. 结果通过 [scrapeResultProvider] 按 videoPath 查询
class ScrapeNotifier extends StateNotifier<ScrapeState> {
  ScrapeNotifier() : super(const ScrapeState());

  /// 初始化：加载已缓存的刮削结果
  Future<void> loadCache() async {
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

  /// 设置 API key 并启用刮削
  void enable(String apiKey) {
    ScrapeCacheService.instance.init(apiKey: apiKey);
    state = state.copyWith(isEnabled: true, error: null);
  }

  void disable() {
    state = state.copyWith(isEnabled: false);
  }

  /// 批量刮削（后台，不阻塞 UI）
  Future<void> scrapeBatch(List<String> paths) async {
    if (!state.isEnabled) return;

    for (final path in paths) {
      // 跳过已缓存
      if (state.results.containsKey(path) && state.results[path] != null) {
        continue;
      }
      // 跳过正在处理
      if (state.pending.contains(path)) continue;

      // 异步处理，不等待
      _scrapeOne(path);
    }
  }

  Future<void> _scrapeOne(String path) async {
    state = state.copyWith(pending: {...state.pending, path});
    try {
      final result = await ScrapeCacheService.instance.scrapeForVideo(path);
      state = state.copyWith(
        results: {...state.results, path: result},
        pending: state.pending.difference({path}),
      );
    } catch (e) {
      debugPrint('[Scrape] $path error: $e');
      state = state.copyWith(
        pending: state.pending.difference({path}),
        error: e.toString(),
      );
    }
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