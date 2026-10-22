import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';

/// 阿里云盘客户端。
///
/// ## 认证方式（与另外三家不同）
/// 阿里云盘**不用 Cookie**，用 OAuth refresh_token 换 access_token。
/// PerchPlay 反编译揭示了三重认证路径：
///  1. 内置 OAuth 应用 ID（client_id = b8c990e60b18446eb07f5dca30398e8a）
///  2. 用户在 WebView 登录 `alipan.com`，从 localStorage 取出 `refresh_token`
///  3. alist 代理降级（`api.alistgo.com` / `api.nn.ci`，突破官方限速）
///
/// ## 端点
///  - 换 token: `auth.alipan.com/v2/account/token`（内置 client_id）
///  - 列目录:   `openapi.alipan.com/adrive/v1.0/openFile/list`（开放平台）
///               `api.alipan.com/adrive/v3/file/list`（网页版，需 X-Canary）
///  - 直链:     `openapi.alipan.com/adrive/v1.0/openFile/getDownloadUrl`
///               `api.alipan.com/v2/file/get_download_url`（网页版）
///  - alist:    `api.alistgo.com` / `api.nn.ci`（开源代理，无需签名头）
///
/// ## drive_id 探测
/// 阿里云盘的「文件」(file_id) 分为两类：
///  - 备份盘：drive_id = ''（空串），getDriveInfo 返回的 default_drive_id
///  - 资源库：drive_id != ''，共享 / 保险箱等
/// 第一次连接时会探测 drive_id，之后缓存。
class AliyunDriveClient {
  AliyunDriveClient(this.account, {this.clientId, this.clientSecret});

  final CloudDriveAccount account;

  /// 开放平台应用凭据（用户在设置里填；留空则用内置的 PerchPlay 同款 client_id）
  final String? clientId;
  final String? clientSecret;

  /// PerchPlay 代码里的阿里云盘 OAuth client_id。
  /// 内置默认 client_id 常量。
  static const String _builtinClientId = 'b8c990e60b18446eb07f5dca30398e8a';

  static const String _authApi = 'https://auth.alipan.com';
  static const String _webApi = 'https://api.alipan.com';
  static const String _openApi = 'https://openapi.alipan.com';

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// 本次运行内缓存的 access token。
  String _cachedToken = '';

  /// 探测到的 drive_id（空串 = 备份盘，非空 = 资源库）
  String _driveId = '';

  /// 取可用 token：
  ///  1. 内存缓存（检查是否过期）
  ///  2. account.accessToken（WebView 登录时从 localStorage 直接抓的，最可靠）
  ///  3. 用 refresh_token 换（OAuth / Web / 直用）
  Future<String?> _token() async {
    // 检查缓存 token 是否过期（阿里云盘 access_token 有效期约 7200s）
    if (_cachedToken.isNotEmpty && !_isTokenExpired()) {
      return _cachedToken;
    }
    
    // 如果有 accessToken，检查是否过期
    if (account.accessToken.isNotEmpty) {
      _cachedToken = account.accessToken;
      if (!_isTokenExpired()) {
        return _cachedToken;
      }
    }
    
    // token 过期或不存在，用 refresh_token 刷新
    final t = await refreshAccessToken();
    if (t != null && t.isNotEmpty) {
      _cachedToken = t;
      _tokenFetchedAt = DateTime.now();
    }
    return _cachedToken.isEmpty ? null : _cachedToken;
  }

  /// token 获取时间（用于判断过期）
  DateTime? _tokenFetchedAt;

  /// 检查 token 是否已过期（默认 7200 秒 = 2 小时）
  bool _isTokenExpired() {
    if (_tokenFetchedAt == null) {
      // 如果没有记录获取时间，保守认为已过期
      return account.tokenExpireAt?.isBefore(DateTime.now()) ?? true;
    }
    final elapsed = DateTime.now().difference(_tokenFetchedAt!);
    return elapsed.inSeconds > 7000; // 提前 200 秒刷新
  }

  void dispose() => _client.close();

  /// 内置 client_id 优先，用户自填的覆盖。
  String get _effectiveClientId =>
      (clientId != null && clientId!.isNotEmpty) ? clientId! : _builtinClientId;

  /// 用 refresh_token 换 access_token。
  ///
  /// 阿里云盘 WebView 登录拿到的 token 有两类：
  ///  - access_token（直接从 localStorage 取，优先使用，有效期约 7200s）
  ///  - refresh_token（需换 access_token，可能因 client_id 失效）
  ///
  /// 换 token 时先试 Web API（`api.alipan.com`，**不需要** client_id），
  /// 失败再试 OAuth（`auth.alipan.com`，需要 client_id），
  /// 最后把 refresh_token 当成 access_token 直接试。
  Future<String?> refreshAccessToken() async {
    final rt = account.refreshToken;
    if (rt.isEmpty) return null;

    // 如果 refresh_token 很短（< 80 字符），很可能是 web 版 access_token
    if (rt.length < 80) {
      final ok = await _tryToken(rt);
      if (ok) return rt;
    }

    // 方案 1: Web API（api.alipan.com，无需 client_id，成功率最高）
    final tok = await _refreshAtWeb(rt);
    if (tok != null) return tok;

    // 方案 2: OAuth 端点（auth.alipan.com，需要有效 client_id）
    final tok2 = await _refreshAtOAuth(rt);
    if (tok2 != null) return tok2;

    // 方案 3: 直接用 refresh_token 当 access_token
    final ok = await _tryToken(rt);
    if (ok) return rt;

    return null;
  }

  /// 测试 token 是否有效（先用 web API，降级 open API）
  Future<bool> _tryToken(String token) async {
    try {
      // 先试 web API（access_token 不需要 client_id）
      final req = await _client.postUrl(
          Uri.parse('$_webApi/adrive/v3/file/list'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'drive_id': _driveId,
        'parent_file_id': 'root',
        'limit': 1,
        'image_thumbnail_process': 'image/resize,w_160/format,jpeg',
        'video_thumbnail_process': 'video/snapshot,t_0,f_jpg,ar_auto,w_160',
      }));
      final resp = await req.close();
      if (resp.statusCode == 200) return true;
      debugPrint('[Aliyun] _tryToken webApi ${resp.statusCode}');
    } catch (_) {}

    // 降级 open API
    try {
      final req = await _client.postUrl(
          Uri.parse('$_openApi/adrive/v1.0/openFile/list'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'drive_id': _driveId,
        'parent_file_id': 'root',
        'limit': 1,
      }));
      final resp = await req.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// OAuth 端点：auth.alipan.com
  Future<String?> _refreshAtOAuth(String rt) async {
    try {
      final uri = Uri.parse('$_authApi/v2/account/token');
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('User-Agent', userAgent);
      final bodyMap = <String, dynamic>{
        'refresh_token': rt,
        'grant_type': 'refresh_token',
        'client_id': _effectiveClientId,
      };
      if (clientSecret != null && clientSecret!.isNotEmpty) {
        bodyMap['client_secret'] = clientSecret;
      }
      req.write(jsonEncode(bodyMap));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[Aliyun] OAuth token HTTP ${resp.statusCode}');
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final tok = j['access_token']?.toString();
      if (tok != null && tok.isNotEmpty) return tok;
      final tok2 = j['accessToken']?.toString();
      if (tok2 != null && tok2.isNotEmpty) return tok2;
    } catch (e) {
      debugPrint('[Aliyun] OAuth token 失败: $e');
    }
    return null;
  }

  /// Web API 端点：api.alipan.com（不需要 client_id）
  Future<String?> _refreshAtWeb(String rt) async {
    try {
      final uri = Uri.parse('$_webApi/v2/account/token');
      final req = await _client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.headers.set('User-Agent', userAgent);
      req.write(jsonEncode({
        'refresh_token': rt,
        'grant_type': 'refresh_token',
      }));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[Aliyun] Web token HTTP ${resp.statusCode}');
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final tok = j['access_token']?.toString();
      if (tok != null && tok.isNotEmpty) return tok;
      final tok2 = j['accessToken']?.toString();
      if (tok2 != null && tok2.isNotEmpty) return tok2;
    } catch (e) {
      debugPrint('[Aliyun] Web token 失败: $e');
    }
    return null;
  }

  Map<String, String> _authHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'User-Agent': userAgent,
        'Referer': 'https://www.alipan.com/',
        'Accept': 'application/json, text/plain, */*',
        'X-Canary': 'client=web,app=adrive,version=v4.5.0',
      };

  /// 连接测试 + 昵称 + drive_id 探测。
  ///
  /// **不要在这里 close HttpClient**：调用方拿到结果后还会继续用同一个
  /// 实例列目录 / 取直链。提前关闭会让后续请求全部报 "Client is closed"。
  Future<String?> connect() async {
    try {
      final token = await _token();
      if (token == null || token.isEmpty) return null;

      // 先探测 drive_id（备份盘 vs 资源库）
      _driveId = await _probeDriveId(token);
      debugPrint('[Aliyun] connect driveId=$_driveId token=${token.substring(0, min(token.length, 20))}...');

      // 用「列根目录」验证连接
      final list = await listDirectory('root');
      if (list == null) {
        debugPrint('[Aliyun] 列根目录失败，连接失败');
        return null;
      }

      // 取昵称（web API 优先）
      try {
        // 方案 1: web API
        final r1 = await _client.postUrl(
            Uri.parse('$_webApi/v1.0/user/getDriveInfo'));
        _authHeaders(token).forEach(r1.headers.set);
        r1.headers.contentType = ContentType.json;
        r1.write(jsonEncode({}));
        final resp1 = await r1.close();
        if (resp1.statusCode == 200) {
          final body = await resp1.transform(utf8.decoder).join();
          final j = jsonDecode(body);
          if (j is Map) {
            final n = j['name']?.toString() ??
                j['nick_name']?.toString() ??
                j['user_name']?.toString();
            if (n != null && n.isNotEmpty) return n;
          }
        }
      } catch (_) {}
      // 方案 2: open API
      try {
        final req = await _client.getUrl(
            Uri.parse('$_openApi/adrive/v1.0/user/getDriveInfo'));
        _authHeaders(token).forEach(req.headers.set);
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final j = jsonDecode(body);
          if (j is Map) {
            final n = j['name']?.toString() ??
                j['nick_name']?.toString() ??
                j['default_drive_id']?.toString();
            if (n != null && n.isNotEmpty) return n;
          }
        }
      } catch (_) {}
      return account.type.displayName;
    } catch (e) {
      debugPrint('[Aliyun] 连接失败: $e');
      return null;
    }
  }

  /// 探测可用的 drive_id。
  ///
  /// 先用 web API（`api.alipan.com`，access_token 就行），
  /// 失败再降级 open API（`openapi.alipan.com`，需要 OAuth client）。
  Future<String> _probeDriveId(String token) async {
    // 方案 1: web API
    try {
      final req = await _client.postUrl(
          Uri.parse('$_webApi/adrive/v1.0/user/getDriveInfo'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({}));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is Map) {
          final did = j['default_drive_id']?.toString() ?? '';
          debugPrint('[Aliyun] web drive_id=$did');
          return did;
        }
      }
    } catch (_) {}

    // 方案 2: open API
    try {
      final req = await _client.getUrl(
          Uri.parse('$_openApi/adrive/v1.0/user/getDriveInfo'));
      _authHeaders(token).forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is Map) {
          final did = j['default_drive_id']?.toString() ?? '';
          debugPrint('[Aliyun] open drive_id=$did');
          return did;
        }
      }
    } catch (_) {}

    // 方案 3: listDrives
    try {
      final req = await _client.postUrl(
          Uri.parse('$_openApi/adrive/v1.0/user/listDrives'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({}));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is Map) {
          final items = j['items'];
          if (items is List && items.isNotEmpty) {
            for (final item in items) {
              if (item is Map) {
                final did = item['drive_id']?.toString() ?? '';
                if (did.isNotEmpty) {
                  debugPrint('[Aliyun] listDrives drive_id=$did');
                  return did;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return '';
  }

  /// 列目录。`parentId` 根目录是 `'root'`。
  ///
  /// 先试 web API（`api.alipan.com`，access_token 即可），
  /// 失败降级 open API（`openapi.alipan.com`，需 OAuth client_id）。
  Future<List<CloudFileItem>?> listDirectory(String parentId,
      {String parentPath = '/'}) async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;

    // 先试 web API
    final webItems = await _listDirWeb(token, parentId, parentPath);
    if (webItems != null) return webItems;

    // 降级 open API
    final openItems = await _listDirOpen(token, parentId, parentPath);
    if (openItems != null) return openItems;

    return null;
  }

  // ──────────── web API 列表 ────────────

  Future<List<CloudFileItem>?> _listDirWeb(
      String token, String parentId, String parentPath) async {
    try {
      final items = <CloudFileItem>[];
      var marker = '';
      const limit = 100;

      while (true) {
        final req = await _client.postUrl(
            Uri.parse('$_webApi/adrive/v3/file/list'));
        _authHeaders(token).forEach(req.headers.set);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'drive_id': _driveId,
          'parent_file_id': parentId,
          'limit': limit,
          'marker': marker,
          'order_by': 'name',
          'order_direction': 'ASC',
          'image_thumbnail_process': 'image/resize,w_160/format,jpeg',
          'video_thumbnail_process': 'video/snapshot,t_0,f_jpg,ar_auto,w_160',
        }));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          debugPrint('[Aliyun] web list HTTP ${resp.statusCode}');
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
            modified: DateTime.tryParse(raw['updated_at']?.toString() ?? ''),
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
      debugPrint('[Aliyun] web list 失败: $e');
      return null;
    }
  }

  // ──────────── 开放平台列表 ────────────

  Future<List<CloudFileItem>?> _listDirOpen(
      String token, String parentId, String parentPath) async {
    try {
      final items = <CloudFileItem>[];
      var marker = '';
      const limit = 100;

      while (true) {
        final req = await _client.postUrl(
            Uri.parse('$_openApi/adrive/v1.0/openFile/list'));
        _authHeaders(token).forEach(req.headers.set);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'drive_id': _driveId,
          'parent_file_id': parentId,
          'limit': limit,
          'marker': marker,
          'order_by': 'name',
          'order_direction': 'ASC',
        }));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          debugPrint('[Aliyun] open list HTTP ${resp.statusCode}');
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
            modified: DateTime.tryParse(raw['updated_at']?.toString() ?? ''),
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
      debugPrint('[Aliyun] open list 失败: $e');
      return null;
    }
  }

  /// 取直链（web API 优先，开放平台降级）。
  Future<String?> getDownloadUrl(String fileId) async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;

    // 先试 web API
    try {
      final req = await _client.postUrl(
          Uri.parse('$_webApi/v2/file/get_download_url'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'drive_id': _driveId, 'file_id': fileId}));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is Map) {
          final url = j['url']?.toString() ?? j['download_url']?.toString();
          if (url != null && url.isNotEmpty) return url;
        }
      }
    } catch (e) {
      debugPrint('[Aliyun] web 取直链失败: $e');
    }

    // 降级开放平台
    try {
      final req = await _client.postUrl(
          Uri.parse('$_openApi/adrive/v1.0/openFile/getDownloadUrl'));
      _authHeaders(token).forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'drive_id': _driveId, 'file_id': fileId}));
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        if (j is Map) {
          final url = j['url']?.toString() ?? j['download_url']?.toString();
          if (url != null && url.isNotEmpty) return url;
        }
      }
    } catch (e) {
      debugPrint('[Aliyun] open 取直链失败: $e');
    }
    return null;
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
