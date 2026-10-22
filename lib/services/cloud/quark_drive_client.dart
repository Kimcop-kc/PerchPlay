import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';
import 'cloud_drive_service.dart';

/// 夸克网盘客户端。
///
/// ## 认证
/// 纯 Cookie。WebView 登录 `pan.quark.cn` 后，从 CookieManager 取
/// `__pus`（会话票）等字段，拼成 `k=v; k=v` 串后所有请求带上即可。
///
/// ## 关键端点（来自 NovaPlayer 反编译的 network_endpoints）
///  - 列表: `drive-pc.quark.cn/1/clouddrive/file/sort`
///  - 下载: `drive-pc.quark.cn/1/clouddrive/file/download`
///
/// ## 注意
/// 夸克的下载链接需要 `User-Agent` 与取链接时一致，否则 403。
/// 所以这里统一用一个固定 UA，播放/下载都带它。
class QuarkDriveClient {
  final CloudDriveAccount account;

  static const String _base = 'https://drive-pc.quark.cn/1/clouddrive';

  /// 固定 UA：取直链和实际下载必须一致，否则夸克会拒绝。
  /// 桌面版 UA 与登录 WebView 保持一致，避免移动端限制。
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// 创建时从 CloudDriveService 读取代理设置。
  /// 如需切换代理，需重新连接（断开再打开）以创建新 client。
  QuarkDriveClient(this.account) {
    _client.findProxy = _findProxyFn;
  }

  String Function(Uri) get _findProxyFn {
    final p = CloudDriveService.instance.proxy;
    if (p.isEmpty) return HttpClient.findProxyFromEnvironment;
    return (Uri url) => 'PROXY $p';
  }

  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'Cookie': account.cookie,
        'User-Agent': userAgent,
        'Referer': 'https://pan.quark.cn/',
        'Accept': 'application/json, text/plain, */*',
      };

  /// 连接测试 + 取账号信息。
  ///
  /// 夸克没有独立的「whoami」端点，用「列根目录」来验证 Cookie 是否有效。
  ///
  /// **不要在这里 close HttpClient**：调用方拿到结果后还会继续用同一个
  /// 实例列目录 / 取直链，提前关闭会让后续请求全部报 "Client is closed"。
  /// 生命周期统一由外部 [dispose] 管理。
  Future<String?> connect() async {
    try {
      final list = await listDirectory('0');
      if (list == null) return null;
      // 昵称需要额外接口，失败不影响可用性
      final nick = await _fetchNickname();
      return nick ?? account.type.displayName;
    } catch (e) {
      debugPrint('[Quark] 连接失败: $e');
      return null;
    }
  }

  Future<String?> _fetchNickname() async {
    try {
      final uri =
          Uri.parse('https://pan.quark.cn/account/info?fr=pc&platform=pc');
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is Map && j['data'] is Map) {
        final d = j['data'] as Map;
        return d['nickname']?.toString();
      }
    } catch (_) {}
    return null;
  }

  /// 列出某个目录。`fid` 是夸克的目录 id，根目录固定为 `'0'`。
  ///
  /// 返回 null 表示请求失败（Cookie 失效 / 网络问题）。
  Future<List<CloudFileItem>?> listDirectory(String fid,
      {String parentPath = '/'}) async {
    try {
      final items = <CloudFileItem>[];
      var page = 1;
      const pageSize = 100;

      while (true) {
        final uri = Uri.parse(
          '$_base/file/sort?pr=ucpro&fr=pc&pdir_fid=$fid'
          '&_page=$page&_size=$pageSize&_fetch_total=1&_sort=file_type:asc',
        );
        final req = await _client.getUrl(uri);
        _headers.forEach(req.headers.set);
        final resp = await req.close();

        if (resp.statusCode != 200) {
          debugPrint('[Quark] 列表 HTTP ${resp.statusCode}');
          return null;
        }
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is! Map) return null;

        // 夸克用 code 表达业务错误（0 = 成功）
        final code = j['code'];
        if (code != 0 && code != null) {
          debugPrint('[Quark] 列表业务错误 code=$code msg=${j['message']}');
          return null;
        }

        final data = j['data'];
        if (data is! Map) return items;
        final list = data['list'];
        if (list is! List || list.isEmpty) break;

        for (final raw in list) {
          if (raw is! Map) continue;
          final name = raw['file_name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final dir = raw['dir'] == true;
          items.add(CloudFileItem(
            id: raw['fid']?.toString() ?? '',
            name: name,
            path: parentPath == '/' ? '/$name' : '$parentPath/$name',
            isDirectory: dir,
            size: (raw['size'] as num?)?.toInt() ?? 0,
            modified: _parseTime(raw['updated_at']),
            extension: _extOf(name),
          ));
        }

        // 判断是否还有下一页
        final total = (data['_total'] as num?)?.toInt() ?? items.length;
        if (items.length >= total || list.length < pageSize) break;
        page++;
        if (page > 50) break; // 防御：避免异常时无限翻页
      }
      return items;
    } catch (e) {
      debugPrint('[Quark] listDirectory 失败: $e');
      return null;
    }
  }

  /// 取视频直链。
  ///
  /// 夸克的直链有时效（约几小时），播放前现取即可。
  Future<String?> getDownloadUrl(String fid) async {
    try {
      final uri =
          Uri.parse('$_base/file/download?pr=ucpro&fr=pc&uc_param_str=');
      final req = await _client.postUrl(uri);
      _headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'fids': [fid],
      }));
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final data = j['data'];
      if (data is! List || data.isEmpty) return null;
      final first = data.first;
      if (first is Map) return first['download_url']?.toString();
    } catch (e) {
      debugPrint('[Quark] 取直链失败: $e');
    }
    return null;
  }

  static DateTime? _parseTime(Object? v) {
    if (v == null) return null;
    final n = int.tryParse(v.toString());
    if (n == null) return null;
    // 夸克返回毫秒时间戳
    return DateTime.fromMillisecondsSinceEpoch(n);
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
