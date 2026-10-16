import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/database_service.dart';
import 'package:perchplay/services/media_namer_service.dart';
import 'package:perchplay/services/scrape_matcher.dart';
import 'package:perchplay/services/tmdb_service.dart';

/// 刮削缓存服务
///
/// 核心逻辑：
/// 1. 对每个视频，用 MediaNamer 清洗出"可搜索的片名"
/// 2. 先查本地缓存（SQLite），命中直接返回
/// 3. 未命中 → 调 TMDB API 搜索 → 写入缓存
/// 4. 电视剧：优先匹配剧集详情（季+集），匹配不上则回退到整剧
///
/// 对外暴露 [scrapeForVideo]、[scrapeForSeries]、[scrapeMovie]。
class ScrapeCacheService {
  ScrapeCacheService._();
  static final instance = ScrapeCacheService._();

  TmdbService? _tmdb;
  String? _apiKey;

  /// 临时内存缓存：同一系列只查一次 getTvDetail，避免 24 集多 23 次冗余请求
  final Map<int, Future<ScrapeResult?>> _seriesInfoCache = {};

  /// 必须在 init 之后才能调用刮削
  void init({required String apiKey}) {
    _tmdb?.dispose();
    _apiKey = apiKey;
    _tmdb = TmdbService(apiKey: apiKey);
  }

  /// 释放 HTTP 连接
  void dispose() {
    _tmdb?.dispose();
    _tmdb = null;
    _apiKey = null;
    _seriesInfoCache.clear();
  }

  /// 每批刮削完成后清理系列缓存
  void clearSeriesInfoCache() => _seriesInfoCache.clear();

  bool get isReady => _apiKey != null && _apiKey!.isNotEmpty;

  // ── 对外 API ──

  /// 刮削单个视频（自动判断电影/电视剧）
  ///
  /// [filePath] 是视频的完整路径，用来推断剧名 / 集数。
  Future<ScrapeResult?> scrapeForVideo(String filePath) async {
    if (!isReady) return null;

    final info = MediaNamer.parse(filePath);
    final title = info.seriesTitle.trim();
    if (title.isEmpty) return null;

    // 先查缓存（按路径）
    final cached = await DatabaseService.instance.getScrapeCacheByPath(filePath);
    if (cached != null) return ScrapeResult.fromRow(cached);

    if (info.isEpisode && !info.weakEpisode) {
      // 明确写了 S01E02：只走剧集，不做电影兜底，避免给剧集贴上无关电影的海报
      return _scrapeSeriesEpisode(title, info.season, info.episode,
          filePath: filePath);
    }

    if (info.isEpisode) {
      // 弱识别：这个「集数」多半是片名自带的数字（《流浪地球2》《阿凡达2》）
      final ep = await _scrapeSeriesEpisode(title, info.season, info.episode,
          filePath: filePath);
      if (ep != null) return ep;
      // 剧集查不到 → 按电影再试一次，并且用**带数字的完整片名**，
      // 否则《流浪地球2》会搜到第 1 部
      final full = info.fullTitle.trim();
      final asMovie = await _scrapeMovie(
          full.isEmpty ? title : full, info.year,
          filePath: filePath);
      if (asMovie != null) return asMovie;
    }

    return _scrapeMovie(title, info.year, filePath: filePath);
  }

  /// 刮削一个剧集列表（用于播放列表页展示海报）
  Future<ScrapeResult?> scrapeForSeries(String seriesTitle) async {
    if (!isReady) return null;

    final key = seriesTitle.trim().toLowerCase();
    final cached = await DatabaseService.instance.getScrapeCache(key, 'tv');
    if (cached != null) return ScrapeResult.fromRow(cached);

    final results = await _tmdb!.searchTv(seriesTitle);
    if (results.isEmpty) return null;

    final best = results.first;
    final detail = await _tmdb!.getTvDetail(best.tmdbId);
    if (detail == null) return null;

    final row = detail.toRow();
    row['search_key'] = key;
    row['video_path'] = null;
    await DatabaseService.instance.upsertScrapeCache(row);

    return detail;
  }

  /// 刮削电影
  Future<ScrapeResult?> scrapeMovie(String title, {int? year}) async {
    if (!isReady) return null;

    final key = title.trim().toLowerCase();
    final cached = await DatabaseService.instance.getScrapeCache(key, 'movie');
    if (cached != null) return ScrapeResult.fromRow(cached);

    return _scrapeMovie(title, year, filePath: null);
  }

  /// 按搜索词搜索 TMDB
  Future<List<ScrapeResult>> search(String query) async {
    if (!isReady) return [];
    final results = await _tmdb!.searchMulti(query);
    // 同时拉详情以获取 genres
    final detailed = await Future.wait(
      results.take(5).map((r) async {
        if (r.type == ScrapeType.movie) {
          return _tmdb!.getMovieDetail(r.tmdbId);
        } else {
          return _tmdb!.getTvDetail(r.tmdbId);
        }
      }),
    );
    return detailed.where((r) => r != null).cast<ScrapeResult>().toList();
  }

  // ── 内部 ──

  Future<ScrapeResult?> _scrapeMovie(String title, int? year,
      {String? filePath}) async {
    final key = title.trim().toLowerCase();

    // 依次降级尝试，避免「搜不到就永远没海报」：
    //  1) 带年份搜电影（最精确）
    //  2) 去掉年份再搜电影 —— TMDB 的 year 是**硬过滤**，
    //     文件名里的年份写错/写成上映年以外的年份时，会把正确结果一起滤掉
    //  3) 混合搜索 —— 片名其实是剧集/电视电影时 search/movie 永远查不到
    var results = await _tmdb!.searchMovie(title, year: year);
    if (results.isEmpty && year != null) {
      results = await _tmdb!.searchMovie(title);
    }
    if (results.isEmpty) {
      results = await _tmdb!.searchMulti(title);
    }
    if (results.isEmpty) return null;

    // 不再盲取第一条：按片名相似度 + 年份挑最像的
    final best = ScrapeMatcher.best(results, query: title, year: year);
    if (best == null) return null;

    final detail = best.type == ScrapeType.tv
        ? await _tmdb!.getTvDetail(best.tmdbId)
        : await _tmdb!.getMovieDetail(best.tmdbId);
    if (detail == null) return null;

    // 注意：不要写死 row['type']，让 toRow() 按实际命中的是电影还是剧集来写，
    // 否则降级命中剧集时会往缓存里写错类型
    final row = detail.toRow();
    row['search_key'] = key;
    row['video_path'] = filePath;
    await DatabaseService.instance.upsertScrapeCache(row);

    return detail;
  }

  Future<ScrapeResult?> _scrapeSeriesEpisode(
      String title, int? season, int? episode,
      {String? filePath}) async {
    final s = season ?? 1;
    final e = episode ?? 1;
    final key = '${title.trim().toLowerCase()}|${s}x${e.toString().padLeft(2, '0')}';

    // 先搜整剧；搜不到就退到混合搜索（TMDB 里有的剧只有本地化/别名能命中）
    var results = await _tmdb!.searchTv(title);
    if (results.isEmpty) {
      results = (await _tmdb!.searchMulti(title))
          .where((r) => r.type == ScrapeType.tv)
          .toList();
    }
    if (results.isEmpty) return null;

    // 同样按相似度挑，而不是盲取第一条
    final series = ScrapeMatcher.best(results, query: title);
    if (series == null) return null;
    final seriesId = series.tmdbId;

    // 同一系列只拉一次整剧详情（内存缓存）
    final seriesFuture = _seriesInfoCache.putIfAbsent(
        seriesId, () => _tmdb!.getTvDetail(seriesId));
    final seriesDetail = await seriesFuture;
    if (seriesDetail == null) return null;

    // 拉剧集详情
    final epDetail =
        await _tmdb!.getEpisodeDetail(seriesId, s, e, seriesInfo: seriesDetail);
    if (epDetail != null) {
      final row = epDetail.toRow();
      row['search_key'] = key;
      row['video_path'] = filePath;
      await DatabaseService.instance.upsertScrapeCache(row);
      return epDetail;
    }

    // 集详情拿不到，回退到整剧信息
    final row = seriesDetail.toRow();
    row['search_key'] = key;
    row['video_path'] = filePath;
    row['season_number'] = s;
    row['episode_number'] = e;
    await DatabaseService.instance.upsertScrapeCache(row);

    return seriesDetail;
  }
}