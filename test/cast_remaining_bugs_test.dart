// 剩余 bug 的回归测试：
//   M08 - disconnect 后 LocalMediaServer 关闭
//   M06 - http/https 远程视频走 LAN 可达代理；smb/ftp 明确报错
//   M09 - NAS 慢响应不覆盖新目录选择
//   M10 - 网盘字幕下载复用鉴权头
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/providers/cast_provider.dart';
import 'package:perchplay/providers/nas_provider.dart';
import 'package:perchplay/services/local_media_server.dart';
import 'package:perchplay/services/cloud_subtitle_service.dart';
import 'package:perchplay/services/cloud/cloud_drive_service.dart';
import 'package:perchplay/models/cloud_drive_model.dart';
import 'package:perchplay/models/nas_connection_model.dart';
import 'package:perchplay/services/nas_client_service.dart';

/// 内嵌假 DLNA 渲染器。
class _MiniRenderer {
  HttpServer? _server;
  int get port => _server!.port;
  final List<String> log = [];

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
      final action = RegExp(r'<u:([A-Za-z]+)')
              .firstMatch(utf8.decode(body))
              ?.group(1) ??
          '';
      final uri = RegExp(r'<CurrentURI>([^<]+)</CurrentURI>')
              .firstMatch(utf8.decode(body))
              ?.group(1) ??
          '';
      log.add('${req.uri.path} action=$action uri=$uri');
      req.response.write(
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="urn:upnp-org:service"/></s:Body></s:Envelope>',
      );
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

/// 可注入 listDirectory 行为的假 NAS 服务。
class _FakeNasService extends NasClientService {
  final Map<String, Future<List<NasFileItem>>> _byPath;
  _FakeNasService(this._byPath);

  @override
  Future<List<NasFileItem>> listDirectory(String connectionId, String path) {
    return _byPath[path] ?? Future.value([]);
  }

  @override
  Future<bool> connect(NasConnection config) async => true;
}

/// 可注入 drive 行为的假网盘服务。
class _FakeDrive extends CloudDriveService {
  final String downloadUrl;
  _FakeDrive(this.downloadUrl);

  @override
  Future<List<CloudFileItem>?> listDirectory(String accountId, String dirId,
          {String parentPath = '/'}) async =>
      [const CloudFileItem(id: 'sid', name: 'movie.srt', path: '/movie.srt')];

  @override
  Future<String?> getDownloadUrl(String accountId, String fileId) async =>
      downloadUrl;

  @override
  Future<Map<String, String>> resourceHeaders(String accountId) async => {
        'Cookie': 'session=abc',
        'User-Agent': 'exact-agent',
        'Referer': 'https://pan.example.invalid/',
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('M08: disconnect 后 LocalMediaServer 关闭', () async {
    final r = _MiniRenderer();
    await r.start();
    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.port,
        location: 'http://127.0.0.1:${r.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      final tmp = File(
          '${Directory.systemTemp.path}/cast_m08_${DateTime.now().microsecondsSinceEpoch}.bin');
      await tmp.writeAsBytes([1, 2, 3]);
      final url = await LocalMediaServer.instance.urlFor(tmp.path, title: 'x');
      expect(url, isNotNull);
      expect(LocalMediaServer.instance.isRunning, isTrue);

      await notifier.disconnect();
      expect(LocalMediaServer.instance.isRunning, isFalse,
          reason: '断开后本地媒体服务必须关闭（M08）');
      await tmp.delete();
    } finally {
      await LocalMediaServer.instance.stop();
      await r.stop();
    }
  });

  test('M06: http 远程视频经 LAN 可达代理投屏，不给电视 127.0.0.1', () async {
    final r = _MiniRenderer();
    await r.start();
    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.port,
        location: 'http://127.0.0.1:${r.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      final ok = await notifier.castLocalFile(
        'http://example.invalid/video.mp4',
        title: 'remote',
      );
      expect(ok, isTrue,
          reason: '远程 http 视频应能投屏，error=${notifier.state.errorMessage}');

      final setLog = r.log.where((l) => l.contains('SetAVTransportURI')).join('\n');
      expect(setLog, isNotEmpty);
      // 电视收到的 URL 不能是 127.0.0.1（电视连不上手机回环）
      expect(setLog, isNot(contains('uri=http://127.0.0.1')),
          reason: '不能把 127.0.0.1 地址给电视，实际=$setLog');

      await notifier.disconnect();
    } finally {
      await r.stop();
    }
  });

  test('M06: smb/ftp 远程路径明确报错', () async {
    final notifier = CastNotifier();
    final ok = await notifier.castLocalFile('smb://host/share/movie.mp4');
    expect(ok, isFalse);
    expect(notifier.state.errorMessage, contains('SMB'));
  });

  test('M09: 慢响应不覆盖较新的目录选择', () async {
    final slow = Completer<List<NasFileItem>>();
    final fast = Completer<List<NasFileItem>>();

    final svc = _FakeNasService({
      '/slow/': slow.future,
      '/fast/': fast.future,
    });
    final notifier = NasNotifier(service: svc);
    // 直接播种一个活跃连接（跳过 connect 的首次 navigateTo）
    notifier.seedForTest(const NasConnection(
      id: 'c1',
      name: 'NAS',
      protocol: NasProtocol.webdav,
      host: '127.0.0.1',
      port: 80,
      remotePath: '/',
    ));

    final p1 = notifier.navigateTo('/slow/');
    final p2 = notifier.navigateTo('/fast/');

    // fast 先返回
    fast.complete([
      const NasFileItem(name: 'fast.mp4', path: '/fast/fast.mp4')
    ]);
    await p2;
    expect(notifier.state.currentPath, '/fast/');

    // slow 后返回，必须被丢弃
    slow.complete([
      const NasFileItem(name: 'slow.mp4', path: '/slow/slow.mp4')
    ]);
    await p1;

    expect(notifier.state.currentPath, '/fast/',
        reason: '慢响应不能覆盖较新的目录选择（M09）');
  });

  test('M10: 网盘字幕下载复用鉴权头', () async {
    final root = await Directory.systemTemp.createTemp('cast_cloudsub_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var okCount = 0;
    server.listen((req) async {
      if (req.headers.value('cookie') != 'session=abc' ||
          req.headers.value('referer') != 'https://pan.example.invalid/' ||
          req.headers.value('user-agent') != 'exact-agent') {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      okCount++;
      req.response.write('1\n00:00:00,000 --> 00:00:01,000\nok\n\n');
      await req.response.close();
    });

    try {
      final drive = _FakeDrive('http://127.0.0.1:${server.port}/subtitle');
      final svc = CloudSubtitleService(drive: drive);
      final subs = await svc.findAndDownload(
        accountId: 'A',
        dirId: 'dir',
        videoName: 'movie.mp4',
      );
      expect(subs, hasLength(1),
          reason: '鉴权头正确时字幕应能下载（缺 Cookie/Referer 会被 403）');
      expect(okCount, 1);
    } finally {
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null);
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
