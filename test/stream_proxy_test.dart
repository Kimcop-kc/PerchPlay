import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/cloud/stream_proxy_server.dart';

/// 串流代理的端到端验证。
///
/// 用本地起一个「假 CDN」，校验：
///  - Range 请求是否被正确转发
///  - 分块是否按序拼回完整内容
///  - 鉴权头是否每块都带上
///  - CDN 返回 200（忽略 Range）时是否被判为失败
void main() {
  /// 造一个假的 CDN：支持 Range，且要求必须带 Cookie。
  Future<HttpServer> startFakeCdn(
    Uint8List payload, {
    bool honorRange = true,
    bool requireCookie = true,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (requireCookie) {
        final ck = req.headers.value('cookie') ?? '';
        if (!ck.contains('__pus=')) {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
          return;
        }
      }
      final range = req.headers.value('range');
      if (honorRange && range != null && range.startsWith('bytes=')) {
        final spec = range.substring(6);
        final dash = spec.indexOf('-');
        final s = int.parse(spec.substring(0, dash));
        final e = spec.substring(dash + 1).isEmpty
            ? payload.length - 1
            : int.parse(spec.substring(dash + 1));
        final end = e >= payload.length ? payload.length - 1 : e;
        final slice = Uint8List.sublistView(payload, s, end + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set('content-range',
            'bytes $s-$end/${payload.length}');
        req.response.headers.set('content-length', '${slice.length}');
        req.response.add(slice);
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set('content-length', '${payload.length}');
        req.response.add(payload);
      }
      await req.response.close();
    });
    return server;
  }

  /// 用 HTTP 客户端完整读取一个 URL（模拟播放器行为）。
  Future<Uint8List> fetchAll(String url, {String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final resp = await req.close();
    final out = BytesBuilder();
    await for (final d in resp) {
      out.add(d);
    }
    client.close();
    return out.takeBytes();
  }

  group('StreamProxyServer', () {
    test('端到端：分块拉取能完整还原内容', () async {
      // 造 5MB 数据，跨多个 2MB 分块
      final payload = Uint8List(5 * 1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i & 0xff;
      }
      final cdn = await startFakeCdn(payload);
      final cdnUrl = 'http://127.0.0.1:${cdn.port}/file';

      final proxy = await StreamProxyServer.start(
        resolveUrl: () async => cdnUrl,
        headers: () => {'Cookie': '__pus=test', 'Referer': 'https://pan.quark.cn/'},
      );

      final got = await fetchAll(proxy.urlFor());
      expect(got.length, equals(payload.length), reason: '长度不一致');
      // 逐段比对（避免整体 equals 在大数组上太慢）
      var ok = true;
      for (var i = 0; i < payload.length; i += 4096) {
        final end = (i + 4096 > payload.length) ? payload.length : i + 4096;
        for (var j = i; j < end; j++) {
          if (got[j] != payload[j]) {
            ok = false;
            break;
          }
        }
        if (!ok) break;
      }
      expect(ok, isTrue, reason: '内容不一致');

      await proxy.stop();
      await cdn.close(force: true);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('Range 请求：只返回请求的区间', () async {
      final payload = Uint8List.fromList(List.generate(1024 * 1024, (i) => i & 0xff));
      final cdn = await startFakeCdn(payload);
      final cdnUrl = 'http://127.0.0.1:${cdn.port}/file';

      final proxy = await StreamProxyServer.start(
        resolveUrl: () async => cdnUrl,
        headers: () => {'Cookie': '__pus=test'},
      );

      final got = await fetchAll(proxy.urlFor(), range: 'bytes=100-199');
      expect(got.length, equals(100));
      for (var i = 0; i < 100; i++) {
        expect(got[i], equals((100 + i) & 0xff));
      }

      await proxy.stop();
      await cdn.close(force: true);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('CDN 缺少 Cookie 时代理应失败', () async {
      final payload = Uint8List.fromList(List.generate(1024, (i) => i));
      final cdn = await startFakeCdn(payload, requireCookie: true);
      final cdnUrl = 'http://127.0.0.1:${cdn.port}/file';

      final proxy = await StreamProxyServer.start(
        resolveUrl: () async => cdnUrl,
        // 故意不给 Cookie
        headers: () => {'Referer': 'https://pan.quark.cn/'},
      );

      // 探测失败 → 返回 502
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(proxy.urlFor()));
      final resp = await req.close();
      await resp.drain<void>();
      expect(resp.statusCode, equals(HttpStatus.badGateway));
      client.close();

      await proxy.stop();
      await cdn.close(force: true);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('CDN 忽略 Range 时不应返回错位数据', () async {
      final payload = Uint8List.fromList(List.generate(1024 * 1024, (i) => i & 0xff));
      // honorRange=false：CDN 永远返回 200 + 全量
      final cdn = await startFakeCdn(payload, honorRange: false);
      final cdnUrl = 'http://127.0.0.1:${cdn.port}/file';

      final proxy = await StreamProxyServer.start(
        resolveUrl: () async => cdnUrl,
        headers: () => {'Cookie': '__pus=test'},
      );

      // 这种源会被探测识别为「不支持 Range」，代理退回整段转发。
      // 关键是不能返回错位的分块数据 —— 长度必须等于原文件。
      final got = await fetchAll(proxy.urlFor());
      expect(got.length, equals(payload.length));
      expect(got[0], equals(0));
      expect(got[payload.length - 1], equals((payload.length - 1) & 0xff));

      await proxy.stop();
      await cdn.close(force: true);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
