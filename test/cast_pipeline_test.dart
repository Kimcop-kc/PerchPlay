// 投屏链路的真实测试（在开发机上跑，不依赖手机）：
// 1) LocalMediaServer 必须支持 Range 请求（电视拖进度条要用）
// 2) DLNA 连接必须从设备描述里解析出真实的 controlURL，并把
//    SetAVTransportURI / Play 发到那个地址
//
// 测试 2 需要一个本地假渲染器：
//   python tools/fake_dlna_renderer.py 8099
// 未启动时该用例会被跳过（不会误报失败）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/cast_device_model.dart';
import 'package:perchplay/services/cast_control_service.dart';
import 'package:perchplay/services/local_media_server.dart';

Future<bool> _rendererUp() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final req =
        await client.getUrl(Uri.parse('http://127.0.0.1:8099/description.xml'));
    final res = await req.close();
    await res.drain<void>();
    client.close();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('LocalMediaServer 暴露文件并支持 Range', () async {
    final tmp = File(
        '${Directory.systemTemp.path}/perchplay_ms_test_${DateTime.now().microsecondsSinceEpoch}.bin');
    final payload = List<int>.generate(1000, (i) => i % 256);
    await tmp.writeAsBytes(payload);

    final server = LocalMediaServer.instance;
    final url = await server.urlFor(tmp.path, title: 'clip.bin');
    expect(url, isNotNull, reason: '应能生成投屏 URL');
    expect(url!.startsWith('http://'), isTrue);

    // 换成回环地址访问（本地 IP 在开发机上同样可路由）
    final localUrl =
        'http://127.0.0.1:${server.port}${Uri.parse(url).path}';
    final client = HttpClient();

    // 完整请求
    var res = await (await client.getUrl(Uri.parse(localUrl))).close();
    expect(res.statusCode, 200);
    var bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes.length, 1000);
    expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');

    // Range 请求（拖动进度）
    final req = await client.getUrl(Uri.parse(localUrl));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    res = await req.close();
    expect(res.statusCode, 206, reason: 'Range 必须返回 206');
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
    bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes.length, 10);
    expect(bytes, payload.sublist(10, 20));

    client.close();
    await server.stop();
    await tmp.delete();
  });

  test('DLNA：解析 controlURL 并发送 SetAVTransportURI + Play', () async {
    if (!await _rendererUp()) {
      markTestSkipped('假 DLNA 渲染器未启动，跳过');
      return;
    }

    final logFile = File('${Directory.current.path}/../tools/soap.log');
    // 清掉历史记录（渲染器每次启动也会清）
    if (await logFile.exists()) {
      await logFile.writeAsString('');
    }

    final control = CastControlService.instance;
    final device = CastDevice(
      id: 'test:fake',
      name: 'Fake DLNA TV',
      protocol: CastProtocol.dlna,
      host: '127.0.0.1',
      port: 8099,
      location: 'http://127.0.0.1:8099/description.xml',
      supportsVideo: true,
    );

    final connected = await control.connect(device);
    expect(connected, isTrue,
        reason: '应从描述里解析出 AVTransport controlURL（${control.lastError}）');

    final mediaUrl = 'http://192.168.1.50:41234/video/movie.mp4';
    final ok = await control.playUrl(mediaUrl, title: '测试影片');
    expect(ok, isTrue, reason: 'SetAVTransportURI + Play 应成功（${control.lastError}）');

    await control.disconnect();

    // 校验渲染器实际收到的请求
    expect(await logFile.exists(), isTrue, reason: '渲染器应写入 soap.log');
    final log = await logFile.readAsString();
    expect(log.contains('POST /AVTransport/control'), isTrue,
        reason: '必须 POST 到描述里给出的 controlURL，实际日志：\n$log');
    expect(log.contains('SetAVTransportURI'), isTrue);
    expect(log.contains('Play'), isTrue);
    expect(log.contains(mediaUrl), isTrue,
        reason: 'SOAP 里应带上待投的媒体 URL');
  });
}
