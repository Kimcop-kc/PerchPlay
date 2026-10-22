// OpenSubtitles 适配器测试
//
// 用 MockClient 注入假 HTTP 响应，验证：
// - 搜索响应解析（正常结果、空结果、字段缺失）
// - 语言归一化
// - 错误分类（401/429/5xx/无效 JSON）
// - 下载链接解析
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perchplay/models/online_subtitle.dart';
import 'package:perchplay/services/subtitle/opensubtitles_source.dart';
import 'package:perchplay/services/subtitle/subtitle_source.dart';

late Uri lastUri;
late Map<String, String> lastHeaders;

OpenSubtitlesSource _service(
  Object body, {
  int status = 200,
  void Function(Uri uri)? onRequest,
}) {
  final client = MockClient((req) async {
    lastUri = req.url;
    lastHeaders = req.headers;
    onRequest?.call(req.url);
    return http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return OpenSubtitlesSource(apiKey: 'test-key', client: client);
}

Map<String, dynamic> _item({
  String id = '123',
  String fileName = 'Movie.2023.1080p.WEB-DL.srt',
  String language = 'en',
  Map<String, dynamic>? featureDetails,
}) {
  return {
    'id': id,
    'attributes': {
      'language': language,
      'download_count': 5000,
      'files': [
        {'file_id': 998877, 'file_name': fileName},
      ],
      if (featureDetails != null) 'feature_details': featureDetails,
    },
  };
}

void main() {
  group('search 正常解析', () {
    test('解析单条结果（含影片信息）', () async {
      final svc = _service({
        'data': [
          _item(
            id: '123',
            language: 'zh',
            featureDetails: {
              'title': '星际穿越',
              'year': 2014,
              'imdb_id': 'tt0816692',
              'season_number': null,
              'episode_number': null,
            },
          ),
        ],
      });

      final results = await svc
          .search(const SubtitleQuery(fileName: 'Interstellar.2014.mkv'));
      expect(results.length, 1);
      final r = results.first;
      expect(r.id, '123');
      expect(r.source, 'opensubtitles');
      expect(r.languageCode, 'zh');
      expect(r.languageName, '中文');
      expect(r.format, 'srt');
      expect(r.downloadUrl, '998877'); // file_id
      expect(r.movieName, '星际穿越');
      expect(r.year, 2014);
      expect(r.releaseGroup, 'WEB-DL');
    });

    test('语言归一化：eng → en', () async {
      final svc = _service({
        'data': [_item(language: 'eng')],
      });
      final results = await svc.search(const SubtitleQuery(title: 'x'));
      expect(results.first.languageCode, 'en');
    });

    test('空结果返回空列表', () async {
      final svc = _service({'data': []});
      final results = await svc.search(const SubtitleQuery(title: 'x'));
      expect(results, isEmpty);
    });

    test('字段缺失的文件项被跳过', () async {
      final svc = _service({
        'data': [
          {
            'id': '1',
            'attributes': {'files': []}
          }, // 无文件
          _item(id: '2'),
        ],
      });
      final results = await svc.search(const SubtitleQuery(title: 'x'));
      expect(results.length, 1);
      expect(results.first.id, '2');
    });

    test('查询参数：imdb_id 优先', () async {
      final svc = _service({'data': []});
      await svc.search(const SubtitleQuery(
        imdbId: 'tt0816692',
        fileName: 'Interstellar.mkv',
        languageCode: 'zh',
      ));
      expect(lastUri.queryParameters['imdb_id'], 'tt0816692');
      expect(lastUri.queryParameters['languages'], 'zh');
      expect(lastUri.queryParameters.containsKey('query'), false);
    });

    test('无 imdb_id 时用 fileName 作 query', () async {
      final svc = _service({'data': []});
      await svc.search(const SubtitleQuery(fileName: 'Interstellar.mkv'));
      expect(lastUri.queryParameters['query'], 'Interstellar.mkv');
    });
  });

  group('错误分类', () {
    test('401 → unauthorized，且服务置为不可用', () async {
      final svc = _service('{}', status: 401);
      expect(svc.isAvailable, true);
      await expectLater(
        svc.search(const SubtitleQuery(title: 'x')),
        throwsA(isA<SubtitleServiceException>()
            .having((e) => e.type, 'type', SubtitleErrorType.unauthorized)),
      );
      expect(svc.isAvailable, false);
    });

    test('429 → quotaExceeded', () async {
      final svc = _service('{}', status: 429);
      await expectLater(
        svc.search(const SubtitleQuery(title: 'x')),
        throwsA(isA<SubtitleServiceException>()
            .having((e) => e.type, 'type', SubtitleErrorType.quotaExceeded)),
      );
    });

    test('5xx → serviceUnavailable', () async {
      final svc = _service('{}', status: 503);
      await expectLater(
        svc.search(const SubtitleQuery(title: 'x')),
        throwsA(isA<SubtitleServiceException>().having(
            (e) => e.type, 'type', SubtitleErrorType.serviceUnavailable)),
      );
    });

    test('无效 JSON → parseError', () async {
      final svc = _service('not json', status: 200);
      await expectLater(
        svc.search(const SubtitleQuery(title: 'x')),
        throwsA(isA<SubtitleServiceException>()
            .having((e) => e.type, 'type', SubtitleErrorType.parseError)),
      );
    });

    test('无 API Key → unauthorized', () async {
      final svc = OpenSubtitlesSource(
          apiKey: '',
          client: MockClient((_) async {
            return http.Response('{}', 200);
          }));
      await expectLater(
        svc.search(const SubtitleQuery(title: 'x')),
        throwsA(isA<SubtitleServiceException>()
            .having((e) => e.type, 'type', SubtitleErrorType.unauthorized)),
      );
    });
  });

  group('resolveDownloadUrl', () {
    test('解析下载链接', () async {
      final client = MockClient((req) async {
        expect(req.method, 'POST');
        return http.Response(
          jsonEncode({'link': 'https://dl.example.com/sub.srt'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final source = OpenSubtitlesSource(apiKey: 'key', client: client);
      final link = await source.resolveDownloadUrl(
        const OnlineSubtitle(
          id: '1',
          name: 'x',
          source: 'opensubtitles',
          languageCode: 'en',
          languageName: 'English',
          format: 'srt',
          downloadUrl: '998877',
        ),
      );
      expect(link, 'https://dl.example.com/sub.srt');
    });

    test('下载链接缺失 → parseError', () async {
      final client = MockClient((req) async {
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      });
      final source = OpenSubtitlesSource(apiKey: 'key', client: client);
      await expectLater(
        source.resolveDownloadUrl(const OnlineSubtitle(
          id: '1',
          name: 'x',
          source: 'opensubtitles',
          languageCode: 'en',
          languageName: 'English',
          format: 'srt',
          downloadUrl: '1',
        )),
        throwsA(isA<SubtitleServiceException>()),
      );
    });
  });
}
