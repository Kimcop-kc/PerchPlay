// NAS 自动发现测试
//
// 需要一个本地假 NAS：
//   python tools/fake_nas.py     （:5000 群晖页面，:5005 WebDAV）
// 未启动时用例自动跳过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/models/nas_connection_model.dart';
import 'package:vidflow/services/nas_discovery_service.dart';

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
  test('发现局域网 NAS：识别品牌与 WebDAV 可用性', () async {
    if (!await _fakeNasUp()) {
      markTestSkipped('假 NAS(:5000/5005) 未启动，跳过');
      return;
    }

    final found = await NasDiscoveryService.instance.discover(
      hosts: const ['127.0.0.1'],
      ports: const [5000, 5005, 22],
      timeout: const Duration(milliseconds: 400),
    );

    // 5000：群晖页面 → 应识别出品牌
    final dsm = found.where((c) => c.port == 5000).toList();
    expect(dsm, isNotEmpty, reason: '端口 5000 应被发现');
    expect(dsm.first.brand, contains('群晖'));

    // 5005：PROPFIND 返回 207 → 判定为可用 WebDAV
    final dav = found.where((c) => c.port == 5005).toList();
    expect(dav, isNotEmpty, reason: '端口 5005 应被发现');
    expect(dav.first.isWebDav, isTrue, reason: '应识别为可直接使用的 WebDAV');
    expect(dav.first.protocol, NasProtocol.webdav);

    // 22 未监听 → 不应出现在结果里
    expect(found.any((c) => c.port == 22), isFalse);

    // 结果按“可直接使用”优先排序
    expect(found.first.isWebDav || found.first.port == 5005, isTrue,
        reason: 'WebDAV 应排在前面');
  });
}
