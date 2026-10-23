import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cloud_drive_model.dart';
import 'p115_cipher.dart';

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
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

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
          // 文件用 pickcode（取直链必需），目录用 cid（列子目录用）。
          // 字段名在不同接口版本里是 `pc` 或 `pickcode`；目录 id 是 `cid`
          // 或 `fid`。这里都兼容，避免取直链时拿到 fid 而必然失败。
          final pc = (raw['pc'] ?? raw['pickcode'])?.toString() ?? '';
          final fid = raw['fid']?.toString() ?? '';
          final cidF = (raw['cid'] ?? raw['fid'])?.toString() ?? '';
          items.add(CloudFileItem(
            id: dir ? cidF : (pc.isNotEmpty ? pc : fid),
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
  /// 115 的流程：用 `pickcode`（文件列表里的 `pc` 字段）换一次性下载地址。
  ///
  /// 原实现有三个致命缺陷，导致「直链获取失败」：
  ///
  /// 1. **只看 `data` 的类型，不看 `state`**
  ///    接口失败时返回 `{"state":false,"error":"请重新登录","errno":99}`，
  ///    `data` 是空数组 `[]`。原代码 `if (data is Map)` 不成立就直接
  ///    `return null`，连「cookie 失效」这个原因都丢了。
  ///
  /// 2. **成功时 `data` 是 RSA 加密的 base64 字符串**
  ///    `proapi/app/chrome/downurl` 的响应里 `data` 字段是加密的，
  ///    原文结构是 `{"<pickcode>":{"file_url":"https://..."}}`。
  ///    所以成功时 `data is Map` 同样不成立 —— 即使鉴权正常也必然失败。
  ///
  /// 3. **响应字段名是 `file_url`，不是 `url`**
  ///    网页版下载结果的真正字段是 `file_url` / `file_name` / `file_size`，
  ///    原代码只找 `url`，即使拿到明文也提取不到。
  ///
  /// 现在的通道顺序（先无解密、再解密，兼顾速度与大小限制）：
  ///   A. `115.com/?ct=download&ac=video`：302 重定向，`Location` 即直链，
  ///      **不需要 RSA**，失败快（限 ≤200MB）
  ///   B. `webapi.115.com/files/download` GET：明文 JSON（限 ≤200MB）
  ///   C. `proapi/app/chrome/downurl` POST：响应经 RSA 混淆，
  ///      用 [P115Cipher] 还原。**无 200MB 限制**，大文件走这条。
  ///
  /// A/B 先试是因为它们更快（一次请求即返回）；超过 200MB 时 A/B 会失败，
  /// 自动落到 C。这样小文件不付 RSA 解密的 CPU 成本，大文件又能播。
  Future<String?> getDownloadUrl(String pickCode) async {
    if (pickCode.isEmpty) {
      debugPrint('[115] pickcode 为空，无法取直链');
      return null;
    }

    // A. 无加密的 302 通道（最稳、最快）
    final via302 = await _downloadUrlVia302(pickCode);
    if (via302 != null) return via302;

    // B. webapi GET 明文通道
    final plain = await _downloadUrlWebApiGet(pickCode);
    if (plain != null) return plain;

    // C. proapi + RSA 还原（>200MB 大文件走这条）
    return _downloadUrlProApi(pickCode);
  }

  /// 通道 A：`GET https://115.com/?ct=download&ac=video&pickcode=xxx`
  ///
  /// 这个接口**不加密**：带有效 Cookie 时直接返回 302，`Location` 就是
  /// 下载直链（且该直链本身通常不再校验 Cookie）。
  /// 文件 >200MB 时它会重定向回登录页，此时 `Location` 里带 `goto=`，
  /// 可以据此识别并降级到其它通道。
  Future<String?> _downloadUrlVia302(String pickCode) async {
    try {
      final uri = Uri.parse(
          'https://115.com/?ct=download&ac=video&pickcode=$pickCode');
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      // 关键：不自动跟随重定向，我们要的就是 Location
      req.followRedirects = false;
      final resp = await req.close();

      // 先取 headers（必须在 drain 之前，HttpClientResponse 的 headers
      // 在读完 body 后仍可读，但先读更稳妥，也便于记录 Set-Cookie）
      final loc = resp.headers.value('location') ?? '';
      final setCookie = resp.headers.value('set-cookie') ?? '';
      // 丢弃响应体，避免连接复用被 body 阻塞
      await resp.drain<void>();

      if (resp.statusCode != 302 && resp.statusCode != 301) {
        debugPrint('[115] 302 通道 HTTP ${resp.statusCode}（多半 >200MB 或已删除）');
        return null;
      }
      if (loc.isEmpty) {
        debugPrint('[115] 302 通道没有 Location');
        return null;
      }
      // 未登录/超限时会被重定向回站内页面，带 goto= 参数
      if (loc.contains('goto=') || loc.contains('ct=download')) {
        debugPrint('[115] 302 通道被弹回（>200MB / Cookie 失效）');
        return null;
      }
      // 记住这个通道下发的附加 Cookie：直链若带 f=3，播放时必须带上它，
      // 否则 403。这里存下来供上层拼请求头。
      if (setCookie.isNotEmpty) {
        _lastSetCookie = setCookie.split(';').first.trim();
        debugPrint('[115] 302 通道下发附加 Cookie: $_lastSetCookie');
      }
      return loc;
    } catch (e) {
      debugPrint('[115] 302 通道失败: $e');
    }
    return null;
  }

  /// 取直链时服务端通过 `Set-Cookie` 下发的附加 Cookie（形如 `k=v`）。
  ///
  /// 115 直链里 `f` 参数表示播放时的校验要求：
  ///  - 空：无要求
  ///  - `1`：要求 User-Agent 与取链时一致
  ///  - `3`：要求 UA **且** 带上下发的 Cookie
  /// 所以要把这个值暴露给上层，拼进播放请求头。
  String get lastSetCookie => _lastSetCookie;
  String _lastSetCookie = '';

  /// 通道 B：`GET webapi.115.com/files/download?pickcode=xxx`
  ///
  /// 明文 JSON，成功结构：
  /// `{"state":true,"data":{"file_url":"https://...","file_name":"..."}}`
  Future<String?> _downloadUrlWebApiGet(String pickCode) async {
    try {
      final uri = Uri.parse(
          '$_webApi/files/download?pickcode=$pickCode'
          '&ac=1&t=${DateTime.now().millisecondsSinceEpoch}');
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[115] webapi download HTTP ${resp.statusCode}');
        return null;
      }
      // 同样可能下发附加 Cookie（直链 f=3 时需要）
      final setCookie = resp.headers.value('set-cookie') ?? '';
      final body = await resp.transform(utf8.decoder).join();
      if (setCookie.isNotEmpty) {
        _lastSetCookie = setCookie.split(';').first.trim();
      }
      final j = jsonDecode(body);
      if (j is! Map) return null;
      return _extractUrlFromEnvelope(j, 'webapi');
    } catch (e) {
      debugPrint('[115] webapi 取直链失败: $e');
    }
    return null;
  }

  /// 通道 C：`POST proapi.115.com/app/chrome/downurl`
  ///
  /// 该端点**响应经过 RSA 混淆**（`data` 字段是加密字符串）。
  /// 这里用 [P115Cipher] 还原成 `{"<pickcode>":{"file_url":...}}`。
  ///
  /// 这一条**没有 200MB 限制**，是 >200MB 大文件的唯一可行通道。
  ///
  /// 注意请求体目前仍发明文 JSON：115 对 chrome 通道的入参校验较宽松，
  /// 若服务端要求 RSA 加密入参，会返回 state=false，此时报错信息里能看到。
  Future<String?> _downloadUrlProApi(String pickCode) async {
    try {
      final uri = Uri.parse(
          '$_proApi/app/chrome/downurl?t=${DateTime.now().millisecondsSinceEpoch}');
      final req = await _client.postUrl(uri);
      _headers.forEach(req.headers.set);
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      req.write(
          'data=${Uri.encodeComponent(jsonEncode({'pickcode': pickCode}))}');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[115] proapi download HTTP ${resp.statusCode}');
        return null;
      }
      final setCookie = resp.headers.value('set-cookie') ?? '';
      final body = await resp.transform(utf8.decoder).join();
      if (setCookie.isNotEmpty) {
        _lastSetCookie = setCookie.split(';').first.trim();
      }

      final j = jsonDecode(body);
      if (j is! Map) return null;

      // 先看 state：失败时 data 是空数组，把真实原因打出来
      if (j['state'] == false) {
        final errno = j['errno'] ?? j['errNo'];
        final msg = j['error']?.toString() ?? '未知错误';
        debugPrint('[115] proapi 业务失败 errno=$errno msg=$msg');
        return null;
      }

      final data = j['data'];

      // ① 明文形态（少数情况，接口调整时）
      if (data is Map) {
        final url = _extractUrlFromDataMap(data, 'proapi');
        if (url != null) return url;
      }

      // ② 加密形态：base64 字符串，用内置公钥还原
      if (data is String && data.isNotEmpty) {
        final decoded = P115Cipher.decryptJson(data);
        debugPrint('[115] proapi data 长度=${data.length} '
            '解密结果=${decoded == null ? "失败" : decoded.runtimeType}');
        if (decoded is Map) {
          // 结构一：{"<pickcode>":{"file_url":...}}
          // 结构二：{"file_url":...}（直接平铺）
          final url = _extractUrlFromDataMap(decoded, 'proapi-dec');
          if (url != null) return url;
        }
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final url = _extractUrlFromDataMap(item, 'proapi-dec');
              if (url != null) return url;
            }
          }
        }
        return null;
      }
    } catch (e) {
      debugPrint('[115] proapi 取直链失败: $e');
    }
    return null;
  }

  /// 从「外层信封」里抽 url，兼容多种结构。
  ///
  /// 注意 115 的**真实字段名是 `file_url`**（不是 `url`）：
  /// `{"state":true,"data":{"file_url":"...","file_name":"..."}}`
  String? _extractUrlFromEnvelope(Map<dynamic, dynamic> j, String tag) {
    if (j['state'] == false) {
      final errno = j['errno'] ?? j['errNo'];
      final msg = j['error']?.toString() ?? '未知错误';
      debugPrint('[115] $tag 业务失败 errno=$errno msg=$msg');
      return null;
    }
    final data = j['data'];
    if (data is Map) return _extractUrlFromDataMap(data, tag);
    if (data is List && data.isNotEmpty) {
      for (final item in data) {
        if (item is Map) {
          final u = _extractUrlFromDataMap(item, tag);
          if (u != null) return u;
        }
      }
    }
    debugPrint('[115] $tag 响应里没找到 url，data 类型=${data.runtimeType}');
    return null;
  }

  /// 从 `data` 对象里抽 url。
  ///
  /// 115 的字段名在不同通道里不一致，全部覆盖：
  ///  - `file_url`（网页版 download 的标准字段）
  ///  - `url`（部分接口/历史结构）
  ///  - 嵌套 `{"url":{"url":"..."}}`
  ///  - 按 pickcode 包一层 `{"<pc>":{"file_url":"..."}}`
  String? _extractUrlFromDataMap(Map<dynamic, dynamic> data, String tag) {
    // 最常见的两种直接字段
    for (final key in const ['file_url', 'url', 'download_url']) {
      final v = data[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is Map) {
        final inner = v['url'] ?? v['file_url'];
        if (inner is String && inner.isNotEmpty) return inner;
      }
    }
    // 按 pickcode 包一层
    for (final v in data.values) {
      if (v is Map) {
        for (final k in const ['file_url', 'url']) {
          final u = v[k];
          if (u is String && u.isNotEmpty) return u;
          if (u is Map) {
            final s = u['url'] ?? u['file_url'];
            if (s is String && s.isNotEmpty) return s;
          }
        }
      }
    }
    debugPrint('[115] $tag data 里没有 url，keys=${data.keys.take(6).toList()}');
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
