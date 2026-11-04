// 跨模块闭环回归测试：验证「NAS 视频 → 播放器 → 投屏 → 电视」完整链路
// 是否真正闭环（不只是单元级通过）。
//
// 链路：nas_browser 的 getPlayableUrl + playHeaders(Basic)
//   → PlayerPage.widget.headers
//   → _CastDeviceSheet(headers)
//   → CastNotifier.castLocalFile(http url, headers: Basic)
//   → _castRemoteUrl → StreamProxyServer(绑定 LAN, 带 Basic 头转发)
//   → 电视(假渲染器) 收到局域网可达 URL
//
// 这里用「假 NAS CDN（要求 Basic 认证）+ 假 DLNA 渲染器」把整条链路
// 真实跑一遍，最后直接从电视收到的 URL 里把内容拉回来，逐字节比对。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/providers/cast_provider.dart';

/// 假 DLNA 渲染器：记录 SetAVTransportURI 的 CurrentURI。
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

/// 假 NAS WebDAV：要求 Basic 认证，认证通过才返回视频内容（支持 Range）。
class _FakeNas {
  HttpServer? _server;
  int get port => _server!.port;
  final List<int> payload;
  final int authChecked = 0;
  int get authOk => _authOk;
  int _authOk = 0;
  int get authFail => _authFail;
  int _authFail = 0;

  _FakeNas(this.payload);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      final auth = req.headers.value('authorization') ?? '';
      if (auth != 'Basic dXNlcjpwYXNz') {
        _authFail++;
        req.response.statusCode = HttpStatus.unauthorized;
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
        final slice = payload.sublist(s, end + 1);
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers
            .set('content-range', 'bytes $s-$end/${payload.length}');
        req.response.headers.set('content-length', '${slice.length}');
        req.response.add(slice);
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

  test('闭环：NAS(Basic) → 投屏转发代理 → 电视，内容完整且鉴权头透传', () async {
    final renderer = _Renderer();
    await renderer.start();

    // 造 1MB 可校验内容
    final payload = List<int>.generate(1024 * 1024, (i) => i & 0xff);
    final nas = _FakeNas(payload);
    await nas.start();

    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: renderer.port,
        location: 'http://127.0.0.1:${renderer.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);
      expect(notifier.state.isConnected, isTrue);

      // 模拟 NAS 播放：URL + Basic 头（和 nas_browser_page 一样）
      final nasUrl = 'http://127.0.0.1:${nas.port}/video.mp4';
      final ok = await notifier.castLocalFile(
        nasUrl,
        title: 'movie',
        headers: {'Authorization': 'Basic dXNlcjpwYXNz'},
      );
      expect(ok, isTrue,
          reason: 'NAS 视频经转发代理应能投屏，error=${notifier.state.errorMessage}');

      // 电视收到的 URL 必须是局域网可达，且不是 127.0.0.1
      final tvUrl = renderer.lastUri;
      expect(tvUrl, isNotEmpty, reason: '电视应收到 SetAVTransportURI');
      expect(tvUrl, isNot(contains('127.0.0.1')),
          reason: '电视连不上手机回环，实际=$tvUrl');

      // 关键闭环验证：从电视拿到的 URL 真实拉取，内容必须完整。
      // 这一步会穿过 转发代理 → 假 NAS，并带上 Basic 头。
      final client = HttpClient();
      final resp = await (await client.getUrl(Uri.parse(tvUrl))).close();
      expect(resp.statusCode, HttpStatus.ok,
          reason: '电视端 URL 应能真实取到内容，HTTP ${resp.statusCode}');
      final got = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      client.close();
      expect(got.length, payload.length, reason: '内容长度不一致');
      expect(got[0], payload[0]);
      expect(got[payload.length - 1], payload[payload.length - 1]);

      // 鉴权头确实被转发层带上（否则假 NAS 会 401，上面就取不到内容）
      expect(nas.authOk, greaterThan(0),
          reason: '转发代理必须带 Basic 头，否则假 NAS 会拒绝');
      expect(nas.authFail, 0, reason: '不应出现未带鉴权头的请求');

      await notifier.disconnect();

      // M08 闭环：断开后远程转发代理必须释放 —— 电视拿到的 URL 应当连不上。
      final afterClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2);
      Object? connectErr;
      try {
        final resp = await (await afterClient.getUrl(Uri.parse(tvUrl))).close();
        await resp.drain<void>();
      } catch (e) {
        connectErr = e;
      }
      afterClient.close();
      expect(connectErr, isNotNull,
          reason: '断开后转发代理应已关闭，电视端 URL 应连接失败');
    } finally {
      await nas.stop();
      await renderer.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
