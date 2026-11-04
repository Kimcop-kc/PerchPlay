// 缺口 2 / 缺口 3 的回归测试：
//  缺口2 - castVideo(远程 http 地址) 必须走 M06 代理分流，不能把裸直链/127.0.0.1 塞给电视
//  缺口3 - 网盘「串流代理(127.0.0.1) → 投屏」双层链路：电视端 URL 必须可达且内容完整
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/providers/cast_provider.dart';
import 'package:perchplay/services/cloud/stream_proxy_server.dart';

/// 假 DLNA 渲染器，记录 SetAVTransportURI 的 CurrentURI。
class _Renderer {
  HttpServer? _server;
  int get port => _server!.port;
  String lastUri = '';

  static const _desc = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Fake TV</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/AVTransport/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      if (req.method == 'GET') {
        req.response.write(_desc);
        await req.response.close();
        return;
      }
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final m = RegExp(r'<CurrentURI>([^<]+)</CurrentURI>')
          .firstMatch(utf8.decode(body));
      if (m != null) lastUri = m.group(1)!;
      final action =
          RegExp(r'<u:([A-Za-z]+)').firstMatch(utf8.decode(body))?.group(1) ?? '';
      req.response.write(
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="urn:upnp-org:service"/></s:Body></s:Envelope>',
      );
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

/// 假 CDN：要求 Cookie，支持 Range。
class _FakeCdn {
  HttpServer? _server;
  int get port => _server!.port;
  final List<int> payload;
  int _authOk = 0;
  int _authFail = 0;
  int get authOk => _authOk;
  int get authFail => _authFail;

  _FakeCdn(this.payload);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      if (req.headers.value('cookie') != '__pus=test') {
        _authFail++;
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      _authOk++;
      final range = req.headers.value('range');
      if (range != null && range.startsWith('bytes=')) {
        final spec = range.substring(6);
        final dash = spec.indexOf('-');
        final s = int.parse(spec.substring(0, dash));
        final eStr = spec.substring(dash + 1);
        final e = eStr.isEmpty ? payload.length - 1 : int.parse(eStr);
        final end = e >= payload.length ? payload.length - 1 : e;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers
            .set('content-range', 'bytes $s-$end/${payload.length}');
        req.response.headers.set('content-length', '${end - s + 1}');
        req.response.add(payload.sublist(s, end + 1));
      } else {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set('content-length', '${payload.length}');
        req.response.add(payload);
      }
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('缺口2: castVideo(远程 http) 走代理分流，电视不收到裸直链', () async {
    final renderer = _Renderer();
    await renderer.start();
    final payload = List<int>.generate(64 * 1024, (i) => i & 0xff);
    final cdn = _FakeCdn(payload);
    await cdn.start();

    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't', name: 'Fake', protocol: CastProtocol.dlna,
        host: '127.0.0.1', port: renderer.port,
        location: 'http://127.0.0.1:${renderer.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      // 模拟旧调用方：直接把远程 URL 交给 castVideo
      final remoteUrl = 'http://127.0.0.1:${cdn.port}/video.mp4';
      final ok = await notifier.castVideo(
        remoteUrl,
        title: 'movie',
        headers: {'Cookie': '__pus=test'},
      );
      expect(ok, isTrue,
          reason: 'castVideo 应能投屏，error=${notifier.state.errorMessage}');

      // 电视收到的 URL 不能是裸直链（否则鉴权头丢失，电视直接连 CDN 会 403）
      final tvUrl = renderer.lastUri;
      expect(tvUrl, isNotEmpty);
      expect(tvUrl, isNot(remoteUrl),
          reason: 'castVideo 不能把裸直链直接塞给电视');

      await notifier.disconnect();
    } finally {
      await cdn.stop();
      await renderer.stop();
    }
  });

  test('缺口3: 网盘串流代理(127.0.0.1) → 投屏 双层链路内容完整', () async {
    final renderer = _Renderer();
    await renderer.start();
    final payload = List<int>.generate(256 * 1024, (i) => (i * 7) & 0xff);
    final cdn = _FakeCdn(payload);
    await cdn.start();

    // 第一层：网盘播放用的串流代理（模拟 cloud_drive_page 的 startStreamProxy）
    final streamProxy = await StreamProxyServer.start(
      resolveUrl: () async => 'http://127.0.0.1:${cdn.port}/video.mp4',
      headers: () => {'Cookie': '__pus=test'},
    );

    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't', name: 'Fake', protocol: CastProtocol.dlna,
        host: '127.0.0.1', port: renderer.port,
        location: 'http://127.0.0.1:${renderer.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      // 播放器里 videoPath = 串流代理的 127.0.0.1 地址
      final playerUrl = streamProxy.urlFor();
      expect(playerUrl, contains('127.0.0.1'));

      final ok = await notifier.castLocalFile(playerUrl, title: 'cloud');
      expect(ok, isTrue,
          reason: '串流代理地址也应能投屏，error=${notifier.state.errorMessage}');

      final tvUrl = renderer.lastUri;
      expect(tvUrl, isNotEmpty);
      expect(tvUrl, isNot(contains('127.0.0.1')),
          reason: '电视不能拿到 127.0.0.1 地址，实际=$tvUrl');

      // 关键闭环：电视端 URL 真实拉取，内容完整
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse(tvUrl))).close();
      expect(resp.statusCode, HttpStatus.ok,
          reason: '电视端 URL 应能取到内容');
      final got = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      client.close();
      expect(got.length, payload.length, reason: '双层链路内容长度不一致');
      expect(got[0], payload[0]);
      expect(got[payload.length - 1], payload[payload.length - 1]);

      await notifier.disconnect();
    } finally {
      await streamProxy.stop();
      await cdn.stop();
      await renderer.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
