// 投屏错误传播 / 音量服务 / 断开清理 的回归测试。
//
// 这些测试用一个**内嵌的假 DLNA 渲染器**（不依赖 tools/fake_dlna_renderer.py）
// 来验证：
//   M04 - HTTP>=400 / SOAP Fault 必须让 playUrl 返回 false，且不发 playing 事件
//   M05 - SetVolume 必须发往 RenderingControl 的 controlURL 与 SOAPAction
//   M07 - disconnect 后 CastNotifier 的 activeDevice 必须清空
//
// M08（断开后 LocalMediaServer 关闭）与 M09（NAS 慢响应）在别的测试文件里。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/providers/cast_provider.dart';
import 'package:perchplay/services/cast_control_service.dart';

/// 内嵌假渲染器：可配置对每个 SOAP 动作返回 200 / 500 / Fault。
class _FakeRenderer {
  _FakeRenderer({this.failActions = const {}});

  /// 需要返回 500 的动作集合（如 {'SetAVTransportURI', 'Play'}）
  final Set<String> failActions;

  HttpServer? _server;
  int get actualPort => _server!.port;
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
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/RenderingControl/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      try {
        if (req.method == 'GET') {
          log.add('GET ${req.uri.path}');
          req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
          req.response.write(_desc);
          await req.response.close();
          return;
        }
        // POST
        final bodyBytes = await req.fold<List<int>>(
            <int>[], (a, b) => a..addAll(b));
        final body = utf8.decode(bodyBytes);
        final soapaction = req.headers.value('soapaction') ?? '';
        final actionMatch = RegExp(r'<u:([A-Za-z]+)').firstMatch(body);
        final action = actionMatch?.group(1) ?? '';
        log.add('POST ${req.uri.path} action=$action soapaction=$soapaction');

        if (failActions.contains(action)) {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.write('server error');
          await req.response.close();
          return;
        }
        // 正常：返回带 Response 的 SOAP envelope
        req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
        req.response.write(
          '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><u:${action}Response xmlns:u="urn:upnp-org:service"/></s:Body></s:Envelope>',
        );
        await req.response.close();
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('M04: SetAVTransportURI 返回 500 时 playUrl 必须 false 且不发 playing 事件',
      () async {
    final r = _FakeRenderer(failActions: {'SetAVTransportURI'});
    await r.start();
    try {
      final control = CastControlService.instance;
      final device = CastDevice(
        id: 'test',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.actualPort,
        location: 'http://127.0.0.1:${r.actualPort}/description.xml',
        supportsVideo: true,
      );
      expect(await control.connect(device), isTrue);

      var playingEvents = 0;
      final sub = control.statusStream.listen((e) {
        if (e.type == CastEventType.playing) playingEvents++;
      });

      final ok = await control.playUrl('http://192.168.1.50:1/video', title: 'x');
      expect(ok, isFalse, reason: 'HTTP 500 必须传播为失败，实际 lastError=${control.lastError}');
      expect(playingEvents, 0, reason: '失败时绝不能发 playing 事件');

      await sub.cancel();
      await control.disconnect();
    } finally {
      await r.stop();
    }
  });

  test('M04: Play 返回 SOAP Fault 时 playUrl 必须 false', () async {
    final r = _FakeRenderer(failActions: {'Play'});
    await r.start();
    try {
      final control = CastControlService.instance;
      final device = CastDevice(
        id: 'test',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.actualPort,
        location: 'http://127.0.0.1:${r.actualPort}/description.xml',
        supportsVideo: true,
      );
      expect(await control.connect(device), isTrue);
      final ok = await control.playUrl('http://192.168.1.50:1/video', title: 'x');
      expect(ok, isFalse, reason: 'Play 失败（HTTP 500）必须传播为 false');
      await control.disconnect();
    } finally {
      await r.stop();
    }
  });

  test('M05: SetVolume 发往 RenderingControl 的 controlURL 与 SOAPAction', () async {
    final r = _FakeRenderer();
    await r.start();
    try {
      final control = CastControlService.instance;
      final device = CastDevice(
        id: 'test',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.actualPort,
        location: 'http://127.0.0.1:${r.actualPort}/description.xml',
        supportsVideo: true,
      );
      expect(await control.connect(device), isTrue);
      await control.setVolume(30);

      final volLog = r.log.where((l) => l.contains('SetVolume')).toList();
      expect(volLog, isNotEmpty, reason: '应发送 SetVolume 命令');
      expect(volLog.first, contains('/RenderingControl/control'),
          reason: '音量必须走 RenderingControl 的 controlURL，实际=${volLog.first}');
      expect(volLog.first, contains('RenderingControl:1#SetVolume'),
          reason: 'SOAPAction 必须是 RenderingControl 服务，实际=${volLog.first}');
      await control.disconnect();
    } finally {
      await r.stop();
    }
  });

  test('M07: disconnect 后 CastNotifier 的 activeDevice 清空', () async {
    final r = _FakeRenderer();
    await r.start();
    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 'test',
        name: 'Fake',
        protocol: CastProtocol.dlna,
        host: '127.0.0.1',
        port: r.actualPort,
        location: 'http://127.0.0.1:${r.actualPort}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);
      expect(notifier.state.isConnected, isTrue);
      expect(notifier.state.activeDevice?.id, 'test');

      await notifier.disconnect();
      expect(notifier.state.isConnected, isFalse);
      expect(notifier.state.activeDevice, isNull,
          reason: '断开后 activeDevice 必须清空（M07）');
    } finally {
      await r.stop();
    }
  });
}
