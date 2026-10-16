/// 刮削元数据模型
import 'dart:convert';

class ScrapeResult {
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final String? posterPath; // TMDB relative path
  final String? backdropPath;
  final double? rating;
  final int? voteCount;
  final List<String> genres;
  final ScrapeType type; // movie or tv
  final int tmdbId;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? episodeTitle;
  final DateTime? cachedAt;

  const ScrapeResult({
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.rating,
    this.voteCount,
    this.genres = const [],
    required this.type,
    required this.tmdbId,
    this.seasonNumber,
    this.episodeNumber,
    this.episodeTitle,
    this.cachedAt,
  });

  String? get posterUrl {
    if (posterPath == null || posterPath!.isEmpty) return null;
    return 'https://image.tmdb.org/t/p/w500$posterPath';
  }

  String? get backdropUrl {
    if (backdropPath == null || backdropPath!.isEmpty) return null;
    return 'https://image.tmdb.org/t/p/w780$backdropPath';
  }

  String? get posterThumbUrl {
    if (posterPath == null || posterPath!.isEmpty) return null;
    return 'https://image.tmdb.org/t/p/w185$posterPath';
  }

  /// 从 SQLite 行 reconstruct
  factory ScrapeResult.fromRow(Map<String, dynamic> row) {
    List<String> genres = [];
    try {
      genres = (jsonDecode(row['genres'] as String? ?? '[]') as List)
          .map((e) => e.toString())
          .toList();
    } catch (_) {}

    return ScrapeResult(
      title: row['title'] as String,
      originalTitle: row['original_title'] as String?,
      year: row['year'] as int?,
      overview: row['overview'] as String?,
      posterPath: row['poster_path'] as String?,
      backdropPath: row['backdrop_path'] as String?,
      rating: (row['rating'] as num?)?.toDouble(),
      voteCount: row['vote_count'] as int?,
      genres: genres,
      type: row['type'] as String == 'tv' ? ScrapeType.tv : ScrapeType.movie,
      tmdbId: row['tmdb_id'] as int,
      seasonNumber: row['season_number'] as int?,
      episodeNumber: row['episode_number'] as int?,
      episodeTitle: row['episode_title'] as String?,
      cachedAt: row['cached_at'] != null
          ? DateTime.tryParse(row['cached_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toRow() {
    return {
      'title': title,
      'original_title': originalTitle,
      'year': year,
      'overview': overview,
      'poster_path': posterPath,
      'backdrop_path': backdropPath,
      'rating': rating,
      'vote_count': voteCount,
      'genres': jsonEncode(genres),
      'type': type.name,
      'tmdb_id': tmdbId,
      'season_number': seasonNumber,
      'episode_number': episodeNumber,
      'episode_title': episodeTitle,
      'cached_at': (cachedAt ?? DateTime.now()).toIso8601String(),
    };
  }

  String get searchKey {
    final norm = title.toLowerCase();
    final y = year != null ? ' ($year)' : '';
    return '$norm$y';
  }
}

enum ScrapeType { movie, tv }