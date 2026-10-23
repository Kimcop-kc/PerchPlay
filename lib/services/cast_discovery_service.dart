import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/cast_device_model.dart';
import 'native_bridge_service.dart';

/// 投屏设备发现服务
/// 支持: DLNA (SSDP) / Chromecast (mDNS) / AirPlay (mDNS) / Miracast
class CastDiscoveryService {
  CastDiscoveryService._();
  static final instance = CastDiscoveryService._();

  final _devices = <String, CastDevice>{};
  RawDatagramSocket? _ssdpSocket;
  StreamSubscription? _ssdpSubscription;
  Timer? _ssdpTimer;
  Timer? _cleanupTimer;

  final _deviceController = StreamController<CastDevice>.broadcast();
  Stream<CastDevice> get deviceStream => _deviceController.stream;

  List<CastDevice> get devices => _devices.values.toList();
  bool _running = false;

  // ──────────── SSDP (DLNA) 发现 ────────────

  static const _ssdpMulticastAddr = '239.255.255.250';
  static const _ssdpPort = 1900;

  /// 启动设备发现
  Future<void> startDiscovery() async {
    if (_running) return;
    _running = true;

    // Android 必须持有 Wi-Fi 组播锁，否则组播包会被系统丢弃，
    // SSDP 响应收不到 → 设备列表永远是空的
    await NativeBridgeService.instance.acquireMulticastLock();

    // iOS 14+：任何局域网访问（组播/TCP 探测）都要先拿到「本地网络」权限。
    // 系统只会在**第一次真正发起局域网连接**时弹窗；如果用户当时点了拒绝，
    // 之后所有探测都会静默失败、设备列表恒为空，且不会再弹窗。
    // 这里先做一次「明确会触达局域网」的探测，让权限弹窗在进入投屏页时
    // 立刻出现（而不是藏在后台的 SSDP 里，用户根本不知道有东西在等授权）。
    if (!kIsWeb && Platform.isIOS) {
      await _warmUpLocalNetworkPermission();
    }

    await _startSsdp();
    await _scanMdns();

    // 定期刷新 SSDP
    _ssdpTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_running) _sendSsdpSearch();
    });

    // 清理过期设备（60s 未见则标记断连）
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _cleanStaleDevices();
    });
  }

  /// iOS：触发本地网络权限弹窗。
  ///
  /// 做法是主动向组播地址发一个 SSDP 包并尝试短连接——这会命中 iOS 的
  /// 本地网络权限检查，从而弹出系统授权框。失败无所谓（用户可能已授权、
  /// 也可能拒绝），后续真实探测会拿到正确结果。
  Future<void> _warmUpLocalNetworkPermission() async {
    try {
      final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      probe.broadcastEnabled = true;
      try {
        probe.send(
          'M-SEARCH * HTTP/1.1\r\n'
                  'HOST: $_ssdpMulticastAddr:$_ssdpPort\r\n'
                  'MAN: "ssdp:discover"\r\n'
                  'MX: 1\r\n'
                  'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
                  '\r\n'
              .codeUnits,
          InternetAddress(_ssdpMulticastAddr),
          _ssdpPort,
        );
      } catch (_) {}
      probe.close();
      debugPrint('[CastDiscovery] 已触发 iOS 本地网络权限检查');
    } catch (e) {
      debugPrint('[CastDiscovery] 本地网络权限探测失败: $e');
    }
  }

  /// 停止设备发现
  void stopDiscovery() {
    _running = false;
    _ssdpTimer?.cancel();
    _cleanupTimer?.cancel();
    _ssdpSubscription?.cancel();
    _ssdpSocket?.close();
    _ssdpSocket = null;
    // 释放组播锁（不释放会持续耗电）
    NativeBridgeService.instance.releaseMulticastLock();
  }

  // ──────────── SSDP 发送 / 接收 ────────────

  Future<void> _startSsdp() async {
    try {
      _ssdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _ssdpSocket!.readEventsEnabled = true;

      _ssdpSubscription = _ssdpSocket!.listen(_handleSsdpResponse);

      _sendSsdpSearch();

      // 也搜索 Chromecast
      _sendSsdpSearch(serviceType: 'urn:dial-multiscreen-org:service:dial:1');
      // Miracast
      _sendSsdpSearch(
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1');
    } catch (e) {
      debugPrint('[CastDiscovery] SSDP socket error: $e');
    }
  }

  void _sendSsdpSearch({
    String serviceType = 'urn:schemas-upnp-org:device:MediaRenderer:1',
  }) {
    if (_ssdpSocket == null) return;

    final host = InternetAddress(_ssdpMulticastAddr);
    final message = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpMulticastAddr:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $serviceType\r\n'
        '\r\n';

    _ssdpSocket!.send(utf8.encode(message), host, _ssdpPort);
  }

  void _handleSsdpResponse(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _ssdpSocket?.receive();
    if (datagram == null) return;

    try {
      final data = utf8.decode(datagram.data);
      _parseSsdpResponse(data);
    } catch (_) {}
  }

  void _parseSsdpResponse(String response) {
    final headers = _parseHttpHeaders(response);
    final location = headers['location'] ?? '';
    final server = headers['server'] ?? '';
    final st = headers['st'] ?? headers['nt'] ?? '';
    if (location.isEmpty) return;

    final id = location.hashCode.toRadixString(16);
    final name = _extractNameFromHeaders(headers, server);

    final protocol = _inferProtocol(server, st);
    final now = DateTime.now();

    if (_devices.containsKey(id)) {
      _devices[id] = _devices[id]!.copyWith(lastSeen: now);
      return;
    }

    final device = CastDevice(
      id: id,
      name: name,
      protocol: protocol,
      host: Uri.tryParse(location)?.host ?? '',
      port: Uri.tryParse(location)?.port ?? 0,
      location: location,
      serviceType: st,
      manufacturer: server,
      lastSeen: now,
      supportsVideo: st.contains('MediaRenderer') ||
          st.contains('AVTransport') ||
          st.contains('dial'),
      supportsAudio: true,
    );

    _devices[id] = device;
    _deviceController.add(device);
  }

  // ──────────── mDNS (Chromecast / AirPlay) ────────────

  Future<void> _scanMdns() async {
    // Chromecast mDNS: _googlecast._tcp.local
    // AirPlay mDNS: _airplay._tcp.local
    // 由于 multicast_dns 需要额外 package，这里用 IP 扫描作为 fallback
    await _scanLocalNetworkForCasts();
  }

  /// 局域网 HTTP 扫描 Chromecast / AirPlay
  Future<void> _scanLocalNetworkForCasts() async {
    // 从当前网络接口推断 /24 子网
    final subnet = await _getLocalSubnet();
    if (subnet == null) return;

    // 扫描 Chromecast 端口 8008/8009
    for (var i = 1; i <= 20; i++) {
      final host = '$subnet.$i';
      _probeHost(host, 8008, CastProtocol.chromecast);
      _probeHost(host, 7000, CastProtocol.airplay);
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _probeHost(String host, int port, CastProtocol protocol) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();

      final id = '$host:$port';
      if (!_devices.containsKey(id)) {
        final name = protocol == CastProtocol.chromecast
            ? 'Chromecast ($host)'
            : 'AirPlay ($host)';
        final device = CastDevice(
          id: id,
          name: name,
          protocol: protocol,
          host: host,
          port: port,
          lastSeen: DateTime.now(),
          supportsVideo: true,
        );
        _devices[id] = device;
        _deviceController.add(device);
      }
    } catch (_) {
      // 设备不可达，正常
    }
  }

  // ──────────── 工具方法 ────────────

  Map<String, String> _parseHttpHeaders(String data) {
    final map = <String, String>{};
    for (final line in data.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        final key = line.substring(0, colon).trim().toLowerCase();
        final value = line.substring(colon + 1).trim();
        map[key] = value;
      }
    }
    return map;
  }

  String _extractNameFromHeaders(Map<String, String> headers, String server) {
    // 尝试从 X-FRIENDLY-NAME 或 USN 提取
    final friendly = headers['x-friendly-name'];
    if (friendly != null && friendly.isNotEmpty) return friendly;

    final usn = headers['usn'] ?? '';
    // usn: uuid:xxx::urn:xxx
    final parts = usn.split('::');
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return parts[1].split(':').last;
    }

    return server.isNotEmpty ? server.split('/').first : 'Unknown Device';
  }

  CastProtocol _inferProtocol(String server, String st) {
    if (server.toLowerCase().contains('chromecast') || st.contains('dial')) {
      return CastProtocol.chromecast;
    }
    if (server.toLowerCase().contains('airplay') ||
        server.toLowerCase().contains('apple')) {
      return CastProtocol.airplay;
    }
    if (st.contains('MediaRenderer') || st.contains('AVTransport')) {
      return CastProtocol.dlna;
    }
    return CastProtocol.unknown;
  }

  void _cleanStaleDevices() {
    final now = DateTime.now();
    _devices.removeWhere((id, device) {
      if (device.lastSeen == null) return false;
      final stale = now.difference(device.lastSeen!).inSeconds > 60;
      if (stale && device.status != CastDeviceStatus.disconnected) {
        final updated = device.copyWith(status: CastDeviceStatus.disconnected);
        _devices[id] = updated;
        _deviceController.add(updated);
      }
      return stale && device.status == CastDeviceStatus.disconnected;
    });
  }

  Future<String?> _getLocalSubnet() async {
    try {
      for (final interface in await NetworkInterface.list()) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            final parts = addr.address.split('.');
            return '${parts[0]}.${parts[1]}.${parts[2]}';
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // ──────────── 公开方法 ────────────

  /// 手动刷新
  void refresh() {
    _devices.clear();
    _sendSsdpSearch();
    _sendSsdpSearch(serviceType: 'urn:dial-multiscreen-org:service:dial:1');
    _sendSsdpSearch(serviceType: 'urn:schemas-upnp-org:service:AVTransport:1');
  }
}
