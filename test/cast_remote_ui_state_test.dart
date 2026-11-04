// 投屏遥控 UI 的状态闭环测试：
//  音量滑条需要 state.volume 可读写（setVolume 同步到 state）
//  seek 进度控制需要 state 反映 seek 目标（可选，UI 主要是单向控制）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/providers/cast_provider.dart';

/// 假 DLNA 渲染器（支持 RenderingControl 的 SetVolume 与 AVTransport 的 Seek）。
class _Renderer {
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
      if (req.method == 'GET') {
        req.response.write(_desc);
        await req.response.close();
        return;
      }
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final action =
          RegExp(r'<u:([A-Za-z]+)').firstMatch(String.fromCharCodes(body))?.group(1) ?? '';
      final soapaction = req.headers.value('soapaction') ?? '';
      log.add('${req.uri.path} action=$action soapaction=$soapaction body=${String.fromCharCodes(body)}');
      req.response.write(
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="urn:upnp-org:service"/></s:Body></s:Envelope>',
      );
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('CastNotifier.setVolume 同步 volume 到 state（音量滑条可读）', () async {
    final r = _Renderer();
    await r.start();
    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't', name: 'Fake', protocol: CastProtocol.dlna,
        host: '127.0.0.1', port: r.port,
        location: 'http://127.0.0.1:${r.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      await notifier.setVolume(65);
      expect(notifier.state.volume, 65,
          reason: 'setVolume 后 state.volume 必须同步，供滑条显示当前值');

      await notifier.disconnect();
    } finally {
      await r.stop();
    }
  });

  test('CastNotifier.seek 透传到 AVTransport（进度控制）', () async {
    final r = _Renderer();
    await r.start();
    try {
      final notifier = CastNotifier();
      final device = CastDevice(
        id: 't', name: 'Fake', protocol: CastProtocol.dlna,
        host: '127.0.0.1', port: r.port,
        location: 'http://127.0.0.1:${r.port}/description.xml',
        supportsVideo: true,
      );
      await notifier.connect(device);

      await notifier.seek(120);
      final seekLog = r.log.where((l) => l.contains('Seek')).join('\n');
      expect(seekLog, isNotEmpty, reason: '应发送 Seek 命令');
      expect(seekLog, contains('/AVTransport/control'),
          reason: 'Seek 走 AVTransport，实际=$seekLog');
      expect(seekLog, contains('00:02:00'),
          reason: '120 秒应格式化成 00:02:00，实际=$seekLog');

      await notifier.disconnect();
    } finally {
      await r.stop();
    }
  });
}
