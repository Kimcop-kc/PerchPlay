import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:perchplay/models/scrape_result.dart';

/// TMDB API 鍒墛鏈嶅姟
///
/// 鐢ㄦ硶锛?/// ```dart
/// final svc = TmdbService(apiKey: 'your_key_here');
/// final results = await svc.searchMulti('杩涘嚮鐨勫法浜?);
/// ```
class TmdbService {
  final String apiKey;
  final String _base = 'https://api.tmdb.org/3';
  final http.Client _client = http.Client();

  /// 瓒呮椂 15s锛圱MDB 閫氬父鍦?2-5s 鍐呭搷搴旓紝15s 瓒冲宸綉缁滐級
  static const _timeout = Duration(seconds: 15);

  TmdbService({required this.apiKey});

  void dispose() {
    _client.close();
  }

  // 鈹€鈹€ 鎼滅储 鈹€鈹€

  /// 娣峰悎鎼滅储锛堢數褰?+ 鐢佃鍓э級
  Future<List<ScrapeResult>> searchMulti(
    String query, {
    String language = 'zh-CN',
    int page = 1,
  }) async {
    final url = Uri.parse('$_base/search/multi').replace(queryParameters: {
      'api_key': apiKey,
      'query': query,
      'language': language,
      'page': page.toString(),
      'include_adult': 'false',
    });
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  /// 鎼滅储鐢靛奖
  Future<List<ScrapeResult>> searchMovie(
    String query, {
    String language = 'zh-CN',
    int? year,
  }) async {
    final params = <String, String>{
      'api_key': apiKey,
      'query': query,
      'language': language,
      'include_adult': 'false',
    };
    if (year != null) params['year'] = year.toString();
    final url = Uri.parse('$_base/search/movie').replace(queryParameters: params);
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>, forceType: ScrapeType.movie))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  /// 鎼滅储鐢佃鍓?  Future<List<ScrapeResult>> searchTv(
    String query, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/search/tv').replace(queryParameters: {
      'api_key': apiKey,
      'query': query,
      'language': language,
      'include_adult': 'false',
    });
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>, forceType: ScrapeType.tv))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  // 鈹€鈹€ 璇︽儏 鈹€鈹€

  Future<ScrapeResult?> getMovieDetail(
    int tmdbId, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/movie/$tmdbId').replace(queryParameters: {
      'api_key': apiKey,
      'language': language,
    });
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseDetail(data, type: ScrapeType.movie);
  }

  Future<ScrapeResult?> getTvDetail(
    int tmdbId, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/tv/$tmdbId').replace(queryParameters: {
      'api_key': apiKey,
      'language': language,
    });
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseDetail(data, type: ScrapeType.tv);
  }

  // 鈹€鈹€ 瀛?闆嗚鎯?鈹€鈹€

  /// [seriesInfo] 鍙€夛細宸茶幏鍙栫殑绯诲垪璇︽儏锛岄伩鍏嶉噸澶嶈皟鐢?getTvDetail
  Future<ScrapeResult?> getEpisodeDetail(
    int seriesId,
    int seasonNumber,
    int episodeNumber, {
    String language = 'zh-CN',
    ScrapeResult? seriesInfo,
  }) async {
    final url = Uri.parse('$_base/tv/$seriesId/season/$seasonNumber/episode/$episodeNumber')
        .replace(queryParameters: {
      'api_key': apiKey,
      'language': language,
    });
    final resp = await _client.get(url).timeout(_timeout);
    if (resp.statusCode != 200) return null;
    final epData = jsonDecode(resp.body) as Map<String, dynamic>;
    final series = seriesInfo ?? await getTvDetail(seriesId, language: language);
    return ScrapeResult(
      title: series?.title ?? '',
      originalTitle: series?.originalTitle,
      year: series?.year,
      overview: epData['overview'] as String? ?? series?.overview,
      posterPath: epData['still_path'] as String? ?? series?.posterPath,
      backdropPath: series?.backdropPath,
      rating: (epData['vote_average'] as num?)?.toDouble() ?? series?.rating,
      voteCount: epData['vote_count'] as int? ?? series?.voteCount,
      genres: series?.genres ?? [],
      type: ScrapeType.tv,
      tmdbId: seriesId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeTitle: epData['name'] as String?,
    );
  }

  // 鈹€鈹€ 鍐呴儴瑙ｆ瀽 鈹€鈹€

  ScrapeResult? _parseSearchResult(
    Map<String, dynamic> e, {
    ScrapeType? forceType,
  }) {
    final mediaType = forceType?.name ?? e['media_type'] as String?;
    if (mediaType != 'movie' && mediaType != 'tv') return null;
    final type = mediaType == 'tv' ? ScrapeType.tv : ScrapeType.movie;

    final title =
        (e['title'] ?? e['name'] ?? '') as String;
    if (title.isEmpty) return null;

    final dateStr = (e['first_air_date'] ?? e['release_date'] ?? '') as String;
    final year = dateStr.length >= 4 ? int.tryParse(dateStr.substring(0, 4)) : null;
    // genreIds 闇€瑕佹煡 genre map 鎵嶈兘杞悕锛泂earch 缁撴灉涓嶅甫 genre 鍚嶇О锛岀暀绌?    return ScrapeResult(
      title: title,
      originalTitle: e['original_title'] as String? ?? e['original_name'] as String?,
      year: year,
      overview: e['overview'] as String?,
      posterPath: e['poster_path'] as String?,
      backdropPath: e['backdrop_path'] as String?,
      rating: (e['vote_average'] as num?)?.toDouble(),
      voteCount: e['vote_count'] as int?,
      genres: [],
      type: type,
      tmdbId: e['id'] as int,
    );
  }

  ScrapeResult _parseDetail(Map<String, dynamic> e, {required ScrapeType type}) {
    final genres = (e['genres'] as List?)
            ?.map((g) => (g as Map<String, dynamic>)['name'] as String? ?? '')
            .where((g) => g.isNotEmpty)
            .toList() ??
        [];

    final dateStr = (e['first_air_date'] ?? e['release_date'] ?? '') as String;
    final year = dateStr.length >= 4 ? int.tryParse(dateStr.substring(0, 4)) : null;

    return ScrapeResult(
      title: (e['title'] ?? e['name'] ?? '') as String,
      originalTitle: e['original_title'] as String? ?? e['original_name'] as String?,
      year: year,
      overview: e['overview'] as String?,
      posterPath: e['poster_path'] as String?,
      backdropPath: e['backdrop_path'] as String?,
      rating: (e['vote_average'] as num?)?.toDouble(),
      voteCount: e['vote_count'] as int?,
      genres: genres,
      type: type,
      tmdbId: e['id'] as int,
    );
  }
}