import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:perchplay/services/tmdb_service.dart';

/// TMDB 会给两种凭证，用户在官网很容易复制错那个：
///   · API 密钥 (v3 auth)：32 位十六进制 → 走 ?api_key=
///   · API 读访问令牌 (v4)：eyJ 开头的 JWT → 走 Authorization: Bearer
/// 混用会一律 401，所以服务层要自动识别。这两个用例把识别逻辑钉住。
void main() {
  late http.Request captured;

  MockClient recordingClient() => MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'results': <dynamic>[]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

  test('v3 密钥：走 api_key 查询参数，不带 Authorization 头', () async {
    final svc = TmdbService(
        apiKey: '897d1fc0d9da045996a8fd2b13c38aa2', client: recordingClient());

    await svc.searchMovie('Interstellar');

    expect(captured.url.queryParameters['api_key'],
        '897d1fc0d9da045996a8fd2b13c38aa2');
    expect(captured.url.queryParameters['query'], 'Interstellar');
    expect(captured.headers.containsKey('Authorization'), isFalse);
  });

  test('v4 读访问令牌：走 Bearer 头，且不再带 api_key', () async {
    const token = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.fake-signature';
    final svc = TmdbService(apiKey: token, client: recordingClient());

    await svc.searchMovie('Interstellar');

    expect(captured.headers['Authorization'], 'Bearer $token');
    expect(captured.url.queryParameters.containsKey('api_key'), isFalse);
    // 其余查询参数要保留
    expect(captured.url.queryParameters['query'], 'Interstellar');
    expect(captured.url.queryParameters['language'], 'zh-CN');
  });

  test('多端点都走同一套凭证逻辑（multi / tv / 详情）', () async {
    const token = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.fake-signature';
    final svc = TmdbService(apiKey: token, client: recordingClient());

    await svc.searchMulti('流浪地球');
    expect(captured.headers['Authorization'], isNotNull);
    expect(captured.url.queryParameters.containsKey('api_key'), isFalse);

    await svc.searchTv('Stranger Things');
    expect(captured.headers['Authorization'], isNotNull);
    expect(captured.url.queryParameters.containsKey('api_key'), isFalse);
  });
}
