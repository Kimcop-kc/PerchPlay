import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';

/// 百度网盘客户端。
///
/// ## 认证
/// 纯 Cookie（`BDUSS` + `STOKEN` 为核心）。WebView 登录 `pan.baidu.com` 后抓取。
///
/// ## 端点（来自 NovaPlayer 反编译）
///  - 列表: `pan.baidu.com/api/list?dir=...&num=...`
///  - 目录操作: `pan.baidu.com/api/filemanager`
///
/// ## 已知限制
/// 百度网盘的直链需要 VIP 才能高速下载，普通账号会被限速到几十 KB/s。
/// 这里只负责「能列出、能取到链接」，速度取决于用户账号。
class BaiduDriveClient {
  BaiduDriveClient(this.account);

  final CloudDriveAccount account;

  static const String _api = 'https://pan.baidu.com/api';
  static const String _appId = '250528';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'Cookie': account.cookie,
        'User-Agent': userAgent,
        'Referer': 'https://pan.baidu.com/disk/main',
        'Accept': 'application/json, text/plain, */*',
      };

  /// 连接测试 + 昵称。
  Future<String?> connect() async {
    try {
      final list = await listDirectory('/');
      if (list == null) return null;
      // 取昵称
      try {
        final uri =
            Uri.parse('https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo');
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final j = jsonDecode(body);
          if (j is Map) {
            final n = j['netname']?.toString();
            if (n != null && n.isNotEmpty) return n;
          }
        }
      } catch (_) {}
      return account.type.displayName;
    } catch (e) {
      debugPrint('[Baidu] 连接失败: $e');
      return null;
    }
  }

  /// 列目录。`dir` 是从 `/` 开始的绝对路径。
  Future<List<CloudFileItem>?> listDirectory(String dir,
      {String parentPath = '/'}) async {
    try {
      final items = <CloudFileItem>[];
      var page = 1;
      const pageSize = 100;

      while (true) {
        final uri = Uri.parse(
          '$_api/list?dir=${Uri.encodeComponent(dir)}&num=$pageSize&page=$page'
          '&order=name&clienttype=0&app_id=$_appId&web=1',
        );
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode != 200) return null;

        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is! Map) return null;
        // 百度用 errno 表达业务错误（0 = 成功，-6 = 未登录）
        final errno = j['errno'];
        if (errno != 0 && errno != null) {
          debugPrint('[Baidu] 业务错误 errno=$errno');
          return null;
        }
        final list = j['list'];
        if (list is! List || list.isEmpty) break;

        for (final raw in list) {
          if (raw is! Map) continue;
          final name = raw['server_filename']?.toString() ?? '';
          if (name.isEmpty) continue;
          final isDir = raw['isdir'] == 1 || raw['isdir'] == true;
          final childPath = parentPath == '/' ? '/$name' : '$parentPath/$name';
          items.add(CloudFileItem(
            id: raw['fs_id']?.toString() ?? '',
            name: name,
            path: childPath,
            isDirectory: isDir,
            size: (raw['size'] as num?)?.toInt() ?? 0,
            modified: _parseTime(raw['server_mtime']),
            extension: _extOf(name),
          ));
        }

        if (list.length < pageSize) break;
        page++;
        if (page > 50) break;
      }
      return items;
    } catch (e) {
      debugPrint('[Baidu] listDirectory 失败: $e');
      return null;
    }
  }

  /// 取下载直链。
  ///
  /// 百度要求先用 `fs_id` 换 `dlink`（`dlink` 带鉴权参数），
  /// 且实际下载必须带同样的 Cookie + UA。
  Future<String?> getDownloadUrl(String fsId) async {
    try {
      final uri = Uri.parse(
          'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas'
          '&access_token=&dlink=1&fsids=[$fsId]');
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final list = j['list'];
      if (list is List && list.isNotEmpty) {
        final first = list.first;
        if (first is Map) {
          final dlink = first['dlink']?.toString();
          if (dlink != null && dlink.isNotEmpty) {
            // 百度的 dlink 是 http，需要替换为 https 并带上 access_token 占位
            return dlink.replaceFirst('http://', 'https://');
          }
        }
      }
    } catch (e) {
      debugPrint('[Baidu] 取直链失败: $e');
    }
    return null;
  }

  static DateTime? _parseTime(Object? v) {
    if (v == null) return null;
    final n = int.tryParse(v.toString());
    if (n == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
