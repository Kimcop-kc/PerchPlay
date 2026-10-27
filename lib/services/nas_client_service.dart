import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import '../models/nas_connection_model.dart';

/// 单个 NAS 连接的客户端（SMB/FTP/WebDAV）。
class _NasConnection {
  _NasConnection(this.config);

  final NasConnection config;
  HttpClient? httpClient;
  Smb2Pool? smbPool;
  bool connected = false;

  /// 最近一次操作的具体错误（空串 = 无错误）。
  ///
  /// 各 `_listXxx` 内部把异常转成空数组返回，但会把原因写到这里，
  /// 让上层能区分「空目录」和「读取失败」。
  String lastError = '';

  Future<bool> connect() async {
    // SMB 不走 HttpClient
    if (config.protocol != NasProtocol.smb) {
      // 先关掉可能存在的旧客户端，避免每次重连都泄漏一个连接池。
      // 反复「返回主页 → 再点连接」时，旧 HttpClient 不关会累积，
      // 每个都持有到 NAS 的 keep-alive 连接。
      try {
        httpClient?.close(force: true);
      } catch (_) {}
      httpClient = HttpClient();
      httpClient!.connectionTimeout = const Duration(seconds: 10);
      // 避免空闲连接被 NAS 单方面断掉后仍留在池里被复用
      httpClient!.idleTimeout = const Duration(seconds: 5);
    }
    try {
      switch (config.protocol) {
        case NasProtocol.webdav:
          return await _connectWebDav();
        case NasProtocol.ftp:
          return await _connectFtp();
        case NasProtocol.smb:
          return await _connectSmb();
        case NasProtocol.nfs:
          return false;
      }
    } catch (e) {
      debugPrint('[NAS] connect error: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    httpClient?.close();
    httpClient = null;
    try {
      await smbPool?.disconnect();
    } catch (_) {}
    smbPool = null;
    connected = false;
  }

  /// 轻量探测当前连接是否真的还能用。
  ///
  /// 只发一个 OPTIONS（WebDAV/FTP/HTTP 都支持），超时 3 秒。
  /// 任何异常/超时都判定为「已失效」，让上层重建连接。
  ///
  /// 为什么不能只看 [connected]：那只是「上次成功过」的历史标志。
  /// 播放器拉流、系统睡眠、NAS 空闲断连都会让底层 socket 悄悄失效，
  /// 而标志位不会自己变 false。
  Future<bool> ping() async {
    if (!connected) return false;
    // SMB 用连接池，ping 代价高，交给它的重连机制
    if (config.protocol == NasProtocol.smb) return true;
    final c = httpClient;
    if (c == null) return false;
    try {
      final uri = Uri(
        scheme: config.useHttps ? 'https' : 'http',
        host: config.host,
        port: config.port,
        path: config.remotePath.isNotEmpty ? config.remotePath : '/',
      );
      // 用 Future.any 做硬超时：HttpClient 的 connectionTimeout 只管
      // 「建立连接」，连接已建立但对端不回包时会一直等下去。
      final probe = () async {
        final req = await c.openUrl('OPTIONS', uri);
        final resp = await req.close();
        await resp.drain<void>();
        return resp.statusCode;
      }();
      final code = await Future.any<int?>([
        probe,
        Future<int?>.delayed(const Duration(seconds: 3), () => null),
      ]);
      if (code == null) {
        debugPrint('[NAS] ping 超时(3s)，判定连接失效');
        return false;
      }
      debugPrint('[NAS] ping 返回 HTTP $code');
      // 只要拿到响应就算活着（OPTIONS 可能返回 405/501）
      return code > 0;
    } catch (e) {
      debugPrint('[NAS] ping 异常: $e');
      return false;
    }
  }

  // ──────────── WebDAV ────────────

  Future<bool> _connectWebDav() async {
    final c = config;
    httpClient ??= HttpClient();
    httpClient!.connectionTimeout = const Duration(seconds: 10);
    try {
      // 尝试 OPTIONS 测试连接。WebDAV 很多实现 OPTIONS 会返回
      // 500/501（不支持），所以 200-599 都接受，只检查是否真能
      // 连上（socket 连不通会抛 IOException）。
      final uri = Uri(
        scheme: c.useHttps ? 'https' : 'http',
        host: c.host,
        port: c.port,
        path: c.remotePath.isNotEmpty ? c.remotePath : '/',
      );
      await _request(uri, 'OPTIONS', client: httpClient!);
      connected = true;
      return true;
    } catch (e) {
      debugPrint('[NAS] WebDAV 连接失败: $e');
      return false;
    }
  }

  Future<List<NasFileItem>> _listWebDav(String path) async {
    final c = config;
    final client = httpClient;
    if (client == null) {
      lastError = 'WebDAV 未连接';
      return [];
    }
    try {
      final uri = Uri(
        scheme: c.useHttps ? 'https' : 'http',
        host: c.host,
        port: c.port,
        path: path.isNotEmpty ? path : '/',
      );
      final resp = await _request(uri, 'PROPFIND',
          client: client,
          headers: {'Depth': '1'},
          body: _propfindBody);
      if (resp == null) {
        lastError = 'PROPFIND 无响应（地址或网络问题）';
        return [];
      }
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 207) {
        // 401 认证失败 / 404 路径不存在 / 405 不是 WebDAV 端点
        lastError = switch (resp.statusCode) {
          401 => '认证失败（用户名或密码错误）',
          403 => '无访问权限',
          404 => '路径不存在：$path\n'
              '（若服务器要求 WebDAV 前缀如 /dav，请在「路径」里填上）',
          405 => '该地址不是 WebDAV 端点（METHOD 不允许）',
          _ => 'PROPFIND 失败 HTTP ${resp.statusCode}',
        };
        debugPrint('[NAS] PROPFIND $path -> HTTP ${resp.statusCode}');
        return [];
      }
      // 把「当前请求的路径」传进去：解析时要靠它跳过「自身」那一条，
      // 只跳过自身、保留子目录。原来靠「href 以 / 结尾」判断目录，
      // 结果把所有目录都跳过了。
      final parsed = _parseWebDavMultiStatus(body, requestPath: path);
      debugPrint('[NAS] PROPFIND $path -> HTTP 207, '
          '响应 ${body.length} 字节, 解析出 ${parsed.length} 项');
      return parsed;
    } catch (e) {
      lastError = '网络异常：$e';
      debugPrint('[NAS] WebDAV list 异常: $e');
      return [];
    }
  }

  // ──────────── FTP ────────────

  Future<bool> _connectFtp() async {
    final c = config;
    try {
      final socket = await Socket.connect(c.host, c.port,
          timeout: const Duration(seconds: 10));
      final ftp = _FtpControl(socket);
      final line = await ftp.readResponse();
      if (line == null || !line.startsWith('220')) return false;
      await ftp.sendCommand('USER ${c.username}');
      final userResp = await ftp.readResponse();
      if (userResp == null) return false;
      if (userResp.startsWith('331')) {
        await ftp.sendCommand('PASS ${c.password}');
        final passResp = await ftp.readResponse();
        if (passResp == null || !passResp.startsWith('230')) return false;
      }
      await ftp.quit();
      connected = true;
      return true;
    } catch (e) {
      debugPrint('[NAS] FTP 连接失败: $e');
      return false;
    }
  }

  Future<List<NasFileItem>> _listFtp(String path) async {
    final c = config;
    try {
      final socket = await Socket.connect(c.host, c.port,
          timeout: const Duration(seconds: 10));
      final ftp = _FtpControl(socket);
      await ftp.readResponse(); // 220
      await ftp.sendCommand('USER ${c.username}');
      await ftp.readResponse();
      await ftp.sendCommand('PASS ${c.password}');
      await ftp.readResponse();
      // PASV + LIST
      await ftp.sendCommand('PASV');
      final pasvResp = await ftp.readResponse();
      if (pasvResp == null) {
        await ftp.quit();
        return [];
      }
      final pasv = _parsePasv(pasvResp);
      if (pasv == null) {
        await ftp.quit();
        return [];
      }
      final p = path.trim().isEmpty ? '/' : path.trim();
      await ftp.sendCommand(p == '/' ? 'LIST' : 'LIST $p');
      final dataSocket =
          await Socket.connect(pasv['host']!, int.parse(pasv['port']!),
              timeout: const Duration(seconds: 10));
      await ftp.readResponse(); // 消费 LIST 响应，保持协议时序
      final data = await dataSocket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      dataSocket.destroy();
      await ftp.quit();
      return _parseFtpList(data, basePath: p);
    } catch (e) {
      debugPrint('[NAS] FTP list 失败: $e');
      return [];
    }
  }

  // ──────────── SMB ────────────

  Future<bool> _connectSmb() async {
    final c = config;
    final share = c.shareName.trim();
    if (share.isEmpty) {
      connected = false;
      return false;
    }
    try {
      await smbPool?.disconnect();
      smbPool = await Smb2Pool.connect(
        host: c.host,
        share: share,
        user: c.username.isEmpty ? null : c.username,
        password: c.password.isEmpty ? null : c.password,
        domain: c.domain.isEmpty ? null : c.domain,
      );
      await smbPool!.listDirectory('');
      connected = true;
      return true;
    } catch (e) {
      debugPrint('[NAS] SMB 连接失败: $e');
      smbPool = null;
      connected = false;
      return false;
    }
  }

  Future<List<NasFileItem>> _listSmb(String path) async {
    final pool = smbPool;
    if (pool == null) return [];
    var rel = path.trim();
    if (rel.startsWith('/')) rel = rel.substring(1);
    if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);

    final entries = await pool.listDirectory(rel);
    final items = <NasFileItem>[];
    for (final e in entries) {
      if (e.name == '.' || e.name == '..') continue;
      final childPath = rel.isEmpty ? '/${e.name}' : '/$rel/${e.name}';
      final st = e.stat;
      items.add(NasFileItem(
        name: e.name,
        path: childPath,
        isDirectory: st.isDirectory,
        size: st.size,
        modifiedTime: st.modified,
      ));
    }
    return items;
  }

  // ──────────── Public ops ────────────

  Future<List<NasFileItem>> listDirectory(String path) async {
    try {
      switch (config.protocol) {
        case NasProtocol.webdav:
          return await _listWebDav(path);
        case NasProtocol.ftp:
          return await _listFtp(path);
        case NasProtocol.smb:
          return await _listSmb(path);
        case NasProtocol.nfs:
          return [];
      }
    } catch (e) {
      debugPrint('[NAS] listDirectory 失败: $e');
      return [];
    }
  }

  String getPlayableUrl(String path) {
    final c = config;
    if (c.protocol == NasProtocol.smb) {
      // SMB 不做 URL 转换，返回 path 原样给 dart_smb2 stream
      return 'smb://${c.host}/${c.shareName}$path';
    }
    final scheme = c.useHttps ? 'https' : 'http';
    // 注意：URL 里**不能**带账号密码（mpv 会把它当路径的一部分，
    // 而且明文密码会进日志）。认证交给调用方通过 headers 传。
    return '$scheme://${c.host}:${c.port}$path';
  }

  /// 播放该文件时需要的 HTTP 请求头。
  ///
  /// 之前 `getPlayableUrl` 只拼了裸 URL，**没有带认证**：
  /// 列目录走 `_request` 会加 `Authorization: Basic ...`，
  /// 但播放是 mpv 直接连 NAS，它不知道账号密码 —— 于是需要认证的
  /// NAS 上会出现「目录能看、视频打不开（401）」。
  ///
  /// 这里把认证头暴露出来，由播放页传给播放器。
  Map<String, String> playHeaders() {
    final c = config;
    if (c.protocol == NasProtocol.smb) return const {};
    if (c.username.isEmpty) return const {};
    final raw = '${c.username}:${c.password}';
    return {
      'Authorization': 'Basic ${base64Encode(utf8.encode(raw))}',
    };
  }

  // ──────────── HTTP helpers ────────────

  Future<HttpClientResponse?> _request(
    Uri uri,
    String method, {
    HttpClient? client,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    client ??= HttpClient();
    final req = await (method == 'PROPFIND'
        ? _propfindRequest(uri, client)
        : (method == 'GET'
            ? client.getUrl(uri)
            : client.postUrl(uri)));
    headers.forEach(req.headers.set);
    if (config.username.isNotEmpty) {
      final auth = base64Encode(
          utf8.encode('${config.username}:${config.password}'));
      req.headers.set('Authorization', 'Basic $auth');
    }
    if (body != null) {
      req.headers.contentType = ContentType('application', 'xml');
      req.write(body);
    }
    try {
      return await req.close();
    } catch (_) {
      return null;
    }
  }

  Future<HttpClientRequest> _propfindRequest(
      Uri uri, HttpClient client) async {
    // 用 openUrl 构造 PROPFIND（dart:io 不直接支持）
    final req =
        await client.openUrl('PROPFIND', uri);
    return req;
  }

  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>''';

  /// 解析 WebDAV 的 multistatus 响应。
  ///
  /// ## 修复的三个缺陷
  ///
  /// **① 目录被整体跳过（根因）**
  /// 原代码有这一行：
  /// ```dart
  /// if (href.endsWith('/') && !href.contains('?')) continue; // skip dirs
  /// ```
  /// WebDAV 规范里**目录的 href 一定以 `/` 结尾**，所以这一行把所有目录
  /// 都丢掉了，只剩文件。如果用户配置的目录下只有子文件夹（很常见），
  /// 列表就是完全空白 —— 表现正是「连接没报错，但看不到文件」。
  ///
  /// **② 第二个跳过条件也误伤目录**
  /// ```dart
  /// if (name.isEmpty || name == href.split('/').last && isDir) continue;
  /// ```
  /// 当服务器没给 `<D:displayname>` 时，name 会回退成 `href.split('/').last`，
  /// 此时目录必然命中这个条件被跳过。
  ///
  /// **③ path 直接用 href**
  /// href 可能是绝对路径（`/dav/movies`）、也可能是完整 URL
  /// （`https://host/dav/movies`）。直接用会把 URL 当路径拼接，
  /// 后续请求拼出畸形地址。这里统一归一化成以 `/` 开头的路径。
  ///
  /// 正确的做法是**只跳过「当前请求目录自身」那一条**（WebDAV 响应里
  /// 第一条总是自身），其余全部保留。
  List<NasFileItem> _parseWebDavMultiStatus(
    String xml, {
    String requestPath = '',
  }) {
    final items = <NasFileItem>[];
    // ── XML 标签匹配：不能硬编码 `D:` 前缀 ──
    //
    // RFC 4918 规定 XML 命名空间前缀可以任意命名（`D:` / `d:` / `ns0:` / 无前缀），
    // 之前这里全部写死 `<D:xxx>`，导致返回小写 `d:` 或无前缀的服务器
    // （群晖、部分 WebDAV 网关）解析出 0 项或全部误判成文件：
    //   - isDirectory 恒为 false → 目录点不开（日志 dir=false video=false）
    //   - 视频也识别不出来 → 点不开
    //
    // 现在用「任意前缀（含无前缀）+ 不区分大小写」的写法。
    // ns 后面紧跟标签名，用 ${ns} 明确边界，避免 $ns? 被误读。
    const ns = r'(?:[A-Za-z0-9_.-]+:)?';
    final responsePattern = RegExp(
      '<${ns}response\\b[^>]*>.*?</${ns}response>',
      dotAll: true,
      caseSensitive: false,
    );
    final hrefPattern = RegExp(
      '<${ns}href\\b[^>]*>(.*?)</${ns}href>',
      dotAll: true,
      caseSensitive: false,
    );
    final displayNamePattern = RegExp(
      '<${ns}displayname\\b[^>]*>(.*?)</${ns}displayname>',
      dotAll: true,
      caseSensitive: false,
    );
    // collection 是**空元素**：`<D:collection/>` 或 `<D:collection></D:collection>`
    // 两种写法都要认（之前的 `<D:collection/>` 只认第一种）。
    final collectionPattern = RegExp(
      '<${ns}collection\\b[^>]*(?:/>|>\\s*</${ns}collection>)',
      dotAll: true,
      caseSensitive: false,
    );
    final lengthPattern = RegExp(
      '<${ns}getcontentlength\\b[^>]*>(\\d+)</${ns}getcontentlength>',
      caseSensitive: false,
    );
    final modifiedPattern = RegExp(
      '<${ns}getlastmodified\\b[^>]*>(.*?)</${ns}getlastmodified>',
      dotAll: true,
      caseSensitive: false,
    );

    /// 归一化：去掉完整 URL 的 scheme/host、解码、去掉末尾 `/`
    String normPath(String raw) {
      var s = raw.trim();
      if (s.isEmpty) return '';
      // 完整 URL -> 只取 path
      if (s.startsWith('http://') || s.startsWith('https://')) {
        final u = Uri.tryParse(s);
        s = u?.path ?? s;
      }
      try {
        s = Uri.decodeFull(s);
      } catch (_) {}
      // 去掉 query/fragment
      final q = s.indexOf('?');
      if (q >= 0) s = s.substring(0, q);
      final h = s.indexOf('#');
      if (h >= 0) s = s.substring(0, h);
      // 去掉末尾斜杠（保留根）
      while (s.length > 1 && s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      if (!s.startsWith('/')) s = '/$s';
      return s;
    }

    final selfPath = normPath(requestPath);

    for (final m in responsePattern.allMatches(xml)) {
      final resp = m.group(0)!;
      final rawHref = hrefPattern.firstMatch(resp)?.group(1) ?? '';
      if (rawHref.isEmpty) continue;

      final isDir = collectionPattern.hasMatch(resp);
      final path = normPath(rawHref);
      if (path.isEmpty) continue;

      // 只跳过「当前目录自身」（WebDAV 响应第一条固定是自身）
      if (selfPath.isNotEmpty && path == selfPath) continue;

      // 名称：优先 displayname，其次路径最后一段
      var name = displayNamePattern.firstMatch(resp)?.group(1) ?? '';
      name = name.trim();
      if (name.isEmpty) {
        final segs = path.split('/').where((e) => e.isNotEmpty).toList();
        name = segs.isEmpty ? '' : segs.last;
      }
      try {
        name = Uri.decodeFull(name);
      } catch (_) {}
      if (name.isEmpty) continue;

      final sizeStr = lengthPattern.firstMatch(resp)?.group(1) ?? '0';
      final modStr = modifiedPattern.firstMatch(resp)?.group(1);

      items.add(NasFileItem(
        name: name,
        path: path,
        isDirectory: isDir,
        size: int.tryParse(sizeStr) ?? 0,
        modifiedTime: modStr != null ? DateTime.tryParse(modStr) : null,
      ));
    }

    // 稳定排序：目录在前，同类按名称
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  /// 解析 FTP LIST 的类 Unix 长格式输出。
  ///
  /// [basePath] 是本次 LIST 的目录路径。子项的 path 必须拼上它，
  /// 否则进入子目录后返回的 path 都变成 `/名字`，把父目录层级丢掉 ——
  /// 表现为「进得去、退不回，点文件也播不了」。
  List<NasFileItem> _parseFtpList(String data, {String basePath = '/'}) {
    final items = <NasFileItem>[];
    final base = basePath.trim().isEmpty || basePath.trim() == '/'
        ? ''
        : basePath.trim().replaceAll(RegExp(r'/+$'), '');
    for (final line in data.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 9) continue;
      final perm = parts[0];
      final isDir = perm.startsWith('d');
      final size = int.tryParse(parts[4]) ?? 0;
      String name;
      if (parts.length > 9 && (parts[8] == '->' || parts[7] == '->')) {
        final idx = parts.indexWhere((e) => e == '->');
        name = parts.sublist(idx + 1).join(' ');
      } else {
        name = parts.sublist(8).join(' ');
      }
      if (name.isEmpty || name == '.' || name == '..') continue;
      items.add(NasFileItem(
        name: name,
        path: '$base/$name',
        isDirectory: isDir,
        size: size,
      ));
    }
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  Map<String, String>? _parsePasv(String response) {
    final match = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)')
        .firstMatch(response);
    if (match == null) return null;
    final host =
        '${match.group(1)}.${match.group(2)}.${match.group(3)}.${match.group(4)}';
    final port =
        (int.parse(match.group(5)!) << 8) + int.parse(match.group(6)!);
    return {'host': host, 'port': '$port'};
  }
}

/// FTP 控制连接辅助类。
class _FtpControl {
  _FtpControl(this.socket);

  final Socket socket;
  final _buffer = StringBuffer();

  Future<String?> readResponse() async {
    try {
      await for (final data in socket) {
        _buffer.write(utf8.decode(data));
        final s = _buffer.toString();
        if (s.contains('\r\n')) {
          final lines = s.split('\r\n');
          final last = lines.firstWhere((l) => l.length >= 3 &&
              int.tryParse(l.substring(0, 3)) != null,
              orElse: () => '');
          if (last.isNotEmpty) {
            _buffer.clear();
            _buffer.write(lines.skipWhile((l) => l != last).skip(1).join('\r\n'));
            return last;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> sendCommand(String cmd) async {
    socket.add(utf8.encode('$cmd\r\n'));
    await socket.flush();
  }

  Future<void> quit() async {
    try {
      await sendCommand('QUIT');
      await readResponse();
    } catch (_) {}
    socket.destroy();
  }
}

/// NAS 文件服务客户端 — 多连接池。
///
/// v1.0.96 之前只有一个连接槽，新增 NAS 会把上一个断开。
/// 现在改用 Map<connectionId, _NasConnection>，每个连接独立，
/// 切换不互相影响。
class NasClientService {
  NasClientService._();
  static final instance = NasClientService._();

  final Map<String, _NasConnection> _conns = {};

  /// 建立连接（返回 true/false）。
  ///
  /// ## 为什么要「验证复用」而不是无脑复用
  ///
  /// 之前的写法是：
  /// ```dart
  /// if (c != null && c.connected) return true;   // 直接信任 connected 标志
  /// ```
  ///
  /// `connected` 只表示「上次 connect 成功过」，**不代表底层连接还活着**。
  /// 典型失效场景：用户浏览目录 → 点开视频播放 → 播放器（media_kit）
  /// 用同一台 NAS 的 URL 拉流，这个过程可能把 HttpClient 里那条 keep-alive
  /// 连接用掉/半关闭。播放结束返回 NAS 主页再点连接时：
  ///   - `connected` 仍是 true → 直接 return true
  ///   - 但底层连接已废 → 紧接着的 PROPFIND 卡住或立刻失败
  ///   - UI 上就是「点了没反应」，只能杀掉 App 重来
  ///
  /// 所以复用前必须真发一次轻量请求验证。失败就重建连接。
  Future<bool> connect(NasConnection config) async {
    // 规范化路径：补前导 `/`。这里再做一次是防御 —— 上层可能忘了调，
    // 而 path 少斜杠会让 Uri 拼出 `host:portwebdav` 这种畸形地址。
    final cfg = config.copyWith(
      remotePath: normalizeRemotePath(config.remotePath),
    );
    final existing = _conns[cfg.id];
    if (existing != null && existing.connected) {
      // 轻量探测：OPTIONS 打到配置路径。超时很短，不拖慢正常流程。
      debugPrint('[NAS] 已有连接，ping 验证…');
      final alive = await existing.ping();
      if (alive) {
        debugPrint('[NAS] ping 成功，复用连接');
        return true;
      }
      debugPrint('[NAS] 复用连接已失效，重建');
      await existing.disconnect();
      _conns.remove(cfg.id);
    }

    final c = _NasConnection(cfg);
    final ok = await c.connect();
    debugPrint('[NAS] 新建连接 ${ok ? "成功" : "失败"} '
        '(${cfg.host}:${cfg.port}${cfg.remotePath})');
    _conns[cfg.id] = c;
    return ok;
  }

  /// 断开某个连接。
  Future<void> disconnect(String id) async {
    debugPrint('[NAS] disconnect($id)');
    final c = _conns.remove(id);
    await c?.disconnect();
  }

  /// 断开所有连接。
  Future<void> disconnectAll() async {
    for (final c in _conns.values) {
      await c.disconnect();
    }
    _conns.clear();
  }

  /// 最近一次列目录是否**真正失败**（区别于「目录真的是空的」）。
  ///
  /// 为什么需要这个标记：`listDirectory` 内部把所有异常都 catch 掉、
  /// 返回空数组，于是调用方无法区分：
  ///  - 目录确实是空的（正常）
  ///  - 路径不对 / 401 / 404 / 超时（异常）
  ///
  /// 结果就是用户看到「连接没报错，但目录是空的」，完全无法排查。
  /// 上层应该检查这个标记，为 true 时提示具体错误而不是显示空状态。
  bool lastListFailed = false;
  String lastListError = '';

  /// 列目录。
  Future<List<NasFileItem>> listDirectory(
      String connectionId, String path) async {
    lastListFailed = false;
    lastListError = '';
    final c = _conns[connectionId];
    if (c == null) {
      lastListFailed = true;
      lastListError = '连接未建立';
      debugPrint('[NAS] listDirectory 失败: 连接 $connectionId 不存在');
      return [];
    }
    debugPrint('[NAS] listDirectory 请求: $path');
    final result = await c.listDirectory(path);
    if (c.lastError.isNotEmpty) {
      lastListFailed = true;
      lastListError = c.lastError;
      debugPrint('[NAS] listDirectory 失败: ${c.lastError}');
      c.lastError = '';
    } else {
      debugPrint('[NAS] listDirectory 成功: $path -> ${result.length} 项');
    }
    return result;
  }

  /// 获取文件播放 URL。
  String getPlayableUrl(String connectionId, String path) {
    final c = _conns[connectionId];
    if (c == null) {
      debugPrint('[NAS] getPlayableUrl 失败: 连接 $connectionId 不存在');
      return '';
    }
    final url = c.getPlayableUrl(path);
    debugPrint('[NAS] getPlayableUrl: $url');
    return url;
  }

  /// 播放该文件时需要的请求头（Basic 认证）。
  ///
  /// 与 [getPlayableUrl] 配对使用：URL 里不带密码（会进日志），
  /// 认证通过 headers 传给播放器。
  Map<String, String> playHeaders(String connectionId) {
    final c = _conns[connectionId];
    if (c == null) return const {};
    return c.playHeaders();
  }

  /// 规范化远程路径：补上前导 `/`，去掉末尾多余 `/`，去首尾空格。
  static String normalizeRemotePath(String path) {
    path = path.trim();
    if (path.isEmpty) return '/';
    if (!path.startsWith('/')) path = '/$path';
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path.isEmpty ? '/' : path;
  }
}