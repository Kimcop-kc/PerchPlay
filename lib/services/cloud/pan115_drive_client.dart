import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';

/// 115 网盘客户端。
///
/// ## 认证
/// 纯 Cookie（`UID` + `CID` 为核心）。WebView 登录 `115.com` 后抓取。
///
/// ## 端点（来自 NovaPlayer 反编译）
///  - 列表: `webapi.115.com/files`
///  - 直链: `proapi.115.com/app/chrome/downurl?t=`
class Pan115DriveClient {
  Pan115DriveClient(this.account);

  final CloudDriveAccount account;

  static const String _webApi = 'https://webapi.115.com';
  static const String _proApi = 'https://proapi.115.com';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'Cookie': account.cookie,
        'User-Agent': userAgent,
        'Referer': 'https://115.com/',
        'Accept': 'application/json, text/plain, */*',
      };

  /// 连接测试。用「列根目录第一页」验证 Cookie。
  Future<String?> connect() async {
    try {
      final list = await listDirectory('0');
      if (list == null) return null;
      // 115 的昵称接口
      try {
        final uri = Uri.parse('$_webApi/files?aid=1&cid=0&limit=1&offset=0');
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final j = jsonDecode(body);
          if (j is Map && j['data'] is Map) {
            final nick = (j['data'] as Map)['uname']?.toString();
            if (nick != null && nick.isNotEmpty) return nick;
          }
        }
      } catch (_) {}
      return account.type.displayName;
    } catch (e) {
      debugPrint('[115] 连接失败: $e');
      return null;
    }
  }

  /// 列目录。`cid` 为目录 id，根目录是 `'0'`。
  Future<List<CloudFileItem>?> listDirectory(String cid,
      {String parentPath = '/'}) async {
    try {
      final items = <CloudFileItem>[];
      var offset = 0;
      const limit = 100;

      while (true) {
        final uri = Uri.parse(
          '$_webApi/files?aid=1&cid=$cid&offset=$offset&limit=$limit'
          '&show_dir=1&format=json',
        );
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode != 200) return null;

        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is! Map) return null;
        // 115 用 state=false 表示业务失败（如 Cookie 失效）
        if (j['state'] == false) {
          debugPrint('[115] 业务错误: ${j['error']}');
          return null;
        }
        final data = j['data'];
        if (data is! List || data.isEmpty) break;

        for (final raw in data) {
          if (raw is! Map) continue;
          final name = raw['n']?.toString() ?? '';
          if (name.isEmpty) continue;
          final dir = raw['is_dir'] == 1 || raw['is_dir'] == true;
          items.add(CloudFileItem(
            id: raw['cid']?.toString() ?? raw['fid']?.toString() ?? '',
            name: name,
            path: parentPath == '/' ? '/$name' : '$parentPath/$name',
            isDirectory: dir,
            size: (raw['s'] as num?)?.toInt() ?? 0,
            modified: _parseTime(raw['t']),
            extension: _extOf(name),
          ));
        }

        final count = (j['count'] as num?)?.toInt() ?? data.length;
        if (items.length >= count || data.length < limit) break;
        offset += limit;
        if (offset > 5000) break;
      }
      return items;
    } catch (e) {
      debugPrint('[115] listDirectory 失败: $e');
      return null;
    }
  }

  /// 取直链。
  ///
  /// 115 的流程：用 `pickcode` 换一次性下载地址。
  Future<String?> getDownloadUrl(String pickCode) async {
    try {
      final uri = Uri.parse('$_proApi/app/chrome/downurl?t=${DateTime.now().millisecondsSinceEpoch}');
      final req = await _client.postUrl(uri);
      _headers.forEach(req.headers.set);
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      req.write('data=${Uri.encodeComponent(jsonEncode({'pickcode': pickCode}))}');
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final data = j['data'];
      if (data is Map) {
        // 结构可能是 {code: {url: {url: '...'}}} 或直接 {url: ...}
        for (final v in data.values) {
          if (v is Map) {
            final u = v['url'];
            if (u is String && u.isNotEmpty) return u;
            if (u is Map && u['url'] is String) return u['url'] as String;
          }
        }
      }
    } catch (e) {
      debugPrint('[115] 取直链失败: $e');
    }
    return null;
  }

  static DateTime? _parseTime(Object? v) {
    if (v == null) return null;
    // 115 的 t 是秒级
    final n = int.tryParse(v.toString());
    if (n == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
