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
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'Cookie': account.cookie,
        'User-Agent': userAgent,
        'Referer': 'https://pan.baidu.com/disk/main',
        'Accept': 'application/json, text/plain, */*',
      };

  /// 从 cookie 串里取某个字段的值（如 `bdstoken`）。
  ///
  /// 百度的网页接口（`/api/list`）除了 BDUSS 之外，通常还要求
  /// `bdstoken` 参数或 cookie —— 它是 CSRF token，登录后随 cookie 下发。
  /// 缺了它即便 BDUSS 有效也可能返回 errno=-6。
  String _cookieValue(String name) {
    for (final part in account.cookie.split(';')) {
      final t = part.trim();
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      if (t.substring(0, eq) == name) return t.substring(eq + 1);
    }
    return '';
  }

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

  /// 列表接口返回的最近一次业务错误码（供上层给出准确提示）。
  ///
  /// 百度用 `errno` 区分原因，常见值：
  ///  - `0`     成功
  ///  - `-6`    未登录（BDUSS / STOKEN 缺失或失效）
  ///  - `-7`    文件或目录不存在
  ///  - `-9`    路径不存在
  ///  - `31066` 需要实名 / 账号受限
  ///  - `2`     参数错误
  ///
  /// 之前所有错误都被折叠成「登录可能已过期」，用户被误导着反复重新登录，
  /// 而真实原因可能是路径不存在。
  int? lastErrno;
  String lastErrmsg = '';

  /// 列目录。`dir` 是从 `/` 开始的绝对路径。
  Future<List<CloudFileItem>?> listDirectory(String dir,
      {String parentPath = '/'}) async {
    lastErrno = null;
    lastErrmsg = '';
    try {
      final items = <CloudFileItem>[];
      var page = 1;
      const pageSize = 100;

      while (true) {
        // bdstoken 是百度的 CSRF token，登录后随 cookie 下发。
        // 网页 API 对它校验较严，带上能显著降低 errno=-6 的概率。
        final bdstoken = _cookieValue('bdstoken');
        final uri = Uri.parse(
          '$_api/list?dir=${Uri.encodeComponent(dir)}&num=$pageSize&page=$page'
          '&order=name&clienttype=0&app_id=$_appId&web=1&channel=chunlei'
          '${bdstoken.isEmpty ? '' : '&bdstoken=$bdstoken'}',
        );
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode != 200) {
          debugPrint('[Baidu] list HTTP ${resp.statusCode}');
          lastErrno = resp.statusCode;
          lastErrmsg = 'HTTP ${resp.statusCode}';
          return null;
        }

        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is! Map) return null;
        // 百度用 errno 表达业务错误（0 = 成功，-6 = 未登录）
        final errno = j['errno'];
        if (errno != 0 && errno != null) {
          lastErrno = (errno as num?)?.toInt();
          lastErrmsg = j['errmsg']?.toString() ??
              j['show_msg']?.toString() ??
              '';
          debugPrint('[Baidu] 列表业务错误 errno=$errno msg=$lastErrmsg dir=$dir');
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
  /// 百度有两条路：
  ///  - `xpan/multimedia?method=filemetas`：需要 **access_token**（OAuth），
  ///    原代码传的是 `access_token=`（空），所以这条必然失败。
  ///  - `api/filemetas`：**只认 Cookie**，适合我们这种 WebView 抓 cookie 的场景。
  ///
  /// 这里先走 Cookie 通道，失败再试 xpan（万一账号里带了 token）。
  Future<String?> getDownloadUrl(String fsId) async {
    // 通道 1：Cookie 认证的老版接口
    final viaCookie = await _downloadUrlByCookie(fsId);
    if (viaCookie != null) return viaCookie;

    // 通道 2：xpan（只有持 access_token 时可用；这里仍试一次以兼容）
    return _downloadUrlByXpan(fsId);
  }

  /// `GET /api/filemetas?dlink=1&fsids=[id]`（Cookie 认证）
  Future<String?> _downloadUrlByCookie(String fsId) async {
    try {
      final bdstoken = _cookieValue('bdstoken');
      final uri = Uri.parse(
        '$_api/filemetas?dlink=1&fsids=%5B$fsId%5D'
        '&clienttype=0&app_id=$_appId&web=1&channel=chunlei'
        '${bdstoken.isEmpty ? '' : '&bdstoken=$bdstoken'}',
      );
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[Baidu] filemetas HTTP ${resp.statusCode}');
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final errno = j['errno'];
      if (errno != 0 && errno != null) {
        lastErrno = (errno as num?)?.toInt();
        lastErrmsg = j['errmsg']?.toString() ?? '';
        debugPrint('[Baidu] filemetas errno=$errno msg=$lastErrmsg');
        return null;
      }
      return _pickDlink(j['info'] ?? j['list']);
    } catch (e) {
      debugPrint('[Baidu] filemetas 失败: $e');
    }
    return null;
  }

  /// `GET /rest/2.0/xpan/multimedia?method=filemetas&access_token=...&dlink=1`
  Future<String?> _downloadUrlByXpan(String fsId) async {
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
      final errno = j['errno'];
      if (errno != 0 && errno != null) {
        debugPrint('[Baidu] xpan filemetas errno=$errno');
        return null;
      }
      return _pickDlink(j['list']);
    } catch (e) {
      debugPrint('[Baidu] xpan 取直链失败: $e');
    }
    return null;
  }

  /// 从返回结构里取 dlink 并规整。
  ///
  /// 百度 dlink 的两个坑：
  ///  1. 以 `http://` 开头，必须换成 `https://`
  ///  2. 自带 `&access_token=xxx` 占位，播放时必须**带同样的 Cookie + UA**
  String? _pickDlink(Object? container) {
    Map? first;
    if (container is List && container.isNotEmpty) {
      final f = container.first;
      if (f is Map) first = f;
    } else if (container is Map) {
      first = container;
    }
    if (first == null) return null;
    final dlink = first['dlink']?.toString();
    if (dlink == null || dlink.isEmpty) {
      debugPrint('[Baidu] 返回里没有 dlink');
      return null;
    }
    return dlink.replaceFirst('http://', 'https://');
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
