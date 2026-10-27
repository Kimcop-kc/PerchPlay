import 'package:flutter_test/flutter_test.dart';

/// WebDAV multistatus 解析的回归测试。
///
/// 背景：线上 v1.1.3 的解析正则硬编码了 `<D:xxx>` 前缀，导致返回
/// 小写 `d:` 或无前缀的 WebDAV 服务器（群晖等）里：
///   - isDirectory 恒为 false → 目录点不开
///   - 日志表现为 `dir=false video=false`
///
/// 这些用例覆盖常见的命名空间写法，锁住「任意前缀都能解析」。
void main() {
  // 与 nas_client_service.dart 中 _parseWebDavMultiStatus 保持一致的写法
  const ns = r'(?:[A-Za-z0-9_.-]+:)?';

  bool isDirOf(String resp) => RegExp(
        '<${ns}collection\\b[^>]*(?:/>|>\\s*</${ns}collection>)',
        dotAll: true,
        caseSensitive: false,
      ).hasMatch(resp);

  String? hrefOf(String resp) => RegExp(
        '<${ns}href\\b[^>]*>(.*?)</${ns}href>',
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(resp)?.group(1);

  group('collection 识别（目录判定）', () {
    test('大写 D 前缀 + 自闭合', () {
      expect(isDirOf('<D:resourcetype><D:collection/></D:resourcetype>'), isTrue);
    });

    test('小写 d 前缀（群晖常见）', () {
      expect(isDirOf('<d:resourcetype><d:collection/></d:resourcetype>'), isTrue);
    });

    test('无前缀', () {
      expect(isDirOf('<resourcetype><collection/></resourcetype>'), isTrue);
    });

    test('非自闭合写法', () {
      expect(
        isDirOf('<D:resourcetype><D:collection></D:collection></D:resourcetype>'),
        isTrue,
      );
    });

    test('ns0 前缀', () {
      expect(isDirOf('<ns0:resourcetype><ns0:collection/></ns0:resourcetype>'), isTrue);
    });

    test('普通文件不误判为目录', () {
      expect(isDirOf('<D:resourcetype/>'), isFalse);
    });
  });

  group('href 提取', () {
    test('大写 D 前缀', () {
      expect(hrefOf('<D:href>/dav/Obsidian/</D:href>'), '/dav/Obsidian/');
    });

    test('小写 d 前缀', () {
      expect(hrefOf('<d:href>/dav/Obsidian/</d:href>'), '/dav/Obsidian/');
    });

    test('无前缀', () {
      expect(hrefOf('<href>/dav/Obsidian/</href>'), '/dav/Obsidian/');
    });

    test('带属性也不影响', () {
      expect(
        hrefOf('<D:href xml:lang="en">/a/b/</D:href>'),
        '/a/b/',
      );
    });
  });

  group('完整 response 块', () {
    const nsFull = r'(?:[A-Za-z0-9_.-]+:)?';
    final respPattern = RegExp(
      '<${nsFull}response\\b[^>]*>.*?</${nsFull}response>',
      dotAll: true,
      caseSensitive: false,
    );

    test('小写 d 前缀的完整块能匹配', () {
      const xml = '''
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/Obsidian/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>''';
      final matches = respPattern.allMatches(xml).toList();
      expect(matches.length, 1);
      expect(isDirOf(matches.first.group(0)!), isTrue);
      expect(hrefOf(matches.first.group(0)!), '/dav/Obsidian/');
    });

    test('无前缀的完整块能匹配', () {
      const xml = '''
<multistatus xmlns="DAV:">
  <response>
    <href>/dav/Movies/</href>
    <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat>
  </response>
</multistatus>''';
      final matches = respPattern.allMatches(xml).toList();
      expect(matches.length, 1);
      expect(isDirOf(matches.first.group(0)!), isTrue);
    });
  });
}
