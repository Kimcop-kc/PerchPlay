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

  Future<bool> connect() async {
    // SMB 不走 HttpClient
    if (config.protocol != NasProtocol.smb) {
      httpClient = HttpClient();
      httpClient!.connectionTimeout = const Duration(seconds: 10);
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
    if (client == null) return [];
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
      if (resp == null) return [];
      final body = await resp.transform(utf8.decoder).join();
      return _parseWebDavMultiStatus(body);
    } catch (e) {
      debugPrint('[NAS] WebDAV list 失败: $e');
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
      final listResp = await ftp.readResponse();
      final data = await dataSocket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join();
      dataSocket.destroy();
      await ftp.quit();
      return _parseFtpList(data);
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
    return '$scheme://${c.host}:${c.port}$path';
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

  List<NasFileItem> _parseWebDavMultiStatus(String xml) {
    final items = <NasFileItem>[];
    final responsePattern = RegExp(
      r'<D:response>.*?</D:response>',
      dotAll: true,
    );
    final hrefPattern = RegExp(r'<D:href>(.*?)</D:href>', dotAll: true);
    final displayNamePattern =
        RegExp(r'<D:displayname>(.*?)</D:displayname>', dotAll: true);
    final collectionPattern = RegExp(r'<D:collection/>');
    final lengthPattern =
        RegExp(r'<D:getcontentlength>(\d+)</D:getcontentlength>');
    final modifiedPattern =
        RegExp(r'<D:getlastmodified>(.*?)</D:getlastmodified>');

    for (final m in responsePattern.allMatches(xml)) {
      final resp = m.group(0)!;
      final href = hrefPattern.firstMatch(resp)?.group(1) ?? '';
      if (href.endsWith('/') && !href.contains('?')) continue; // skip dirs

      final name = Uri.decodeFull(
          displayNamePattern.firstMatch(resp)?.group(1) ?? href.split('/').last);
      final isDir = collectionPattern.hasMatch(resp);
      final sizeStr = lengthPattern.firstMatch(resp)?.group(1) ?? '0';
      final modStr = modifiedPattern.firstMatch(resp)?.group(1);

      if (name.isEmpty || name == href.split('/').last && isDir) continue;

      items.add(NasFileItem(
        name: name,
        path: Uri.decodeFull(href),
        isDirectory: isDir,
        size: int.tryParse(sizeStr) ?? 0,
        modifiedTime: modStr != null ? DateTime.tryParse(modStr) : null,
      ));
    }
    return items;
  }

  List<NasFileItem> _parseFtpList(String data) {
    final items = <NasFileItem>[];
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
      items.add(NasFileItem(
        name: name,
        path: '/$name',
        isDirectory: isDir,
        size: size,
      ));
    }
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
  Future<bool> connect(NasConnection config) async {
    // 同 id 已有连接则复用
    var c = _conns[config.id];
    if (c != null && c.connected) return true;

    c?.disconnect();
    c = _NasConnection(config);
    final ok = await c.connect();
    _conns[config.id] = c;
    return ok;
  }

  /// 断开某个连接。
  Future<void> disconnect(String id) async {
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

  /// 列目录。
  Future<List<NasFileItem>> listDirectory(
      String connectionId, String path) async {
    final c = _conns[connectionId];
    if (c == null) return [];
    return c.listDirectory(path);
  }

  /// 获取文件播放 URL。
  String getPlayableUrl(String connectionId, String path) {
    final c = _conns[connectionId];
    if (c == null) return '';
    return c.getPlayableUrl(path);
  }
}