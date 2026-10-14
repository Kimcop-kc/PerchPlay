import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/cast_device_model.dart';

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

  /// 停止设备发现
  void stopDiscovery() {
    _running = false;
    _ssdpTimer?.cancel();
    _cleanupTimer?.cancel();
    _ssdpSubscription?.cancel();
    _ssdpSocket?.close();
    _ssdpSocket = null;
  }

  // ──────────── SSDP 发送 / 接收 ────────────

  Future<void> _startSsdp() async {
    try {
      _ssdpSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, 0);
      _ssdpSocket!.readEventsEnabled = true;

      _ssdpSubscription = _ssdpSocket!.listen(_handleSsdpResponse);

      _sendSsdpSearch();

      // 也搜索 Chromecast
      _sendSsdpSearch(serviceType: 'urn:dial-multiscreen-org:service:dial:1');
      // Miracast
      _sendSsdpSearch(serviceType: 'urn:schemas-upnp-org:service:AVTransport:1');
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
    final usn = headers['usn'] ?? '';

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
      host: Uri.tryParse(location)?.host ?? datagram?.address.address ?? '',
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

  Future<void> _probeHost(
      String host, int port, CastProtocol protocol) async {
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

  String _extractNameFromHeaders(
      Map<String, String> headers, String server) {
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
    if (server.toLowerCase().contains('chromecast') ||
        st.contains('dial')) {
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
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback) {
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