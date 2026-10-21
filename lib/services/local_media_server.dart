import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// 投屏用的本地媒体服务器
///
/// 投屏设备（电视/盒子）无法访问手机上的 `/storage/emulated/0/...` 路径，
/// 必须由手机起一个 HTTP 服务把文件暴露到局域网，再把 URL 交给设备。
/// 支持 Range 请求（拖动进度必须）。
class LocalMediaServer {
  LocalMediaServer._();
  static final instance = LocalMediaServer._();

  HttpServer? _server;
  File? _currentFile;
  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// 本机在局域网里的 IPv4（投屏 URL 用它，不能用 127.0.0.1）
  Future<String?> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      // 优先 wlan/wifi 接口，避免拿到蜂窝/VPN 网段
      final sorted = interfaces.toList()
        ..sort((a, b) {
          int score(NetworkInterface i) {
            final n = i.name.toLowerCase();
            if (n.contains('wlan') || n.contains('wifi')) return 0;
            if (n.contains('eth')) return 1;
            return 2;
          }

          return score(a).compareTo(score(b));
        });
      for (final i in sorted) {
        for (final a in i.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4) {
            return a.address;
          }
        }
      }
    } catch (e) {
      debugPrint('[MediaServer] localIp error: $e');
    }
    return null;
  }

  /// 启动服务（幂等）
  Future<bool> start() async {
    if (_server != null) return true;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      server.listen(_handle, onError: (e) {
        debugPrint('[MediaServer] listen error: $e');
      });
      debugPrint('[MediaServer] listening on ${server.port}');
      return true;
    } catch (e) {
      debugPrint('[MediaServer] start failed: $e');
      _server = null;
      return false;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _currentFile = null;
  }

  /// 把本地视频暴露成 HTTP URL
  Future<String?> urlFor(String filePath, {String? title}) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    if (!await start()) return null;
    _currentFile = file;
    final ip = await localIp();
    if (ip == null) return null;
    final name = Uri.encodeComponent(title ?? file.uri.pathSegments.last);
    return 'http://$ip:${_server!.port}/video/$name';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final file = _currentFile;
      if (file == null || !await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final length = await file.length();
      final range = request.headers.value(HttpHeaders.rangeHeader);

      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.contentType =
          ContentType('video', 'mp4', charset: 'utf-8');
      request.response.headers.set('transferMode.dlna.org', 'Streaming');
      request.response.headers
          .set('contentFeatures.dlna.org', 'DLNA.ORG_OP=01;DLNA.ORG_CI=0');

      var start = 0;
      var end = length - 1;

      if (range != null && range.startsWith('bytes=')) {
        final spec = range.substring(6).split(',').first.trim();
        final dash = spec.indexOf('-');
        if (dash >= 0) {
          final s = spec.substring(0, dash);
          final e = spec.substring(dash + 1);
          if (s.isNotEmpty) {
            start = int.tryParse(s) ?? 0;
            if (e.isNotEmpty) end = int.tryParse(e) ?? end;
          } else if (e.isNotEmpty) {
            // bytes=-N → 最后 N 字节
            start = (length - (int.tryParse(e) ?? 0)).clamp(0, length - 1);
          }
        }
      }
      if (start >= length) start = 0;
      if (end >= length) end = length - 1;
      if (end < start) end = start;

      final isPartial = range != null;
      request.response.statusCode =
          isPartial ? HttpStatus.partialContent : HttpStatus.ok;
      request.response.headers.contentLength = end - start + 1;
      if (isPartial) {
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }

      final raf = await file.open();
      await raf.setPosition(start);
      var remaining = end - start + 1;
      const chunk = 64 * 1024;
      while (remaining > 0) {
        final size = remaining > chunk ? chunk : remaining;
        final bytes = await raf.read(size);
        if (bytes.isEmpty) break;
        request.response.add(bytes);
        remaining -= bytes.length;
      }
      await raf.close();
      await request.response.close();
    } catch (e) {
      debugPrint('[MediaServer] handle error: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}
