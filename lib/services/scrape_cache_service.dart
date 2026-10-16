import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/database_service.dart';
import 'package:perchplay/services/media_namer_service.dart';
import 'package:perchplay/services/tmdb_service.dart';

/// 鍒墛缂撳瓨鏈嶅姟
///
/// 鏍稿績閫昏緫锛?/// 1. 瀵规瘡涓棰戯紝鐢?MediaNamer 娓呮礂鍑?鍙悳绱㈢殑鐗囧悕"
/// 2. 鍏堟煡鏈湴缂撳瓨锛圫QLite锛夛紝鍛戒腑鐩存帴杩斿洖
/// 3. 鏈懡涓?鈫?璋?TMDB API 鎼滅储 鈫?鍐欏叆缂撳瓨
/// 4. 鐢佃鍓э細浼樺厛鍖归厤鍓ч泦璇︽儏锛堝+闆嗭級锛屽尮閰嶄笉涓婂垯鍥為€€鍒版暣鍓?///
/// 瀵瑰鏆撮湶 [scrapeForVideo]銆乕scrapeForSeries]銆乕scrapeMovie]銆?class ScrapeCacheService {
  ScrapeCacheService._();
  static final instance = ScrapeCacheService._();

  TmdbService? _tmdb;
  String? _apiKey;

  /// 涓存椂鍐呭瓨缂撳瓨锛氬悓涓€绯诲垪鍙煡涓€娆?getTvDetail锛岄伩鍏?24 闆嗗 23 娆″啑浣欒姹?  final Map<int, Future<ScrapeResult?>> _seriesInfoCache = {};

  /// 蹇呴』鍦?init 涔嬪悗鎵嶈兘璋冪敤鍒墛
  void init({required String apiKey}) {
    _tmdb?.dispose();
    _apiKey = apiKey;
    _tmdb = TmdbService(apiKey: apiKey);
  }

  /// 閲婃斁 HTTP 杩炴帴
  void dispose() {
    _tmdb?.dispose();
    _tmdb = null;
    _apiKey = null;
    _seriesInfoCache.clear();
  }

  /// 姣忔壒鍒墛瀹屾垚鍚庢竻鐞嗙郴鍒楃紦瀛?  void clearSeriesInfoCache() => _seriesInfoCache.clear();

  bool get isReady => _apiKey != null && _apiKey!.isNotEmpty;

  // 鈹€鈹€ 瀵瑰 API 鈹€鈹€

  /// 鍒墛鍗曚釜瑙嗛锛堣嚜鍔ㄥ垽鏂數褰?鐢佃鍓э級
  ///
  /// [filePath] 鏄棰戠殑瀹屾暣璺緞锛岀敤鏉ユ帹鏂墽鍚?/ 闆嗘暟銆?  Future<ScrapeResult?> scrapeForVideo(String filePath) async {
    if (!isReady) return null;

    final info = MediaNamer.parse(filePath);
    final title = info.seriesTitle.trim();
    if (title.isEmpty) return null;

    // 鍏堟煡缂撳瓨锛堟寜璺緞锛?    final cached = await DatabaseService.instance.getScrapeCacheByPath(filePath);
    if (cached != null) return ScrapeResult.fromRow(cached);

    if (info.isEpisode) {
      return _scrapeSeriesEpisode(title, info.season, info.episode,
          filePath: filePath);
    } else {
      return _scrapeMovie(title, info.year, filePath: filePath);
    }
  }

  /// 鍒墛涓€涓墽闆嗗垪琛紙鐢ㄤ簬鎾斁鍒楄〃椤靛睍绀烘捣鎶ワ級
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

  /// 鍒墛鐢靛奖
  Future<ScrapeResult?> scrapeMovie(String title, {int? year}) async {
    if (!isReady) return null;

    final key = title.trim().toLowerCase();
    final cached = await DatabaseService.instance.getScrapeCache(key, 'movie');
    if (cached != null) return ScrapeResult.fromRow(cached);

    return _scrapeMovie(title, year, filePath: null);
  }

  /// 鎸夋悳绱㈣瘝鎼滅储 TMDB
  Future<List<ScrapeResult>> search(String query) async {
    if (!isReady) return [];
    final results = await _tmdb!.searchMulti(query);
    // 鍚屾椂鎷夎鎯呬互鑾峰彇 genres
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

  // 鈹€鈹€ 鍐呴儴 鈹€鈹€

  Future<ScrapeResult?> _scrapeMovie(String title, int? year,
      {String? filePath}) async {
    final key = title.trim().toLowerCase();

    final results = await _tmdb!.searchMovie(title, year: year);
    if (results.isEmpty) return null;

    final best = results.first;
    final detail = await _tmdb!.getMovieDetail(best.tmdbId);
    if (detail == null) return null;

    final row = detail.toRow();
    row['search_key'] = key;
    row['video_path'] = filePath;
    row['type'] = 'movie';
    await DatabaseService.instance.upsertScrapeCache(row);

    return detail;
  }

  Future<ScrapeResult?> _scrapeSeriesEpisode(
      String title, int? season, int? episode,
      {String? filePath}) async {
    final s = season ?? 1;
    final e = episode ?? 1;
    final key = '${title.trim().toLowerCase()}|${s}x${e.toString().padLeft(2, '0')}';

    // 鍏堟悳鏁村墽
    final results = await _tmdb!.searchTv(title);
    if (results.isEmpty) return null;

    final series = results.first;
    final seriesId = series.tmdbId;

    // 鍚屼竴绯诲垪鍙媺涓€娆℃暣鍓ц鎯咃紙鍐呭瓨缂撳瓨锛?    final seriesFuture = _seriesInfoCache.putIfAbsent(
        seriesId, () => _tmdb!.getTvDetail(seriesId));
    final seriesDetail = await seriesFuture;
    if (seriesDetail == null) return null;

    // 鎷夊墽闆嗚鎯?    final epDetail =
        await _tmdb!.getEpisodeDetail(seriesId, s, e, seriesInfo: seriesDetail);
    if (epDetail != null) {
      final row = epDetail.toRow();
      row['search_key'] = key;
      row['video_path'] = filePath;
      await DatabaseService.instance.upsertScrapeCache(row);
      return epDetail;
    }

    // 闆嗚鎯呮嬁涓嶅埌锛屽洖閫€鍒版暣鍓т俊鎭?    final row = seriesDetail.toRow();
    row['search_key'] = key;
    row['video_path'] = filePath;
    row['season_number'] = s;
    row['episode_number'] = e;
    await DatabaseService.instance.upsertScrapeCache(row);

    return seriesDetail;
  }
}