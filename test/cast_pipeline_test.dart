// 鎶曞睆閾捐矾鐨勭湡瀹炴祴璇曪紙鍦ㄥ紑鍙戞満涓婅窇锛屼笉渚濊禆鎵嬫満锛夛細
// 1) LocalMediaServer 蹇呴』鏀寔 Range 璇锋眰锛堢數瑙嗘嫋杩涘害鏉¤鐢級
// 2) DLNA 杩炴帴蹇呴』浠庤澶囨弿杩伴噷瑙ｆ瀽鍑虹湡瀹炵殑 controlURL锛屽苟鎶?//    SetAVTransportURI / Play 鍙戝埌閭ｄ釜鍦板潃
//
// 娴嬭瘯 2 闇€瑕佷竴涓湰鍦板亣娓叉煋鍣細
//   python tools/fake_dlna_renderer.py 8099
// 鏈惎鍔ㄦ椂璇ョ敤渚嬩細琚烦杩囷紙涓嶄細璇姤澶辫触锛夈€?import 'dart:io';

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
  test('LocalMediaServer 鏆撮湶鏂囦欢骞舵敮鎸?Range', () async {
    final tmp = File(
        '${Directory.systemTemp.path}/perchplay_ms_test_${DateTime.now().microsecondsSinceEpoch}.bin');
    final payload = List<int>.generate(1000, (i) => i % 256);
    await tmp.writeAsBytes(payload);

    final server = LocalMediaServer.instance;
    final url = await server.urlFor(tmp.path, title: 'clip.bin');
    expect(url, isNotNull, reason: '搴旇兘鐢熸垚鎶曞睆 URL');
    expect(url!.startsWith('http://'), isTrue);

    // 鎹㈡垚鍥炵幆鍦板潃璁块棶锛堟湰鍦?IP 鍦ㄥ紑鍙戞満涓婂悓鏍峰彲璺敱锛?    final localUrl =
        'http://127.0.0.1:${server.port}${Uri.parse(url).path}';
    final client = HttpClient();

    // 瀹屾暣璇锋眰
    var res = await (await client.getUrl(Uri.parse(localUrl))).close();
    expect(res.statusCode, 200);
    var bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes.length, 1000);
    expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');

    // Range 璇锋眰锛堟嫋鍔ㄨ繘搴︼級
    final req = await client.getUrl(Uri.parse(localUrl));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    res = await req.close();
    expect(res.statusCode, 206, reason: 'Range 蹇呴』杩斿洖 206');
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
    bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes.length, 10);
    expect(bytes, payload.sublist(10, 20));

    client.close();
    await server.stop();
    await tmp.delete();
  });

  test('DLNA锛氳В鏋?controlURL 骞跺彂閫?SetAVTransportURI + Play', () async {
    if (!await _rendererUp()) {
      markTestSkipped('鍋?DLNA 娓叉煋鍣ㄦ湭鍚姩锛岃烦杩?);
      return;
    }

    final logFile = File('${Directory.current.path}/../tools/soap.log');
    // 娓呮帀鍘嗗彶璁板綍锛堟覆鏌撳櫒姣忔鍚姩涔熶細娓咃級
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
        reason: '搴斾粠鎻忚堪閲岃В鏋愬嚭 AVTransport controlURL锛?{control.lastError}锛?);

    final mediaUrl = 'http://192.168.1.50:41234/video/movie.mp4';
    final ok = await control.playUrl(mediaUrl, title: '娴嬭瘯褰辩墖');
    expect(ok, isTrue, reason: 'SetAVTransportURI + Play 搴旀垚鍔燂紙${control.lastError}锛?);

    await control.disconnect();

    // 鏍￠獙娓叉煋鍣ㄥ疄闄呮敹鍒扮殑璇锋眰
    expect(await logFile.exists(), isTrue, reason: '娓叉煋鍣ㄥ簲鍐欏叆 soap.log');
    final log = await logFile.readAsString();
    expect(log.contains('POST /AVTransport/control'), isTrue,
        reason: '蹇呴』 POST 鍒版弿杩伴噷缁欏嚭鐨?controlURL锛屽疄闄呮棩蹇楋細\n$log');
    expect(log.contains('SetAVTransportURI'), isTrue);
    expect(log.contains('Play'), isTrue);
    expect(log.contains(mediaUrl), isTrue,
        reason: 'SOAP 閲屽簲甯︿笂寰呮姇鐨勫獟浣?URL');
  });
}
