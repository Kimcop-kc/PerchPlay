import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/online_subtitle.dart';
import 'package:perchplay/services/subtitle/subtitle_matcher_online.dart';
import 'package:perchplay/services/subtitle/subtitle_source.dart';

OnlineSubtitle _sub({
  String name = 'x',
  String? movieName,
  int? year,
  int? season,
  int? episode,
  String? releaseGroup,
  String languageCode = 'zh',
  String format = 'srt',
}) {
  return OnlineSubtitle(
    id: '1',
    name: name,
    source: 'test',
    languageCode: languageCode,
    languageName: languageCode,
    format: format,
    downloadUrl: 'url',
    movieName: movieName,
    year: year,
    season: season,
    episode: episode,
    releaseGroup: releaseGroup,
  );
}

void main() {
  group('名称匹配', () {
    test('精确名称匹配得高分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar'),
        _sub(movieName: 'Interstellar'),
      );
      expect(score.score, greaterThanOrEqualTo(0.4));
      expect(score.reasons, contains('名称精确匹配'));
    });

    test('包含关系匹配', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar 2014'),
        _sub(movieName: 'Interstellar'),
      );
      expect(score.score, greaterThanOrEqualTo(0.35));
    });

    test('完全不同名称得低分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar'),
        _sub(movieName: 'The Matrix'),
      );
      expect(score.score, lessThan(0.2));
    });
  });

  group('年份匹配', () {
    test('年份精确匹配加分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar', year: 2014),
        _sub(movieName: 'Interstellar', year: 2014),
      );
      expect(score.reasons, contains('年份匹配'));
    });

    test('年份不匹配不加分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar', year: 2014),
        _sub(movieName: 'Interstellar', year: 2000),
      );
      expect(score.reasons, isNot(contains('年份匹配')));
    });
  });

  group('语言匹配', () {
    test('语言匹配加分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'x', languageCode: 'zh'),
        _sub(languageCode: 'zh'),
      );
      expect(score.reasons, contains('语言匹配'));
    });
  });

  group('电视剧集数匹配', () {
    test('季集精确匹配加分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Show', season: 1, episode: 2),
        _sub(movieName: 'Show', season: 1, episode: 2),
      );
      expect(score.reasons, contains('集数匹配 S1E2'));
    });

    test('集数不同不加集数分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Show', season: 1, episode: 2),
        _sub(movieName: 'Show', season: 1, episode: 3),
      );
      expect(score.reasons, isNot(contains('集数匹配 S1E2')));
    });
  });

  group('版本匹配', () {
    test('发布组匹配加分', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(
            title: 'Movie', fileName: 'Movie.2023.1080p.WEB-DL.mkv'),
        _sub(movieName: 'Movie', releaseGroup: 'WEB-DL'),
      );
      expect(score.reasons, contains('版本匹配 WEB-DL'));
    });
  });

  group('高/低置信度阈值', () {
    test('完全匹配达到高置信度', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(
          title: 'Interstellar',
          year: 2014,
          languageCode: 'zh',
          format: 'srt',
        ),
        _sub(
          movieName: 'Interstellar',
          year: 2014,
          languageCode: 'zh',
          format: 'srt',
        ),
      );
      expect(score.score, greaterThanOrEqualTo(SubtitleMatcher.highConfidence));
    });

    test('无任何匹配信息时低于低置信度', () {
      final score = SubtitleMatcher.score(
        const SubtitleQuery(title: 'Interstellar'),
        _sub(movieName: 'The Matrix'),
      );
      expect(score.score, lessThan(SubtitleMatcher.lowConfidence));
    });
  });
}
