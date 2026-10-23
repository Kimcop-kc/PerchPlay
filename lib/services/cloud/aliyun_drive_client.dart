import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';

/// 阿里云盘客户端。
///
/// ## 认证方式（与另外三家不同）
/// 阿里云盘**不用 Cookie**，用 OAuth refresh_token 换 access_token。
/// 三重认证路径：
///  1. 内置 OAuth 应用 ID（client_id = b8c990e60b18446eb07f5dca30398e8a）
///  2. 用户在 WebView 登录 `alipan.com`，从 localStorage 取出 `refresh_token`
///  3. 直用 refresh_token 试探降级
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

  /// 开放平台应用凭据（用户在设置里填；留空则用内置的 内置 client_id）
  final String? clientId;
  final String? clientSecret;

  /// PerchPlay 代码里的阿里云盘 OAuth client_id（内置默认常量）。
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

  /// 取可用 token。
  ///
  /// 顺序（每一步都**实际验证**，不靠本地时间猜过期）：
  ///  1. 内存缓存的 access_token（换过就直接用）
  ///  2. account.accessToken（WebView 登录时从 localStorage 抓的）
  ///  3. 用 refresh_token 刷新
  ///
  /// 之前的问题：`_isTokenExpired()` 在 `tokenExpireAt == null` 时返回 true
  /// （保守假设已过期），于是「刚抓到的 access_token」会被当成过期，
  /// 转头去走 refresh_token；而后者的 client_id 往往无效 → 整体失败。
  /// 现在改成：本地没记录过期时间就**先试一次真实请求**，401 才刷新。
  Future<String?> _token() async {
    // 1) 内存缓存：只有明确记录了获取时间且未超时才直接用
    if (_cachedToken.isNotEmpty && _cachedTokenVerified) return _cachedToken;

    // 2) account.accessToken：先用它试一次（真实请求验证，比时间猜进度可靠）
    if (account.accessToken.isNotEmpty) {
      _cachedToken = account.accessToken;
      if (await _tryToken(_cachedToken)) {
        _cachedTokenVerified = true;
        return _cachedToken;
      }
      debugPrint('[Aliyun] 本地 access_token 失效，尝试刷新');
    }

    // 3) 用 refresh_token 刷新（refresh_token 为空则 refreshAccessToken 直接返回 null）
    final t = await refreshAccessToken();
    if (t != null && t.isNotEmpty) {
      _cachedToken = t;
      _cachedTokenVerified = true;
      return _cachedToken;
    }

    // 4) 最后兜底：如果本地有 access_token，即使验证失败也交给上层再试一次
    //    （有些接口路径对 token 的校验不同，比如列目录失败但下载可用）
    if (_cachedToken.isNotEmpty) return _cachedToken;
    return null;
  }

  /// 当前 `_cachedToken` 是否已被真实请求验证通过。
  bool _cachedTokenVerified = false;

  void dispose() => _client.close();

  /// 内置 client_id 优先，用户自填的覆盖。
  String get _effectiveClientId =>
      (clientId != null && clientId!.isNotEmpty) ? clientId! : _builtinClientId;

  /// 用 refresh_token 换 access_token。
  ///
  /// 按官方 OAuth2.0 文档（Web 服务端应用接入流程），标准路径是
  /// `POST /v2/account/token`，form 编码，`grant_type=refresh_token`。
  /// 网页版还有一条 `api.alipan.com/v2/account/token` 的等价接口（不需要
  /// client_id），先试它，失败再走 OAuth 标准端点。
  ///
  /// 最后兜底：阿里云盘的 refresh_token 和 access_token 格式相似，
  /// 有些账号从 localStorage 里抓到的「refresh_token」其实能直接当
  /// access_token 用，所以再验证一次。
  Future<String?> refreshAccessToken() async {
    final rt = account.refreshToken;
    if (rt.isEmpty) return null;

    // 方案 1: Web API（api.alipan.com，无需 client_id，免费账号也能用）
    final tok = await _refreshAtWeb(rt);
    if (tok != null) return tok;

    // 方案 2: OAuth 标准端点（auth.alipan.com，需要有效 client_id/secret）
    final tok2 = await _refreshAtOAuth(rt);
    if (tok2 != null) return tok2;

    // 方案 3: 直接把 refresh_token 当 access_token 试一次
    if (await _tryToken(rt)) return rt;

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
        if (_driveId.isNotEmpty) 'drive_id': _driveId,
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
        if (_driveId.isNotEmpty) 'drive_id': _driveId,
        'parent_file_id': 'root',
        'limit': 1,
      }));
      final resp = await req.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// OAuth 端点：`auth.alipan.com/v2/account/token`
  ///
  /// 按官方 OAuth2.0 文档（Web 服务端应用接入流程），token 接口要求
  /// `Content-Type: application/x-www-form-urlencoded`，字段为
  /// `refresh_token` / `client_id` / `client_secret` / `grant_type`。
  /// 之前这里发的是 JSON，服务端直接 400，所以永远拿不到 token。
  Future<String?> _refreshAtOAuth(String rt) async {
    try {
      final uri = Uri.parse('$_authApi/v2/account/token');
      final form = <String, String>{
        'refresh_token': rt,
        'grant_type': 'refresh_token',
        'client_id': _effectiveClientId,
      };
      if (clientSecret != null && clientSecret!.isNotEmpty) {
        form['client_secret'] = clientSecret!;
      }
      final tok = await _postForm(uri, form, 'OAuth');
      if (tok != null) return tok;
    } catch (e) {
      debugPrint('[Aliyun] OAuth token 失败: $e');
    }
    return null;
  }

  /// Web API 端点：`api.alipan.com/v2/account/token`
  ///
  /// 网页版换 token 不需要 client_id，但同样接受 form 编码。
  Future<String?> _refreshAtWeb(String rt) async {
    try {
      final uri = Uri.parse('$_webApi/v2/account/token');
      final tok = await _postForm(
        uri,
        {'refresh_token': rt, 'grant_type': 'refresh_token'},
        'Web',
      );
      if (tok != null) return tok;
    } catch (e) {
      debugPrint('[Aliyun] Web token 失败: $e');
    }
    return null;
  }

  /// POST `application/x-www-form-urlencoded` 换 token，解析 access_token。
  ///
  /// 同时兼容两种返回结构：
  ///  - OAuth 标准：`{"access_token":"...","refresh_token":"...","expire_in":7200}`
  ///  - 网页版偶尔包一层：`{"token":{"access_token":"..."}}`
  Future<String?> _postForm(
      Uri uri, Map<String, String> form, String tag) async {
    final req = await _client.postUrl(uri);
    req.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    req.headers.set('User-Agent', userAgent);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Referer', 'https://www.alipan.com/');
    req.write(Uri(queryParameters: form).query);
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      debugPrint('[Aliyun] $tag token HTTP ${resp.statusCode} $body');
      return null;
    }
    final j = jsonDecode(body);
    if (j is! Map) return null;
    // 兼容包一层 {"token":{...}}
    final src = (j['token'] is Map) ? (j['token'] as Map) : j;
    final tok = src['access_token']?.toString() ??
        src['accessToken']?.toString() ??
        j['access_token']?.toString() ??
        j['accessToken']?.toString();
    if (tok == null || tok.isEmpty) return null;
    // 顺手记下新的 refresh_token（阿里会轮换）
    final newRt = src['refresh_token']?.toString();
    if (newRt != null && newRt.isNotEmpty) {
      debugPrint('[Aliyun] $tag token 轮换了 refresh_token');
    }
    return tok;
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
      debugPrint('[Aliyun] connect driveId=$_driveId tokenLen=${token.length}');

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
          if (did.isNotEmpty) {
            debugPrint('[Aliyun] web drive_id=$did');
            return did;
          }
          // 200 但 drive_id 为空：说明后端要求别的字段或该账号结构不同，
          // 不能直接返回空串提前结束，继续降级尝试后面的方案。
          debugPrint('[Aliyun] web getDriveInfo 无 default_drive_id，降级');
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
          if (did.isNotEmpty) {
            debugPrint('[Aliyun] open drive_id=$did');
            return did;
          }
          debugPrint('[Aliyun] open getDriveInfo 无 default_drive_id，降级');
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
  ///
  /// `drive_id` 为空时先补探测一次：阿里云盘的列目录接口**必须**带
  /// drive_id，漏了会直接 400/404，表现出来就是「登录成功但网盘打不开」。
  Future<List<CloudFileItem>?> listDirectory(String parentId,
      {String parentPath = '/'}) async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;

    if (_driveId.isEmpty) {
      _driveId = await _probeDriveId(token);
      debugPrint('[Aliyun] listDirectory 补探测 driveId=$_driveId');
    }

    // 先试 web API
    final webItems = await _listDirWeb(token, parentId, parentPath);
    if (webItems != null) return webItems;

    // web 失败：token 可能已失效 → 强制刷新一次再重试
    _cachedTokenVerified = false;
    _cachedToken = '';
    final retryToken = await _token();
    if (retryToken != null &&
        retryToken.isNotEmpty &&
        retryToken != token) {
      final retry = await _listDirWeb(retryToken, parentId, parentPath);
      if (retry != null) return retry;
    }

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
          if (_driveId.isNotEmpty) 'drive_id': _driveId,
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
          if (_driveId.isNotEmpty) 'drive_id': _driveId,
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
  ///
  /// 注意 `drive_id` 必填：为空时先补探测，否则接口直接报错，
  /// 表现为「目录能看但点开视频播不了」。
  Future<String?> getDownloadUrl(String fileId) async {
    var token = await _token();
    if (token == null || token.isEmpty) return null;

    if (_driveId.isEmpty) {
      _driveId = await _probeDriveId(token);
      debugPrint('[Aliyun] getDownloadUrl 补探测 driveId=$_driveId');
    }

    // 先试 web API
    final webUrl = await _downloadUrlWeb(token, fileId);
    if (webUrl != null) return webUrl;

    // web 失败：token 可能已过期，刷新后重试一次
    _cachedTokenVerified = false;
    _cachedToken = '';
    final retryToken = await _token();
    if (retryToken != null && retryToken.isNotEmpty && retryToken != token) {
      token = retryToken;
      final retry = await _downloadUrlWeb(token, fileId);
      if (retry != null) return retry;
    }

    return _downloadUrlOpen(token, fileId);
  }

  Future<String?> _downloadUrlWeb(String token, String fileId) async {
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
      } else {
        debugPrint('[Aliyun] web 取直链 HTTP ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[Aliyun] web 取直链失败: $e');
    }
    return null;
  }

  Future<String?> _downloadUrlOpen(String token, String fileId) async {
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
      } else {
        debugPrint('[Aliyun] open 取直链 HTTP ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[Aliyun] open 取直链失败: $e');
    }
    return null;
  }

  /// 当前可用的 access_token（供播放器构造 Authorization 头用）。
  Future<String?> currentToken() => _token();

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1);
  }
}
