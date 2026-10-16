import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:vidflow/models/scrape_result.dart';

/// TMDB API 刮削服务
///
/// 用法：
/// ```dart
/// final svc = TmdbService(apiKey: 'your_key_here');
/// final results = await svc.searchMulti('进击的巨人');
/// ```
class TmdbService {
  final String apiKey;
  final String _base = 'https://api.tmdb.org/3';

  TmdbService({required this.apiKey});

  // ── 搜索 ──

  /// 混合搜索（电影 + 电视剧）
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
    final resp = await http.get(url);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  /// 搜索电影
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
    final resp = await http.get(url);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>, forceType: ScrapeType.movie))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  /// 搜索电视剧
  Future<List<ScrapeResult>> searchTv(
    String query, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/search/tv').replace(queryParameters: {
      'api_key': apiKey,
      'query': query,
      'language': language,
      'include_adult': 'false',
    });
    final resp = await http.get(url);
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body);
    final list = (data['results'] as List?) ?? [];
    return list
        .map((e) => _parseSearchResult(e as Map<String, dynamic>, forceType: ScrapeType.tv))
        .where((r) => r != null)
        .cast<ScrapeResult>()
        .toList();
  }

  // ── 详情 ──

  Future<ScrapeResult?> getMovieDetail(
    int tmdbId, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/movie/$tmdbId').replace(queryParameters: {
      'api_key': apiKey,
      'language': language,
    });
    final resp = await http.get(url);
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
    final resp = await http.get(url);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return _parseDetail(data, type: ScrapeType.tv);
  }

  // ── 季/集详情 ──

  Future<ScrapeResult?> getEpisodeDetail(
    int seriesId,
    int seasonNumber,
    int episodeNumber, {
    String language = 'zh-CN',
  }) async {
    final url = Uri.parse('$_base/tv/$seriesId/season/$seasonNumber/episode/$episodeNumber')
        .replace(queryParameters: {
      'api_key': apiKey,
      'language': language,
    });
    final resp = await http.get(url);
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    // Also get series overview
    final series = await getTvDetail(seriesId, language: language);
    return ScrapeResult(
      title: series?.title ?? '',
      originalTitle: series?.originalTitle,
      year: series?.year,
      overview: data['overview'] as String? ?? series?.overview,
      posterPath: data['still_path'] as String? ?? series?.posterPath,
      backdropPath: series?.backdropPath,
      rating: (data['vote_average'] as num?)?.toDouble() ?? series?.rating,
      voteCount: data['vote_count'] as int? ?? series?.voteCount,
      genres: series?.genres ?? [],
      type: ScrapeType.tv,
      tmdbId: seriesId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeTitle: data['name'] as String?,
    );
  }

  // ── 内部解析 ──

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
    // genreIds 需要查 genre map 才能转名；search 结果不带 genre 名称，留空
    return ScrapeResult(
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