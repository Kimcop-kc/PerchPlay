// 刮削候选匹配测试
//
// 背景：原来直接取 TMDB 返回的第一条，中文片名场景下经常挑错片子、
// 贴错海报且用户无从察觉。这里把"该挑哪一条"钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/scrape_matcher.dart';

ScrapeResult _r(
  String title, {
  String? original,
  int? year,
  int tmdbId = 1,
  int? voteCount,
  ScrapeType type = ScrapeType.movie,
}) {
  return ScrapeResult(
    title: title,
    originalTitle: original,
    year: year,
    type: type,
    tmdbId: tmdbId,
    voteCount: voteCount,
  );
}

void main() {
  group('normalize', () {
    test('去标点、转小写、保留汉字与数字', () {
      expect(ScrapeMatcher.normalize('Heartstopper.Forever.2160p'),
          'heartstopper forever 2160p');
      expect(ScrapeMatcher.normalize('流浪地球2'), '流浪地球2');
      expect(ScrapeMatcher.normalize('[字幕组] 让子弹飞'), '字幕组 让子弹飞');
      expect(ScrapeMatcher.normalize('  A   B  '), 'a b');
    });
  });

  group('similarity', () {
    test('完全相同 = 1', () {
      expect(ScrapeMatcher.similarity('Interstellar', 'interstellar'), 1);
    });

    test('包含关系得高分（续集/副标题）', () {
      final s = ScrapeMatcher.similarity('流浪地球', '流浪地球2');
      expect(s, greaterThan(0.7));
      expect(s, lessThan(1));
    });

    test('无关片名分数很低', () {
      expect(ScrapeMatcher.similarity('Interstellar', 'The Notebook'),
          lessThan(0.3));
    });

    test('空串不匹配', () {
      expect(ScrapeMatcher.similarity('', 'abc'), 0);
      expect(ScrapeMatcher.similarity('abc', ''), 0);
    });
  });

  group('best：不再盲取第一条', () {
    test('第一条是无关片子时，能挑出真正匹配的那条', () {
      final candidates = [
        _r('The Notebook', year: 2004, tmdbId: 1),
        _r('Interstellar', year: 2014, tmdbId: 2),
        _r('Interstellar Wars', year: 2018, tmdbId: 3),
      ];
      final best =
          ScrapeMatcher.best(candidates, query: 'Interstellar', year: 2014);
      expect(best?.tmdbId, 2);
    });

    test('zh-CN 下 title 是中文、靠 originalTitle 命中', () {
      final candidates = [
        _r('星际穿越', original: 'Interstellar', year: 2014, tmdbId: 2),
        _r('盗梦空间', original: 'Inception', year: 2010, tmdbId: 9),
      ];
      final best = ScrapeMatcher.best(candidates, query: 'Interstellar');
      expect(best?.tmdbId, 2);
    });

    test('同名不同年份：按年份挑（重拍片最容易错）', () {
      final candidates = [
        _r('A Star Is Born', year: 1976, tmdbId: 1),
        _r('A Star Is Born', year: 2018, tmdbId: 2),
      ];
      expect(
        ScrapeMatcher.best(candidates, query: 'A Star Is Born', year: 2018)
            ?.tmdbId,
        2,
      );
      expect(
        ScrapeMatcher.best(candidates, query: 'A Star Is Born', year: 1976)
            ?.tmdbId,
        1,
      );
    });

    test('年份差 3 年以上会被压下去', () {
      final candidates = [
        _r('The Thing', year: 1982, tmdbId: 1),
        _r('The Thing', year: 2011, tmdbId: 2),
      ];
      expect(
        ScrapeMatcher.best(candidates, query: 'The Thing', year: 2011)?.tmdbId,
        2,
      );
    });

    test('完全不像时返回 null（宁可没海报也不贴错）', () {
      final candidates = [_r('完全无关的片子', year: 1990, tmdbId: 5)];
      expect(
        ScrapeMatcher.best(candidates,
            query: 'Heartstopper Forever', year: 2025),
        isNull,
      );
    });

    test('空候选返回 null', () {
      expect(ScrapeMatcher.best(const [], query: 'x'), isNull);
    });

    test('片名相同时，投票数高的优先', () {
      final candidates = [
        _r('Dune', year: 2021, tmdbId: 1, voteCount: 10),
        _r('Dune', year: 2021, tmdbId: 2, voteCount: 30000),
      ];
      expect(
          ScrapeMatcher.best(candidates, query: 'Dune', year: 2021)?.tmdbId, 2);
    });

    test('用户报的场景：带中文标签的文件名清洗后能命中', () {
      final candidates = [
        _r('永远心跳漏一拍',
            original: 'Heartstopper Forever', year: 2025, tmdbId: 1468683),
        _r('心跳漏一拍',
            original: 'Heartstopper',
            year: 2022,
            tmdbId: 111,
            type: ScrapeType.tv),
      ];
      final best =
          ScrapeMatcher.best(candidates, query: 'Heartstopper Forever');
      expect(best?.tmdbId, 1468683);
    });
  });

  group('score', () {
    test('年份一致加分、差得多扣分', () {
      final base = _r('Movie', year: 2020);
      final s0 = ScrapeMatcher.score(base, query: 'Movie', year: 2020);
      final s1 = ScrapeMatcher.score(base, query: 'Movie', year: 2021);
      final sFar = ScrapeMatcher.score(base, query: 'Movie', year: 1990);
      expect(s0, greaterThan(s1));
      expect(s1, greaterThan(sFar));
    });

    test('不提供年份时不加减', () {
      final c = _r('Movie', year: 2020);
      expect(
        ScrapeMatcher.score(c, query: 'Movie'),
        ScrapeMatcher.score(c, query: 'Movie', year: 2020) - 30,
      );
    });
  });
}
