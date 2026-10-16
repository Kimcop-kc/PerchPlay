// NAS 鑷姩鍙戠幇娴嬭瘯
//
// 闇€瑕佷竴涓湰鍦板亣 NAS锛?//   python tools/fake_nas.py     锛?5000 缇ゆ櫀椤甸潰锛?5005 WebDAV锛?// 鏈惎鍔ㄦ椂鐢ㄤ緥鑷姩璺宠繃銆?import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/nas_connection_model.dart';
import 'package:perchplay/services/nas_discovery_service.dart';

Future<bool> _fakeNasUp() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:5000/')))
        .close();
    await res.drain<void>();
    client.close();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('鍙戠幇灞€鍩熺綉 NAS锛氳瘑鍒搧鐗屼笌 WebDAV 鍙敤鎬?, () async {
    if (!await _fakeNasUp()) {
      markTestSkipped('鍋?NAS(:5000/5005) 鏈惎鍔紝璺宠繃');
      return;
    }

    final found = await NasDiscoveryService.instance.discover(
      hosts: const ['127.0.0.1'],
      ports: const [5000, 5005, 22],
      timeout: const Duration(milliseconds: 400),
    );

    // 5000锛氱兢鏅栭〉闈?鈫?搴旇瘑鍒嚭鍝佺墝
    final dsm = found.where((c) => c.port == 5000).toList();
    expect(dsm, isNotEmpty, reason: '绔彛 5000 搴旇鍙戠幇');
    expect(dsm.first.brand, contains('缇ゆ櫀'));

    // 5005锛歅ROPFIND 杩斿洖 207 鈫?鍒ゅ畾涓哄彲鐢?WebDAV
    final dav = found.where((c) => c.port == 5005).toList();
    expect(dav, isNotEmpty, reason: '绔彛 5005 搴旇鍙戠幇');
    expect(dav.first.isWebDav, isTrue, reason: '搴旇瘑鍒负鍙洿鎺ヤ娇鐢ㄧ殑 WebDAV');
    expect(dav.first.protocol, NasProtocol.webdav);

    // 22 鏈洃鍚?鈫?涓嶅簲鍑虹幇鍦ㄧ粨鏋滈噷
    expect(found.any((c) => c.port == 22), isFalse);

    // 缁撴灉鎸夆€滃彲鐩存帴浣跨敤鈥濅紭鍏堟帓搴?    expect(found.first.isWebDav || found.first.port == 5005, isTrue,
        reason: 'WebDAV 搴旀帓鍦ㄥ墠闈?);
  });
}
