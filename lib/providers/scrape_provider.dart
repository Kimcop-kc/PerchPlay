import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/scrape_cache_service.dart';
import 'package:perchplay/services/database_service.dart';
import 'package:perchplay/services/app_settings_service.dart';

/// 鍒墛鐘舵€?class ScrapeState {
  final Map<String, ScrapeResult?> results; // videoPath 鈫?result
  final bool isEnabled;
  final int queueLength; // 杩樻湁鍑犱釜鍦ㄦ帓闃燂紙鍚綋鍓嶆鍦ㄥ鐞嗙殑锛?  final String? error;

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

/// 鍒墛 Provider
///
/// 鏍稿績娴佺▼锛?/// 1. 鐢ㄦ埛璁剧疆 TMDB API key 鈫?enable 鈫?loadCache锛堟仮澶嶅凡鏈夌粨鏋滐級
/// 2. 鎵弿瀹屾垚鍚庤皟鐢?[scrapeBatch] 鈫?鍚庡彴閫愪釜鍒墛锛屾瘡娆￠棿闅?1s
/// 3. 缁撴灉閫氳繃 [scrapeResultProvider] 鎸?videoPath 鏌ヨ
class ScrapeNotifier extends StateNotifier<ScrapeState> {
  ScrapeNotifier() : super(const ScrapeState());

  final List<String> _queue = [];
  bool _processing = false;

  /// 鍒濆鍖栵細鏈変繚瀛樼殑 API key 灏辩珛鍗冲惎鐢紙鍚屾璁?isEnabled锛夛紝缂撳瓨寮傛鍔犺浇
  Future<void> boot() async {
    final key = AppSettingsService.instance.tmdbApiKey;
    if (key.isEmpty) return;
    ScrapeCacheService.instance.init(apiKey: key);
    // isEnabled = true 蹇呴』鍦?await 涔嬪墠锛屽惁鍒?scan() 鐨?scrapeBatch 浼氳璺宠繃
    state = state.copyWith(isEnabled: true);
    await _loadCache();
  }

  /// 璁剧疆 API key 骞跺惎鐢ㄥ埉鍓?  Future<void> enable(String apiKey) async {
    ScrapeCacheService.instance.init(apiKey: apiKey);
    state = state.copyWith(isEnabled: true, error: null);
    await _loadCache();
  }

  void disable() {
    _queue.clear();
    _processing = false;
    state = state.copyWith(isEnabled: false, queueLength: 0);
  }

  /// 鎵归噺鍒墛锛堝悗鍙颁覆琛岋紝涓嶉樆濉?UI锛孴MDB 闄愭祦鍙嬪ソ锛?  void scrapeBatch(List<String> paths) {
    if (!state.isEnabled) return;
    for (final path in paths) {
      if (state.results.containsKey(path) && state.results[path] != null) {
        continue;
      }
      // 涓嶅湪闃熷垪閲屼篃涓嶅啀澶勭悊涓墠鍔?      if (!_queue.contains(path)) _queue.add(path);
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
      state = state.copyWith(queueLength: _queue.length, error: null);
      try {
        final result = await ScrapeCacheService.instance.scrapeForVideo(path);
        if (result != null) {
          state = state.copyWith(
            results: {...state.results, path: result},
          );
        }
        // null = 缃戠粶/TMDB 鏁呴殰锛屼笉缂撳瓨锛涗笅娆℃壂鎻忛噸璇?      } catch (e) {
        debugPrint('[Scrape] $path error: $e');
        state = state.copyWith(error: e.toString());
      }
      // TMDB 鍏嶈垂 API 闄愭祦 鈮?50 req/s锛? 绉掗棿闅旂话缁版湁浣?      if (_queue.isNotEmpty) await Future<void>.delayed(const Duration(seconds: 1));
    }
    _processing = false;
    ScrapeCacheService.instance.clearSeriesInfoCache();
  }

  /// 鎸夌郴鍒楀悕鍒墛锛堟挱鏀惧垪琛ㄧ敤锛?  Future<ScrapeResult?> scrapeSeries(String seriesTitle) async {
    if (!state.isEnabled) return null;
    try {
      return await ScrapeCacheService.instance.scrapeForSeries(seriesTitle);
    } catch (e) {
      debugPrint('[Scrape] series $seriesTitle error: $e');
      return null;
    }
  }

  /// 鎵嬪姩鎼滅储
  Future<List<ScrapeResult>> search(String query) async {
    if (!state.isEnabled) return [];
    try {
      return await ScrapeCacheService.instance.search(query);
    } catch (e) {
      debugPrint('[Scrape] search error: $e');
      return [];
    }
  }

  /// 缁戝畾鍒墛缁撴灉鍒拌棰戣矾寰?  Future<ScrapeResult?> bindResult(String videoPath, ScrapeResult result) async {
    final row = result.toRow();
    row['search_key'] = result.title.toLowerCase();
    row['video_path'] = videoPath;
    await DatabaseService.instance.upsertScrapeCache(row);
    state = state.copyWith(
      results: {...state.results, videoPath: result},
    );
    return result;
  }

  // 鈹€鈹€ private 鈹€鈹€

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
      // 鍚堝苟锛氭鍦ㄨ窇鐨?scrapeBatch 鍙兘宸蹭骇鍑虹粨鏋滐紝鍐呭瓨涓殑浼樺厛
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

/// 鎸夎棰戣矾寰勫彇鍒墛缁撴灉
final scrapeResultProvider =
    Provider.family<ScrapeResult?, String>((ref, videoPath) {
  final state = ref.watch(scrapeProvider);
  return state.results[videoPath];
});