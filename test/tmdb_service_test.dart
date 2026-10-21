// TMDB 服务测试
//
// 用 MockClient 注入假的 HTTP 响应，不联网就能把
// 「JSON → ScrapeResult」的解析逻辑钉住 —— 这块以前完全没有测试，
// 而它直接决定海报/年份/评分对不对。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perchplay/models/scrape_result.dart';
import 'package:perchplay/services/tmdb_service.dart';

/// 记录最后一次请求的 URL，方便断言参数
late Uri lastUri;

TmdbService _service(
  Object body, {
  int status = 200,
  void Function(Uri uri)? onRequest,
}) {
  final client = MockClient((req) async {
    lastUri = req.url;
    onRequest?.call(req.url);
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return TmdbService(apiKey: 'test-key', client: client);
}

void main() {
  group('searchMulti', () {
    test('解析电影与剧集，跳过 person 与无标题项', () async {
      final svc = _service({
        'results': [
          {
            'media_type': 'movie',
            'id': 1,
            'title': '星际穿越',
            'original_title': 'Interstellar',
            'release_date': '2014-11-05',
            'vote_average': 8.4,
            'vote_count': 30000,
            'poster_path': '/p1.jpg',
          },
          {
            'media_type': 'tv',
            'id': 2,
            'name': '心跳漏一拍',
            'original_name': 'Heartstopper',
            'first_air_date': '2022-04-22',
          },
          {'media_type': 'person', 'id': 3, 'name': '某演员'},
          {'media_type': 'movie', 'id': 4}, // 无标题 → 丢弃
        ],
      });

      final r = await svc.searchMulti('interstellar');

      expect(r.length, 2);
      expect(r[0].title, '星际穿越');
      expect(r[0].originalTitle, 'Interstellar');
      expect(r[0].year, 2014);
      expect(r[0].type, ScrapeType.movie);
      expect(r[0].rating, 8.4);
      expect(r[0].voteCount, 30000);
      expect(r[1].title, '心跳漏一拍');
      expect(r[1].year, 2022);
      expect(r[1].type, ScrapeType.tv);

      // 参数正确带上
      expect(lastUri.queryParameters['api_key'], 'test-key');
      expect(lastUri.queryParameters['query'], 'interstellar');
      expect(lastUri.queryParameters['language'], 'zh-CN');
      expect(lastUri.path, endsWith('/search/multi'));
    });

    test('非 200 返回空列表而不是抛异常', () async {
      final svc = _service({'results': []}, status: 401);
      expect(await svc.searchMulti('x'), isEmpty);
    });

    test('响应缺 results 字段也不崩', () async {
      final svc = _service({'status_code': 7});
      expect(await svc.searchMulti('x'), isEmpty);
    });
  });

  group('searchMovie / searchTv', () {
    test('searchMovie 强制 movie 类型，并带上 year', () async {
      final svc = _service({
        'results': [
          {'id': 9, 'title': '沙丘', 'release_date': '2021-09-15'},
        ],
      });
      final r = await svc.searchMovie('沙丘', year: 2021);
      expect(r.single.type, ScrapeType.movie);
      expect(r.single.year, 2021);
      expect(lastUri.path, endsWith('/search/movie'));
      expect(lastUri.queryParameters['year'], '2021');
    });

    test('year 为空时不带 year 参数（否则 TMDB 会过滤掉结果）', () async {
      final svc = _service({'results': []});
      await svc.searchMovie('沙丘');
      expect(lastUri.queryParameters.containsKey('year'), isFalse);
    });

    test('searchTv 强制 tv 类型，first_air_date 取年份', () async {
      final svc = _service({
        'results': [
          {'id': 3, 'name': '怪奇物语', 'first_air_date': '2016-07-15'},
        ],
      });
      final r = await svc.searchTv('怪奇物语');
      expect(r.single.type, ScrapeType.tv);
      expect(r.single.title, '怪奇物语');
      expect(r.single.year, 2016);
      expect(lastUri.path, endsWith('/search/tv'));
    });
  });

  group('详情', () {
    test('电影详情：genres 名称、海报、评分', () async {
      final svc = _service({
        'id': 157336,
        'title': '星际穿越',
        'original_title': 'Interstellar',
        'release_date': '2014-11-05',
        'overview': '剧情简介',
        'poster_path': '/poster.jpg',
        'backdrop_path': '/back.jpg',
        'vote_average': 8.45,
        'vote_count': 35000,
        'genres': [
          {'id': 12, 'name': '冒险'},
          {'id': 18, 'name': '剧情'},
          {'id': 0}, // 无名 → 丢弃
        ],
      });

      final d = await svc.getMovieDetail(157336);

      expect(d, isNotNull);
      expect(d!.type, ScrapeType.movie);
      expect(d.genres, ['冒险', '剧情']);
      expect(d.posterUrl, 'https://image.tmdb.org/t/p/w500/poster.jpg');
      expect(d.posterThumbUrl, 'https://image.tmdb.org/t/p/w185/poster.jpg');
      expect(d.backdropUrl, 'https://image.tmdb.org/t/p/w780/back.jpg');
      expect(d.year, 2014);
      expect(d.overview, '剧情简介');
      expect(lastUri.path, endsWith('/movie/157336'));
    });

    test('剧集详情：name → title，first_air_date → 年份', () async {
      final svc = _service({
        'id': 100,
        'name': '心跳漏一拍',
        'original_name': 'Heartstopper',
        'first_air_date': '2022-04-22',
        'genres': [
          {'id': 18, 'name': '剧情'},
        ],
      });

      final d = await svc.getTvDetail(100);
      expect(d!.type, ScrapeType.tv);
      expect(d.title, '心跳漏一拍');
      expect(d.originalTitle, 'Heartstopper');
      expect(d.year, 2022);
      expect(lastUri.path, endsWith('/tv/100'));
    });

    test('详情非 200 返回 null', () async {
      final svc = _service({'x': 1}, status: 404);
      expect(await svc.getMovieDetail(1), isNull);
      expect(await svc.getTvDetail(1), isNull);
    });

    test('日期缺失时年份为 null，不崩', () async {
      final svc = _service({'id': 1, 'title': '未上映', 'release_date': ''});
      expect((await svc.getMovieDetail(1))!.year, isNull);
    });

    test('无海报时 posterUrl 为 null（界面应回退本地缩略图）', () async {
      final svc = _service({'id': 1, 'title': 'x', 'poster_path': null});
      expect((await svc.getMovieDetail(1))!.posterUrl, isNull);
    });
  });

  group('剧集单集详情', () {
    test('单集仍使用剧集标题，海报回退到剧集海报', () async {
      final svc = _service(
        {
          'name': '第 1 集',
          'overview': '本集简介',
          'still_path': null, // 没有剧照 → 用剧集海报
          'vote_average': 8.0,
        },
        onRequest: (uri) {
          // 本用例只请求单集接口，剧集详情通过 seriesInfo 传入
          expect(uri.path, contains('/season/1/episode/1'));
        },
      );

      const series = ScrapeResult(
        title: '心跳漏一拍',
        originalTitle: 'Heartstopper',
        year: 2022,
        posterPath: '/series.jpg',
        type: ScrapeType.tv,
        tmdbId: 100,
      );

      final ep = await svc.getEpisodeDetail(100, 1, 1, seriesInfo: series);

      expect(ep, isNotNull);
      expect(ep!.title, '心跳漏一拍');
      expect(ep.episodeTitle, '第 1 集');
      expect(ep.seasonNumber, 1);
      expect(ep.episodeNumber, 1);
      expect(ep.posterPath, '/series.jpg');
      expect(ep.overview, '本集简介');
    });

    test('单集有剧照时优先用剧照', () async {
      final svc = _service({'name': 'E1', 'still_path': '/still.jpg'});
      const series = ScrapeResult(
        title: 'S',
        posterPath: '/series.jpg',
        type: ScrapeType.tv,
        tmdbId: 1,
      );
      final ep = await svc.getEpisodeDetail(1, 1, 1, seriesInfo: series);
      expect(ep!.posterPath, '/still.jpg');
    });
  });

  group('searchKey', () {
    test('带年份与不带年份的 key 不同', () {
      const a = ScrapeResult(
          title: 'Dune', year: 2021, type: ScrapeType.movie, tmdbId: 1);
      const b = ScrapeResult(title: 'Dune', type: ScrapeType.movie, tmdbId: 1);
      expect(a.searchKey, 'dune (2021)');
      expect(b.searchKey, 'dune');
    });
  });
}
