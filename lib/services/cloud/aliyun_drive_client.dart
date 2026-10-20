import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';

/// 阿里云盘客户端。
///
/// ## 认证方式（与另外三家不同）
/// 阿里云盘**不用 Cookie**，用 OAuth refresh_token 换 access_token。
/// 本项目采用 NovaPlayer 同样的思路：
///  1. 用户在 WebView 登录 `alipan.com`；
///  2. 从网页 localStorage 里取出 `refresh_token`；
///  3. 用 refresh_token 调 `auth.alipan.com/v2/account/token` 换 access_token。
///
/// 也支持用户直接粘贴 refresh_token（WebView 提取失败时的兜底）。
///
/// ## 端点
///  - 换 token: `auth.alipan.com/v2/account/token`
///  - 列目录:   `api.alipan.com/adrive/v3/file/list`（网页版）
///              或 `openapi.alipan.com/adrive/v1.0/openFile/list`（开放平台）
///  - 直链:     `api.alipan.com/v2/file/get_download_url`
///
/// ## 重要限制
/// 网页版 API 需要 `X-Canary` 之类的签名头，且随时可能变化。这里用
/// 开放平台的 `openapi.alipan.com` 路径（需要用户自备 client_id/secret），
/// 如果用户没配，就退回网页版（可能失效）。
class AliyunDriveClient {
  AliyunDriveClient(this.account, {this.clientId, this.clientSecret});

  final CloudDriveAccount account;

  /// 开放平台应用凭据（用户在设置里填；留空则用网页版接口）
  final String? clientId;
  final String? clientSecret;

  static const String _authApi = 'https://auth.alipan.com';
  static const String _webApi = 'https://api.alipan.com';
  static const String _openApi = 'https://openapi.alipan.com';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// 本次运行内缓存的 access token。
  ///
  /// [account] 是不可变对象，刷新出来的新 token 写不回去；如果不在这里缓存，
  /// 每列一次目录都要重新走一遍 refresh（多一次网络往返，还容易被限流）。
  String _cachedToken = '';

  /// 取可用 token：缓存 → account 里的 → 刷新。
  Future<String?> _token() async {
    if (_cachedToken.isNotEmpty) return _cachedToken;
    if (account.accessToken.isNotEmpty) {
      _cachedToken = account.accessToken;
      return _cachedToken;
    }
    final t = await refreshAccessToken();
    if (t != null && t.isNotEmpty) _cachedToken = t;
    return _cachedToken.isEmpty ? null : _cachedToken;
  }

  void dispose() => _client.close();

  bool get _useOpenApi =>
      (clientId?.isNotEmpty ?? false) && (clientSecret?.isNotEmpty ?? false);

  /// 用 refresh_token 换 access_token，返回新的 access token。
  Future<String?> refreshAccessToken() async {
    final rt = account.refreshToken;
    if (rt.isEmpty) return null;
    try {
      final uri = Uri.parse('$_authApi/v2/account/token');
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('User-Agent', userAgent);
      req.write(jsonEncode({'refresh_token': rt, 'grant_type': 'refresh_token'}));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[Aliyun] 换 token HTTP ${resp.statusCode}');
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final tok = j['access_token']?.toString();
      if (tok != null && tok.isNotEmpty) return tok;
      // 开放平台格式：{ access_token, refresh_token, expires_in }
      final tok2 = j['accessToken']?.toString();
      if (tok2 != null && tok2.isNotEmpty) return tok2;
    } catch (e) {
      debugPrint('[Aliyun] 换 token 失败: $e');
    }
    return null;
  }

  Map<String, String> _authHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'User-Agent': userAgent,
        'Referer': 'https://www.alipan.com/',
        'Accept': 'application/json, text/plain, */*',
        // 网页版 API 要求的标记头（缺失会被拒绝）
        'X-Canary': 'client=web,app=adrive,version=v4.5.0',
      };

  /// 连接测试 + 昵称。
  Future<String?> connect() async {
    try {
      final token = await _token();
      if (token == null || token.isEmpty) return null;

      // 用「列根目录」验证
      final list = await listDirectory('root');
      if (list == null) return null;

      // 取昵称
      try {
        final base = _useOpenApi ? _openApi : _webApi;
        final path = _useOpenApi
            ? '/adrive/v1.0/user/getDriveInfo'
            : '/v2/user/get';
        final req = await _client.getUrl(Uri.parse('$base$path'));
        _authHeaders(token).forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final j = jsonDecode(body);
          if (j is Map) {
            final n = j['name']?.toString() ?? j['nick_name']?.toString();
            if (n != null && n.isNotEmpty) return n;
          }
        }
      } catch (_) {}
      return account.type.displayName;
    } catch (e) {
      debugPrint('[Aliyun] 连接失败: $e');
      return null;
    } finally {
      _client.close();
    }
  }

  /// 列目录。`parentId` 根目录是 `'root'`。
  Future<List<CloudFileItem>?> listDirectory(String parentId,
      {String parentPath = '/'}) async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;

    try {
      final items = <CloudFileItem>[];
      var marker = '';
      const limit = 100;

      while (true) {
        final base = _useOpenApi ? _openApi : _webApi;
        final path =
            _useOpenApi ? '/adrive/v1.0/openFile/list' : '/adrive/v3/file/list';
        final uri = Uri.parse('$base$path');
        final req = await _client.postUrl(uri);
        _authHeaders(token).forEach(req.headers.set);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'drive_id': '',
          'parent_file_id': parentId,
          'limit': limit,
          'marker': marker,
          'order_by': 'name',
          'order_direction': 'ASC',
        }));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          debugPrint('[Aliyun] 列表 HTTP ${resp.statusCode}');
          return null;
        }
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is! Map) return null;
        final list = j['items'];
        if (list is! List || list.isEmpty) break;

        for (final raw in list) {
          if (raw is! Map) continue;
          final name = raw['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          final dir = raw['type']?.toString() == 'folder';
          items.add(CloudFileItem(
            id: raw['file_id']?.toString() ?? '',
            name: name,
            path: parentPath == '/' ? '/$name' : '$parentPath/$name',
            isDirectory: dir,
            size: (raw['size'] as num?)?.toInt() ?? 0,
            modified: DateTime.tryParse(
                raw['updated_at']?.toString() ?? ''),
            extension: _extOf(name),
          ));
        }

        final next = j['next_marker']?.toString() ?? '';
        if (next.isEmpty) break;
        marker = next;
        if (items.length > 5000) break;
      }
      return items;
    } catch (e) {
      debugPrint('[Aliyun] listDirectory 失败: $e');
      return null;
    }
  }

  /// 取直链。
  Future<String?> getDownloadUrl(String fileId) async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;

    try {
      final base = _useOpenApi ? _openApi : _webApi;
      final path = _useOpenApi
          ? '/adrive/v1.0/openFile/getDownloadUrl'
          : '/v2/file/get_download_url';
      final req = await _client.postUrl(Uri.parse('$base$path'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'drive_id': '', 'file_id': fileId}));
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is Map) {
        return j['url']?.toString() ?? j['download_url']?.toString();
      }
    } catch (e) {
      debugPrint('[Aliyun] 取直链失败: $e');
    }
    return null;
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
