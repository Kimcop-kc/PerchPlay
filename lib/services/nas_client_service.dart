import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import '../models/nas_connection_model.dart';

/// NAS 文件服务客户端
/// 支持 SMB / FTP / WebDAV 三种协议
class NasClientService {
  NasClientService._();
  static final instance = NasClientService._();

  NasConnection? _connection;
  NasConnection? get connection => _connection;

  HttpClient? _httpClient;

  /// SMB2/3 连接池（基于 libsmb2，走 worker isolate，不阻塞 UI）
  Smb2Pool? _smbPool;

  bool _connected = false;
  bool get isConnected => _connected;

  // ──────────── 连接 ────────────

  Future<bool> connect(NasConnection config) async {
    _connection = config;
    // SMB 不走 HttpClient，避免无谓的资源占用
    if (config.protocol != NasProtocol.smb) {
      _httpClient = HttpClient();
      _httpClient!.connectionTimeout = const Duration(seconds: 10);
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
          return false; // NFS 需要 kernel 支持，不通过 Dart 实现
      }
    } catch (e) {
      debugPrint('[NAS] connect error: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    _httpClient?.close();
    _httpClient = null;
    try {
      await _smbPool?.disconnect();
    } catch (_) {}
    _smbPool = null;
    _connection = null;
    _connected = false;
  }

  // ──────────── SMB2/3 ────────────

  /// SMB 连接。
  ///
  /// 用 [Smb2Pool] 而不是单连接客户端：它会在 worker isolate 里跑，
  /// 目录遍历/读文件不会卡住 UI（大目录尤其明显）。
  ///
  /// 关键约定：
  ///  - [NasConnection.shareName] 必填（SMB 必须先连到某个共享，如 `video`）
  ///  - [NasConnection.domain] 可选，Windows 域/工作组填 `WORKGROUP`
  Future<bool> _connectSmb() async {
    final c = _connection!;
    final share = c.shareName.trim();
    if (share.isEmpty) {
      debugPrint('[NAS] SMB 缺少共享名（shareName），无法连接');
      _connected = false;
      return false;
    }
    try {
      await _smbPool?.disconnect();
      // 注意：dart_smb2 的 connect 没有 port 参数（固定走 445），
      // 非标准端口暂不支持。
      _smbPool = await Smb2Pool.connect(
        host: c.host,
        share: share,
        user: c.username.isEmpty ? null : c.username,
        password: c.password.isEmpty ? null : c.password,
        domain: c.domain.isEmpty ? null : c.domain,
      );
      // 真正确认可用：列一次根目录
      await _smbPool!.listDirectory('');
      _connected = true;
      debugPrint('[NAS] SMB 已连接: ${c.host}/$share');
      return true;
    } catch (e) {
      debugPrint('[NAS] SMB 连接失败: $e');
      _smbPool = null;
      _connected = false;
      return false;
    }
  }

  /// 列出 SMB 目录。
  ///
  /// 路径以 `/` 开头（与 WebDAV 保持一致），内部转成 SMB 的相对路径。
  Future<List<NasFileItem>> _listSmb(String path) async {
    final pool = _smbPool;
    if (pool == null) return [];
    // '/a/b' → 'a/b'；'/' → ''
    var rel = path.trim();
    if (rel.startsWith('/')) rel = rel.substring(1);
    if (rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);

    final entries = await pool.listDirectory(rel);
    final items = <NasFileItem>[];
    for (final e in entries) {
      // 跳过 . / .. （部分服务端会返回）
      if (e.name == '.' || e.name == '..') continue;
      final childPath =
          rel.isEmpty ? '/${e.name}' : '/$rel/${e.name}';
      final st = e.stat;
      items.add(NasFileItem(
        name: e.name,
        path: childPath,
        isDirectory: e.isDirectory,
        size: e.isDirectory ? 0 : st.size,
        modifiedTime: st.modified,
      ));
    }
    return items;
  }

  /// 读取 SMB 文件全部内容（小文件用，如字幕/封面）。
  Future<Uint8List?> readSmbFile(String path) async {
    final pool = _smbPool;
    if (pool == null) return null;
    var rel = path.trim();
    if (rel.startsWith('/')) rel = rel.substring(1);
    try {
      return await pool.readFile(rel);
    } catch (e) {
      debugPrint('[NAS] SMB 读文件失败: $e');
      return null;
    }
  }

  /// 下载 SMB 文件到本地（视频播放前缓存用）。
  Future<bool> downloadSmbFile(String remotePath, String localPath) async {
    final pool = _smbPool;
    if (pool == null) return false;
    var rel = remotePath.trim();
    if (rel.startsWith('/')) rel = rel.substring(1);
    try {
      await pool.downloadToFile(rel, localPath);
      return true;
    } catch (e) {
      debugPrint('[NAS] SMB 下载失败: $e');
      return false;
    }
  }

  // ──────────── WebDAV ────────────
  Future<bool> _connectWebDav() async {
    final c = _connection!;
    final scheme = c.port == 443 ? 'https' : 'http';
    final baseUrl = '$scheme://${c.host}:${c.port}';

    try {
      final uri = Uri.parse('$baseUrl${c.remotePath}');
      final req = await _httpClient!.openUrl('PROPFIND', uri);
      req.headers.set('Depth', '1');
      req.headers.set('User-Agent', 'PerchPlay/1.0 WebDAV');
      if (c.username.isNotEmpty) {
        final auth = base64Encode(utf8.encode('${c.username}:${c.password}'));
        req.headers.set('Authorization', 'Basic $auth');
      }
      final res = await req.close();
      _connected = res.statusCode >= 200 && res.statusCode < 400 ||
          res.statusCode == 207;
      return _connected;
    } catch (_) {
      return false;
    }
  }

  // ──────────── FTP ────────────

  Future<bool> _connectFtp() async {
    final c = _connection!;
    try {
      final socket = await Socket.connect(
        c.host,
        c.port,
        timeout: const Duration(seconds: 5),
      );
      final response = await _readFtpResponse(socket);
      if (response.startsWith('220')) {
        // 登录
        socket.write('USER ${c.username}\r\n');
        await _readFtpResponse(socket);
        socket.write('PASS ${c.password}\r\n');
        final auth = await _readFtpResponse(socket);
        socket.destroy();
        _connected = auth.startsWith('230');
        return _connected;
      }
      socket.destroy();
      return false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 文件列表 ────────────

  /// 列出目录内容
  Future<List<NasFileItem>> listDirectory(String path) async {
    if (!_connected || _connection == null) return [];

    try {
      switch (_connection!.protocol) {
        case NasProtocol.webdav:
          return await _listWebDav(path);
        case NasProtocol.ftp:
          return await _listFtp(path);
        case NasProtocol.smb:
          return await _listSmb(path);
        case NasProtocol.nfs:
          // NFS 需要 kernel 支持，不通过 Dart 实现
          return [];
      }
    } catch (e) {
      debugPrint('[NAS] list error: $e');
      return [];
    }
  }

  Future<List<NasFileItem>> _listWebDav(String path) async {
    final c = _connection!;
    final scheme = c.port == 443 ? 'https' : 'http';
    final baseUrl = '$scheme://${c.host}:${c.port}';
    final uri = Uri.parse('$baseUrl$path');

    final req = await _httpClient!.openUrl('PROPFIND', uri);
    req.headers.set('Depth', '1');
    req.headers.set('User-Agent', 'PerchPlay/1.0 WebDAV');
    if (c.username.isNotEmpty) {
      final auth = base64Encode(utf8.encode('${c.username}:${c.password}'));
      req.headers.set('Authorization', 'Basic $auth');
    }

    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();

    return _parseWebDavResponse(body, path);
  }

  List<NasFileItem> _parseWebDavResponse(String xml, String currentPath) {
    final items = <NasFileItem>[];

    // 兼容带/不带命名空间前缀、任意大小写（原来硬编码 <D: 前缀，
    // 很多 NAS 用小写或默认命名空间，结果一个条目都解析不出来）
    final responseBlocks = RegExp(
            r'<(?:[A-Za-z0-9]+:)?response[^>]*>(.*?)</(?:[A-Za-z0-9]+:)?response>',
            dotAll: true,
            caseSensitive: false)
        .allMatches(xml);

    for (final match in responseBlocks) {
      final block = match.group(1) ?? '';
      final href = _decodeEntities(_tagText(block, 'href') ?? '');
      if (href.isEmpty) continue;

      final isDir = RegExp(r'<(?:[A-Za-z0-9]+:)?collection',
              caseSensitive: false)
          .hasMatch(block);

      // 跳过自身
      final decodedHref = Uri.decodeFull(href).replaceAll(RegExp(r'/$'), '');
      final decodedPath =
          Uri.decodeFull(currentPath).replaceAll(RegExp(r'/$'), '');
      if (decodedHref == decodedPath) continue;

      final size = int.tryParse(_tagText(block, 'getcontentlength') ?? '0') ?? 0;
      final modifiedStr = _tagText(block, 'getlastmodified');
      final modified =
          modifiedStr == null ? null : DateTime.tryParse(modifiedStr);

      var displayName = _tagText(block, 'displayname') ?? '';
      if (displayName.isEmpty) {
        displayName = Uri.decodeFull(href).split('/')
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
            href;
      }

      final ext = displayName.contains('.')
          ? '.${displayName.split('.').last.toLowerCase()}'
          : '';

      items.add(NasFileItem(
        name: displayName,
        path: Uri.decodeFull(href),
        isDirectory: isDir,
        size: size,
        modifiedTime: modified,
        extension: ext,
      ));
    }

    // 目录在前、再按名称排序
    items.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    // 去重
    final seen = <String>{};
    return items.where((item) => seen.add(item.path)).toList();
  }

  /// 取标签文本，容忍命名空间前缀与大小写
  String? _tagText(String xml, String name) {
    final m = RegExp(
            '<(?:[A-Za-z0-9]+:)?$name[^>]*>(.*?)</(?:[A-Za-z0-9]+:)?$name>',
            dotAll: true,
            caseSensitive: false)
        .firstMatch(xml);
    return m?.group(1)?.trim();
  }

  String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  Future<List<NasFileItem>> _listFtp(String path) async {
    final c = _connection!;
    final items = <NasFileItem>[];

    try {
      final socket = await Socket.connect(
        c.host,
        c.port,
        timeout: const Duration(seconds: 5),
      );
      await _readFtpResponse(socket);

      // 登录
      socket.write('USER ${c.username}\r\n');
      await _readFtpResponse(socket);
      socket.write('PASS ${c.password}\r\n');
      await _readFtpResponse(socket);

      // PASV 模式
      socket.write('PASV\r\n');
      final pasvResponse = await _readFtpResponse(socket);
      final pasvData = _parsePasv(pasvResponse);

      if (pasvData != null) {
        final dataSocket = await Socket.connect(
          pasvData['host'],
          pasvData['port'],
          timeout: const Duration(seconds: 5),
        );

        socket.write('LIST $path\r\n');
        await _readFtpResponse(socket);

        // 读数据
        final listData = await _readAll(dataSocket);
        dataSocket.destroy();

        // 解析 UNIX ls 格式（子项路径要拼上父目录，否则进目录后路径全错）
        for (final line in listData.split('\n')) {
          final item = _parseFtpListLine(line.trim(), path);
          if (item != null) items.add(item);
        }
      }

      socket.write('QUIT\r\n');
      socket.destroy();
    } catch (_) {}

    return items;
  }

  NasFileItem? _parseFtpListLine(String line, String parentPath) {
    if (line.isEmpty || line.startsWith('total')) return null;

    // drwxr-xr-x  2 user group    4096 Jan 1 12:00 filename
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 9) return null;

    final isDir = parts[0].startsWith('d');
    final sizeStr = parts[4];
    final size = int.tryParse(sizeStr) ?? 0;
    final name = parts.sublist(8).join(' ');
    if (name == '.' || name == '..') return null;

    // 拼出完整路径（父目录 + 名称），否则进子目录后请求路径是错的
    final base = parentPath.endsWith('/')
        ? parentPath.substring(0, parentPath.length - 1)
        : parentPath;
    final fullPath = '$base/$name';

    final ext = name.contains('.')
        ? '.${name.split('.').last.toLowerCase()}'
        : '';

    return NasFileItem(
      name: name,
      path: fullPath,
      isDirectory: isDir,
      size: size,
      extension: ext,
    );
  }

  // ──────────── 生成可播放 URL ────────────

  /// 为远程文件生成可直接播放的 URL
  String getPlayableUrl(String path) {
    if (_connection == null) return path;

    final c = _connection!;
    switch (c.protocol) {
      case NasProtocol.webdav:
        final scheme = c.port == 443 ? 'https' : 'http';
        final auth = '${c.username}:${c.password}';
        // 将认证嵌入 URL（media_kit 支持）
        final encodedPath = path.startsWith('/') ? path : '/$path';
        return '$scheme://$auth@${c.host}:${c.port}$encodedPath';

      case NasProtocol.ftp:
        final encodedPath = path.startsWith('/') ? path : '/$path';
        return 'ftp://${c.username}:${c.password}@${c.host}:${c.port}$encodedPath';

      case NasProtocol.smb:
        final encodedPath = path.replaceAll('\\', '/');
        return 'smb://${c.username}:${c.password}@${c.host}$encodedPath';

      default:
        return path;
    }
  }

  // ──────────── FTP 工具 ────────────

  /// 读一条完整的 FTP 响应（多行响应以 "220-..." 开头，
  /// 直到 "220 " 这种 3 位码+空格的行才算结束；原来只读第一行会错位）
  Future<String> _readFtpResponse(Socket socket) async {
    final lines = <String>[];
    await for (final line in socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      lines.add(line);
      if (RegExp(r'^\d{3} ').hasMatch(line)) break;
    }
    return lines.join('\n');
  }

  Future<String> _readAll(Socket socket) async {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    socket.cast<List<int>>().transform(utf8.decoder).listen(
      buffer.write,
      onDone: () => completer.complete(buffer.toString()),
      onError: (e) => completer.complete(buffer.toString()),
    );
    // 超时
    Future.delayed(const Duration(seconds: 2), () {
      if (!completer.isCompleted) completer.complete(buffer.toString());
    });
    return completer.future;
  }

  Map<String, dynamic>? _parsePasv(String response) {
    // 227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)
    final match = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)')
        .firstMatch(response);
    if (match == null) return null;

    final host =
        '${match.group(1)}.${match.group(2)}.${match.group(3)}.${match.group(4)}';
    final port = (int.parse(match.group(5)!) << 8) + int.parse(match.group(6)!);

    return {'host': host, 'port': port};
  }
}
