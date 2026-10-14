import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  bool _connected = false;
  bool get isConnected => _connected;

  // ──────────── 连接 ────────────

  Future<bool> connect(NasConnection config) async {
    _connection = config;
    _httpClient = HttpClient();
    _httpClient!.connectionTimeout = const Duration(seconds: 10);

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

  Future<void> disconnect() {
    _httpClient?.close();
    _httpClient = null;
    _connection = null;
    _connected = false;
    return Future.value();
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
      req.headers.set('User-Agent', 'VidFlow/1.0 WebDAV');
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

  // ──────────── SMB ────────────

  Future<bool> _connectSmb() async {
    // SMB 使用 smb2 客户端
    // 由于 Dart 没有原生 SMB 库，通过方法通道调用原生 SMB
    // 这里提供 WebDAV fallback: 很多 NAS 同时有 WebDAV
    try {
      // 尝试用 HTTP 探测（部分 NAS 的 SMB share 也暴露 HTTP）
      final uri = Uri.parse('http://${_connection!.host}:5000/');
      final req = await _httpClient!.getUrl(uri);
      req.headers.set('User-Agent', 'VidFlow/1.0');
      final res = await req.close();
      _connected = res.statusCode == 200 || res.statusCode == 401;
      return _connected;
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
          return await _listWebDav(path); // fallback
        default:
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
    req.headers.set('User-Agent', 'VidFlow/1.0 WebDAV');
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

    // 简单解析 WebDAV multistatus XML
    final responsePattern =
        RegExp(r'<D:response>(.*?)</D:response>', dotAll: true);
    final hrefPattern = RegExp(r'<D:href>(.*?)</D:href>');
    final displayNamePattern =
        RegExp(r'<D:displayname>(.*?)</D:displayname>');
    final collectionPattern = RegExp(r'<D:resourcetype>.*?<D:collection');
    final sizePattern = RegExp(r'<D:getcontentlength>(.*?)</D:getcontentlength>');
    final modifiedPattern =
        RegExp(r'<D:getlastmodified>(.*?)</D:getlastmodified>');

    for (final match in responsePattern.allMatches(xml)) {
      final block = match.group(1)!;
      final href = hrefPattern.firstMatch(block)?.group(1) ?? '';
      final name = displayNamePattern.firstMatch(block)?.group(1) ?? '';
      final isDir = collectionPattern.hasMatch(block);

      // 跳过自身
      final decodedHref = Uri.decodeFull(href).trimRight('/');
      final decodedPath = Uri.decodeFull(currentPath).trimRight('/');
      if (decodedHref == decodedPath) continue;

      final sizeStr = sizePattern.firstMatch(block)?.group(1) ?? '0';
      final size = int.tryParse(sizeStr) ?? 0;
      final modifiedStr =
          modifiedPattern.firstMatch(block)?.group(1);
      DateTime? modified;
      if (modifiedStr != null) {
        modified = DateTime.tryParse(modifiedStr);
      }

      final displayName = name.isNotEmpty ? name : href.split('/').last;
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

    // 去重
    final seen = <String>{};
    return items.where((item) => seen.add(item.path)).toList();
  }

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

        // 解析 UNIX ls 格式
        for (final line in listData.split('\n')) {
          final item = _parseFtpListLine(line.trim());
          if (item != null) items.add(item);
        }
      }

      socket.write('QUIT\r\n');
      socket.destroy();
    } catch (_) {}

    return items;
  }

  NasFileItem? _parseFtpListLine(String line) {
    if (line.isEmpty || line.startsWith('total')) return null;

    // drwxr-xr-x  2 user group    4096 Jan 1 12:00 filename
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 9) return null;

    final isDir = parts[0].startsWith('d');
    final sizeStr = parts[4];
    final size = int.tryParse(sizeStr) ?? 0;
    final name = parts.sublist(8).join(' ');

    final ext = name.contains('.')
        ? '.${name.split('.').last.toLowerCase()}'
        : '';

    return NasFileItem(
      name: name,
      path: name,
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

  Future<String> _readFtpResponse(Socket socket) async {
    return await socket
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
  }

  Future<String> _readAll(Socket socket) async {
    final completer = Completer<String>();
    final buffer = StringBuffer();
    socket.transform(utf8.decoder).listen(
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