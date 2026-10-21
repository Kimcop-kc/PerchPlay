import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/nas_connection_model.dart';

/// 局域网 NAS 自动发现
///
/// 扫描本机所在 /24 网段的一小组特征端口：
/// - 5000/5001 群晖 DSM、8080/8443 威联通 QTS、80/443/5005/5006 通用 WebDAV
/// - 21 FTP、445 SMB、548 AFP
/// 对 HTTP 类端口读页面标题/Server 头识别品牌，并对候选端口发 PROPFIND
/// 判断是否真的支持 WebDAV（可直接用），避免给出连不上的建议。
class NasDiscoveryService {
  NasDiscoveryService._();
  static final instance = NasDiscoveryService._();

  /// 特征端口 → 说明
  static const Map<int, String> probePorts = {
    5000: '群晖 DSM',
    5001: '群晖 DSM (HTTPS)',
    8080: '威联通 QTS / 通用',
    8443: '威联通 QTS (HTTPS)',
    80: 'Web / WebDAV',
    443: 'Web / WebDAV (HTTPS)',
    5005: 'WebDAV',
    5006: 'WebDAV (HTTPS)',
    21: 'FTP',
    445: 'SMB',
  };

  bool _running = false;
  bool get isRunning => _running;

  /// 本机网段（优先 wlan/wifi，避免拿到蜂窝/VPN）
  Future<String?> localSubnet() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
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
          if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
          final parts = a.address.split('.');
          if (parts.length == 4) return '${parts[0]}.${parts[1]}.${parts[2]}';
        }
      }
    } catch (e) {
      debugPrint('[NasDiscovery] subnet error: $e');
    }
    return null;
  }

  /// 是否已接入局域网（用于判断“扫不到”是没网还是真没有 NAS）
  Future<bool> hasLocalNetwork() async => (await localSubnet()) != null;

  /// 扫描局域网，返回发现的 NAS 候选
  ///
  /// [subnet] 可指定网段（测试用，如 '127.0.0'），
  /// [hosts] 可指定只扫某些主机（测试用）。
  Future<List<NasCandidate>> discover({
    String? subnet,
    List<String>? hosts,
    List<int>? ports,
    Duration timeout = const Duration(milliseconds: 260),
    void Function(int done, int total)? onProgress,
  }) async {
    if (_running) return const [];
    _running = true;
    final found = <NasCandidate>[];
    try {
      final net = subnet ?? await localSubnet();
      final targets = hosts ??
          (net == null
              ? <String>[]
              : List.generate(254, (i) => '$net.${i + 1}'));
      if (targets.isEmpty) {
        // 刚开机/刚连 Wi-Fi 时可能还没有局域网 IP：不算已扫描，
        // 交给调用方稍后重试（否则会静默什么都不做）
        debugPrint('[NasDiscovery] 暂无局域网网段，跳过本次扫描');
        return const [];
      }

      final portList = ports ?? probePorts.keys.toList();
      final jobs = <MapEntry<String, int>>[
        for (final h in targets)
          for (final p in portList) MapEntry(h, p),
      ];
      debugPrint('[NasDiscovery] 网段=$net 主机=${targets.length} '
          '端口=$portList 探测数=${jobs.length}');

      var done = 0;
      const concurrency = 96;
      for (var i = 0; i < jobs.length; i += concurrency) {
        final batch = jobs.sublist(
            i, (i + concurrency) > jobs.length ? jobs.length : i + concurrency);
        final results = await Future.wait(batch.map((job) async {
          final item = await _probe(job.key, job.value, timeout);
          done++;
          onProgress?.call(done, jobs.length);
          return item;
        }));
        for (final r in results) {
          if (r != null) {
            found.add(r);
            debugPrint('[NasDiscovery] 命中 ${r.host}:${r.port} '
                'webdav=${r.isWebDav} brand=${r.brand}');
          }
        }
        // 已找到可直接使用的 WebDAV 就不再穷举（快很多）
        if (found.any((c) => c.isWebDav)) continue;
      }

      // 只保留「确实是 NAS」或「真的能用 WebDAV」的候选：
      // 路由器/电脑上裸露的 80/445/21 端口不是 NAS，列出来只会干扰
      final usable = found.where((c) {
        if (c.isWebDav) return true;
        if (c.brand.isNotEmpty) return true;
        return false;
      }).toList();
      debugPrint('[NasDiscovery] 命中 ${found.length} 个端口，'
          '其中可用 ${usable.length} 个');

      // WebDAV 优先，其次识别出品牌的，最后只是“发现设备”
      usable.sort((a, b) {
        int rank(NasCandidate c) {
          if (c.isWebDav) return 0;
          if (c.brand.isNotEmpty) return 1;
          return 2;
        }

        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return '${a.host}:${a.port}'.compareTo('${b.host}:${b.port}');
      });
      return usable;
    } finally {
      _running = false;
    }
  }

  Future<NasCandidate?> _probe(String host, int port, Duration timeout) async {
    // 1) TCP 是否开放
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
    } catch (_) {
      return null;
    }

    // 2) HTTP 类端口：识别品牌 + 探测 WebDAV
    final isHttpLike = port != 21 && port != 445 && port != 548;
    if (!isHttpLike) {
      return NasCandidate(
        host: host,
        port: port,
        protocol: port == 21 ? NasProtocol.ftp : NasProtocol.smb,
        brand: '',
        label: probePorts[port] ?? '服务',
        isWebDav: false,
      );
    }

    final scheme = (port == 443 || port == 5001 || port == 8443 || port == 5006)
        ? 'https'
        : 'http';
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 900)
      ..badCertificateCallback = (_, __, ___) => true;

    String brand = '';
    var webDav = false;
    try {
      // WebDAV 探测（207 = 是 WebDAV 服务）
      final davReq =
          await client.openUrl('PROPFIND', Uri.parse('$scheme://$host:$port/'));
      davReq.headers.set('Depth', '0');
      davReq.headers.set('User-Agent', 'PerchPlay/1.0');
      // 独立连接：很多 NAS 在一条连接上处理完一个请求就关掉，
      // 复用 keep-alive 会让紧随其后的 GET 直接失败（品牌识别不到）
      davReq.headers.set(HttpHeaders.connectionHeader, 'close');
      final davRes = await davReq.close().timeout(const Duration(seconds: 2));
      await davRes.drain<void>();
      // 注意：必须用 [] 取头。value() 在服务端发重复头时会抛异常，
      // 而重复 Server/DAV 头在真实 NAS 上很常见。
      if (davRes.statusCode == 207 ||
          (davRes.headers['dav']?.isNotEmpty ?? false)) {
        webDav = true;
      }
    } catch (_) {}

    try {
      final req = await client.getUrl(Uri.parse('$scheme://$host:$port/'));
      req.headers.set('User-Agent', 'PerchPlay/1.0');
      req.headers.set(HttpHeaders.connectionHeader, 'close');
      final res = await req.close().timeout(const Duration(seconds: 2));
      final server = (res.headers[HttpHeaders.serverHeader] ?? const [])
          .join(' ')
          .toLowerCase();
      final bodyBytes = <int>[];
      await for (final chunk in res) {
        bodyBytes.addAll(chunk);
        if (bodyBytes.length > 8192) break;
      }
      final body = utf8.decode(bodyBytes, allowMalformed: true);
      brand = _detectBrand(server, body);
    } catch (_) {
      // HTTPS 自签/无 HTTP 服务：忽略
    } finally {
      client.close(force: true);
    }

    // 只有 WebDAV 才建议直接连接；否则仅提示“发现了设备”
    final protocol = webDav
        ? NasProtocol.webdav
        : (port == 5001 || port == 8443 || port == 5006
            ? NasProtocol.webdav
            : NasProtocol.webdav);
    return NasCandidate(
      host: host,
      port: port,
      protocol: protocol,
      brand: brand,
      label: webDav
          ? '${brand.isEmpty ? 'WebDAV' : brand} · WebDAV 可用'
          : (brand.isEmpty ? (probePorts[port] ?? '服务') : brand),
      isWebDav: webDav,
    );
  }

  /// 从 Server 头与页面内容识别品牌（覆盖常见品牌 + 主流自建）
  String _detectBrand(String server, String body) {
    final b = body.toLowerCase();
    bool has(String s) => b.contains(s);
    if (has('synology') || has('diskstation') || server.contains('synology')) {
      return '群晖 Synology';
    }
    if (has('qnap') || has('qts') || server.contains('qnap')) return '威联通 QNAP';
    if (has('truenas') || has('freenas')) return 'TrueNAS';
    if (has('openmediavault')) return 'OpenMediaVault';
    if (has('unraid')) return 'Unraid';
    if (has('fnos') || has('飞牛')) return '飞牛 fnOS';
    if (has('zspace') || has('极空间')) return '极空间';
    if (has('istoreos') || has('istore')) return 'iStoreOS';
    if (has('wd my cloud') || has('mycloud')) return 'WD My Cloud';
    if (has('terramaster') || has('tos ')) return '铁威马 TerraMaster';
    if (has('asustor')) return 'Asustor';
    if (has('dlink') || has('d-link')) return 'D-Link';
    if (has('webdav') || has('dav')) return 'WebDAV 服务';
    if (server.contains('nginx')) return 'NAS（nginx）';
    if (server.contains('apache')) return 'NAS（Apache）';
    return '';
  }
}

/// 发现到的 NAS 候选
class NasCandidate {
  final String host;
  final int port;
  final NasProtocol protocol;
  final String brand;
  final String label;

  /// 是否确认支持 WebDAV（可直接连接使用）
  final bool isWebDav;

  const NasCandidate({
    required this.host,
    required this.port,
    required this.protocol,
    required this.brand,
    required this.label,
    required this.isWebDav,
  });

  String get address => '$host:$port';
}
