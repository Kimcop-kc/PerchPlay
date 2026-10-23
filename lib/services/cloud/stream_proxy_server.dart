import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 网盘串流本地代理。
///
/// ## 为什么需要它
///
/// 直接把网盘直链交给 mpv 有三个绕不过去的问题：
///
///  1. **Range 请求没法带鉴权**。mpv 自己发 `Range` 请求，它只知道 URL，
///     不会带 `Cookie` / `Referer` / 特定 `User-Agent`。而夸克/百度的 CDN
///     对每一条分块请求都校验这些头 —— 缺了就 403 或降级限速。
///  2. **拿不到 CDN 的响应头**。`Set-Cookie` 轮换、`Content-Range` 校验、
///     是否真的返回了 206，这些都发生在 mpv 内部，我们无从干预。
///  3. **没法控制并发**。mpv 默认会开多个连接抢带宽，对已经限速的网盘
///     反而更慢，而且容易被风控。
///
/// 所以这里起一个**本地 HTTP 服务**，让 mpv 连 `127.0.0.1:port`，
/// 由我们全权代理：分块拉取、逐块带鉴权、严格校验 206、失败断点重试、
/// 按实际速率自适应调整并发。
///
/// ## 参考
///
/// 分块策略与重试逻辑参考 openlist-quark-lite 的 `parallelCopy` /
/// `fetchChunk`（AGPL-3.0），移植为 Dart 并针对播放场景做了简化。
///
/// ## 用法
///
/// ```dart
/// final server = await StreamProxyServer.start(
///   resolveUrl: () => quark.getDownloadUrl(fid),   // 每次请求都重新解析
///   headers: () => quarkHeaders,                   // 最新的 Cookie 等
/// );
/// final playUrl = server.urlFor('0');              // 拿去给播放器
/// ```
class StreamProxyServer {
  StreamProxyServer._(
    this._http,
    this._resolveUrl,
    this._headers, {
    required this.singleProxy,
  });

  final HttpServer _http;

  /// 每次播放请求时调用，返回**当前**可用的直链。
  ///
  /// 刻意设计成回调而不是固定值：网盘直链有时效（几小时），
  /// 而且长视频播放过程中可能需要重新解析。
  final Future<String?> Function() _resolveUrl;

  /// 每次分块请求时调用，返回最新的请求头（Cookie 可能已被轮换）。
  final Map<String, String> Function() _headers;

  /// 是否作为「单文件代理」使用（URL 里不需要 path）。
  final bool singleProxy;

  /// 客户端连接（用于分块拉取）。与 API 请求分开，避免互相阻塞。
  final HttpClient _cdn = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    // 单连接最多保持 8 个到 CDN 的复用连接
    ..maxConnectionsPerHost = 8;

  /// 当前端口。
  int get port => _http.port;

  /// 播放器应使用的 URL。
  ///
  /// [path] 只在 [singleProxy] 为 false 时参与拼接。
  String urlFor([String path = '']) =>
      'http://127.0.0.1:$port/${singleProxy ? '' : path}';

  /// 启动一个只服务单个文件的代理。
  static Future<StreamProxyServer> start({
    required Future<String?> Function() resolveUrl,
    required Map<String, String> Function() headers,
  }) async {
    // 绑定 loopback，端口交给系统分配（避免和用户其他服务撞端口）
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = StreamProxyServer._(
      http,
      resolveUrl,
      headers,
      singleProxy: true,
    );
    server._listen();
    return server;
  }

  void _listen() {
    _http.listen((req) async {
      try {
        await _handle(req);
      } catch (e, st) {
        debugPrint('[Stream] 处理请求异常: $e\n$st');
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    }, onError: (e) {
      debugPrint('[Stream] server error: $e');
    });
  }

  Future<void> stop() async {
    try {
      await _http.close(force: true);
    } catch (_) {}
    try {
      _cdn.close(force: true);
    } catch (_) {}
  }

  // ─────────────────────────── 请求处理 ───────────────────────────

  Future<void> _handle(HttpRequest req) async {
    if (req.method != 'GET' && req.method != 'HEAD') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return;
    }

    // 解析直链（每次请求都重新取，直链会过期）
    final target = await _resolveUrl();
    if (target == null || target.isEmpty) {
      debugPrint('[Stream] 取不到直链');
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
      return;
    }

    // 先探一次真实大小/是否支持 Range。
    // 注意：不能假设 CDN 一定支持 Range —— 有网盘会忽略 Range 直接回 200
    // 全量内容，那样分块拉取就没意义了。
    final meta = await _probe(target);
    if (meta == null) {
      req.response.statusCode = HttpStatus.badGateway;
      await req.response.close();
      return;
    }

    final size = meta.$1;
    final supportsRange = meta.$2;
    final contentType = meta.$3;

    // 解析客户端要的区间
    final range = _parseRange(req.headers.value('range'), size);

    final respHeaders = req.response.headers;
    respHeaders.set('Content-Type',
        contentType.isEmpty ? 'application/octet-stream' : contentType);
    respHeaders.set('Accept-Ranges', 'bytes');
    respHeaders.set('Connection', 'keep-alive');

    int start;
    int end;
    if (range == null) {
      start = 0;
      end = size > 0 ? size - 1 : 0;
    } else {
      start = range.$1;
      end = range.$2;
    }

    final length = start <= end ? (end - start + 1) : 0;
    respHeaders.set('Content-Length', '$length');

    if (range != null) {
      respHeaders.set(
          'Content-Range', 'bytes $start-$end/${size > 0 ? size : '*'}');
      req.response.statusCode = HttpStatus.partialContent;
    } else {
      req.response.statusCode = HttpStatus.ok;
    }

    if (req.method == 'HEAD') {
      await req.response.close();
      return;
    }

    // 不支持 Range 的源：只能一次性整段转发，没有并行分块的余地
    if (!supportsRange) {
      await _streamWhole(target, req.response);
      return;
    }

    await _streamChunked(target, req.response, start, end);
  }

  /// 探测文件大小 / Range 支持 / Content-Type。
  ///
  /// 返回 `(size, supportsRange, contentType)`，失败返回 null。
  Future<(int, bool, String)?> _probe(String target) async {
    try {
      final req = await _cdn.openUrl('GET', Uri.parse(target));
      _headers().forEach(req.headers.set);
      // 只要 1 字节，用于探 Content-Range
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final resp = await req.close();
      final ct = resp.headers.contentType?.mimeType ?? '';
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final total = _totalFromContentRange(cr);
      // 丢掉这个探针响应体
      await resp.drain<void>();

      if (resp.statusCode == HttpStatus.partialContent && total > 0) {
        return (total, true, ct);
      }
      if (resp.statusCode == HttpStatus.ok) {
        final len = resp.contentLength;
        return (len >= 0 ? len : 0, false, ct);
      }
      debugPrint('[Stream] 探测失败 HTTP ${resp.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[Stream] 探测异常: $e');
      return null;
    }
  }

  /// 从 `bytes 0-0/12345` 里拿出总长度。
  static int _totalFromContentRange(String? v) {
    if (v == null || v.isEmpty) return 0;
    final slash = v.lastIndexOf('/');
    if (slash < 0) return 0;
    return int.tryParse(v.substring(slash + 1).trim()) ?? 0;
  }

  /// 解析 Range 头，返回 `(start, end)`；无 Range 或非法返回 null。
  ///
  /// 只支持单区间（`bytes=a-b`），多区间在播放器场景不会出现。
  static (int, int)? _parseRange(String? value, int size) {
    if (value == null || value.isEmpty) return null;
    if (!value.startsWith('bytes=')) return null;
    final spec = value.substring(6);
    if (spec.contains(',')) return null;
    final dash = spec.indexOf('-');
    if (dash < 0) return null;

    final startStr = spec.substring(0, dash).trim();
    final endStr = spec.substring(dash + 1).trim();

    if (startStr.isEmpty) {
      // 后缀区间：bytes=-500 表示最后 500 字节
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0 || size <= 0) return null;
      final s = math.max(0, size - suffix);
      return (s, size - 1);
    }

    final start = int.tryParse(startStr);
    if (start == null || start < 0) return null;
    int end;
    if (endStr.isEmpty) {
      if (size <= 0) return null;
      end = size - 1;
    } else {
      final e = int.tryParse(endStr);
      if (e == null || e < start) return null;
      end = e;
    }
    if (size > 0 && end >= size) end = size - 1;
    if (start > end) return null;
    return (start, end);
  }

  /// 分块并行拉取，按序写回客户端。
  ///
  /// 核心是**按序消费 + 提前预取**：第 N 块还在下载时就先把 N+1、N+2
  /// 启动起来，这样客户端读第 N 块时后面的数据已经在路上。
  /// 并发数按「等第 N 块的实际耗时」自适应：等太久说明带宽有余量 → 加并发；
  /// 等太少说明已经跑满 → 减并发。这个策略直接搬自 quark-lite。
  Future<void> _streamChunked(
    String target,
    HttpResponse out,
    int start,
    int end,
  ) async {
    const chunkSize = 2 * 1024 * 1024; // 2MB
    final total = end - start + 1;
    if (total <= 0) {
      await out.close();
      return;
    }
    final chunkCount = (total + chunkSize - 1) ~/ chunkSize;

    // 小文件不值得并行（<= 2 块），直接顺序拉
    final maxParallel = chunkCount <= 2 ? 1 : 6;

    final pending = <int, _ChunkPipe>{};
    var concurrency = math.min(2, maxParallel);
    var nextToLaunch = 0;
    var stableChunks = 0;

    void launch(int index) {
      final cs = start + index * chunkSize;
      final ce = math.min(cs + chunkSize - 1, end);
      final pipe = _ChunkPipe(ce - cs + 1);
      pending[index] = pipe;
      unawaited(_fetchChunk(target, cs, ce, pipe));
    }

    for (; nextToLaunch < concurrency && nextToLaunch < chunkCount;
        nextToLaunch++) {
      launch(nextToLaunch);
    }

    try {
      for (var index = 0; index < chunkCount; index++) {
        final pipe = pending[index];
        if (pipe == null) {
          // 理论上不会发生：所有块都按序预取
          break;
        }
        // 把这一块的数据顺次写给客户端
        await for (final data in pipe.stream) {
          out.add(data);
          await out.flush();
        }
        if (pipe.error != null) {
          debugPrint('[Stream] 第 $index 块失败: ${pipe.error}');
          break;
        }
        pending.remove(index);

        // 自适应并发（与 quark-lite 相同的判据）
        final waited = pipe.waited;
        if (waited > const Duration(milliseconds: 100) &&
            concurrency < maxParallel) {
          concurrency++;
          stableChunks = 0;
        } else if (waited < const Duration(milliseconds: 10)) {
          stableChunks++;
          if (stableChunks >= 4 && concurrency > 1) {
            concurrency--;
            stableChunks = 0;
          }
        } else {
          stableChunks = 0;
        }

        // 保持「已预取块数」不超过当前并发
        while (nextToLaunch < chunkCount &&
            nextToLaunch - (index + 1) < concurrency) {
          launch(nextToLaunch);
          nextToLaunch++;
        }
      }
    } finally {
      // 客户端提前断开（换片/拖动）时，把还在跑的块通知停止
      for (final p in pending.values) {
        p.closeWithError(null);
      }
    }

    try {
      await out.close();
    } catch (_) {}
  }

  /// 拉取一个分块，边下边推给 [_ChunkPipe]。
  ///
  /// 每个块最多重试 4 次，且**从已读位置继续**（断点恢复），
  /// 不是整块重来 —— 大块下到 90% 断线时这个差别很大。
  Future<void> _fetchChunk(
    String target,
    int start,
    int end,
    _ChunkPipe pipe,
  ) async {
    var position = start;
    Object? finalErr;

    for (var attempt = 0; attempt < 4 && position <= end; attempt++) {
      HttpClientResponse? resp;
      try {
        final req = await _cdn.openUrl('GET', Uri.parse(target));
        _headers().forEach(req.headers.set);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$position-$end');
        resp = await req.close();

        // 严格校验 206。
        // 如果 CDN 忽略 Range 返回 200，说明它不支持分块 —— 这时
        // 继续读会拿到「从头开始」的数据，内容错位。必须当失败处理。
        if (resp.statusCode != HttpStatus.partialContent) {
          finalErr =
              'CDN 忽略 Range ($position-$end): HTTP ${resp.statusCode}';
          debugPrint('[Stream] $finalErr');
          await resp.drain<void>();
          resp = null;
          await Future<void>.delayed(
              Duration(milliseconds: 200 * (attempt + 1)));
          continue;
        }

        var read = 0;
        final want = end - position + 1;
        await for (final data in resp) {
          if (pipe.isClosed) break;
          final remain = want - read;
          if (remain <= 0) break;
          final Uint8List piece;
          if (data.length <= remain) {
            piece = data is Uint8List ? data : Uint8List.fromList(data);
          } else {
            final base = data is Uint8List ? data : Uint8List.fromList(data);
            piece = Uint8List.sublistView(base, 0, remain);
          }
          read += piece.length;
          pipe.add(piece);
        }
        position += read;

        if (position == end + 1) {
          finalErr = null;
          break;
        }
        // 短读：连接中途断了，从当前位置续
        finalErr = '分块短读，停在 $position/$end';
        debugPrint('[Stream] $finalErr (attempt $attempt)');
      } catch (e) {
        finalErr = e;
        debugPrint('[Stream] 分块异常 (attempt $attempt): $e');
      } finally {
        try {
          await resp?.drain<void>();
        } catch (_) {}
      }

      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }

    pipe.closeWithError(position > end ? null : finalErr);
  }

  /// 源不支持 Range 时的整段转发。
  Future<void> _streamWhole(String target, HttpResponse out) async {
    HttpClientResponse? resp;
    try {
      final req = await _cdn.openUrl('GET', Uri.parse(target));
      _headers().forEach(req.headers.set);
      resp = await req.close();
      await resp.forEach((data) async {
        out.add(data);
      });
      await out.flush();
    } catch (e) {
      debugPrint('[Stream] 整段转发失败: $e');
    } finally {
      try {
        await resp?.drain<void>();
      } catch (_) {}
      try {
        await out.close();
      } catch (_) {}
    }
  }
}

/// 一个分块的缓冲管道：拉取端 `add`，消费端用 [stream] 读。
///
/// 用 [StreamController] 而不是自己写环形缓冲，是因为播放器消费速度
/// 由 mpv 决定，Stream 的背压天然合适；而且 `await for` 读起来简单。
class _ChunkPipe {
  _ChunkPipe(int expected)
      : _expected = expected,
        _startedAt = DateTime.now();

  /// 这个块应该有多少字节（用于诊断短读）。
  final int _expected;
  int _received = 0;

  /// 实际收到的字节数（诊断用）。
  int get received => _received;

  /// 该块是否完整收到。
  bool get isComplete => _received >= _expected;

  final StreamController<Uint8List> _ctl =
      StreamController<Uint8List>();
  final DateTime _startedAt;

  /// 从创建到「第一块数据真正被消费」之间的等待时长。
  ///
  /// 用于自适应并发：等得久说明还能更快，等得短说明已经跑满。
  Duration waited = Duration.zero;

  Object? error;
  bool _closed = false;
  bool get isClosed => _closed;

  Stream<Uint8List> get stream => _ctl.stream;

  void add(Uint8List data) {
    if (_closed || _ctl.isClosed) return;
    _received += data.length;
    _ctl.add(data);
  }

  void closeWithError(Object? err) {
    if (_closed) return;
    _closed = true;
    error = err;
    // 第一次被消费时记录等待时长
    if (waited == Duration.zero) {
      waited = DateTime.now().difference(_startedAt);
    }
    if (!_ctl.isClosed) _ctl.close();
  }
}
