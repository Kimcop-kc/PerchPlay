import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/cast_device_model.dart';

/// 投屏控制器
/// 负责连接到设备、发送播放命令
class CastControlService {
  CastControlService._();
  static final instance = CastControlService._();

  CastDevice? _activeDevice;
  CastDevice? get activeDevice => _activeDevice;

  HttpClient? _httpClient;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  final _statusController = StreamController<CastControlEvent>.broadcast();
  Stream<CastControlEvent> get statusStream => _statusController.stream;

  // ──────────── 连接 / 断开 ────────────

  /// 连接到投屏设备
  Future<bool> connect(CastDevice device) async {
    _activeDevice = device;
    _httpClient = HttpClient();
    _httpClient!.connectionTimeout = const Duration(seconds: 5);

    try {
      switch (device.protocol) {
        case CastProtocol.dlna:
          await _connectDlna(device);
          break;
        case CastProtocol.chromecast:
          await _connectChromecast(device);
          break;
        case CastProtocol.airplay:
          await _connectAirPlay(device);
          break;
        default:
          return false;
      }

      _isConnected = true;
      _statusController.add(CastControlEvent(
        type: CastEventType.connected,
        device: device,
      ));
      return true;
    } catch (e, st) {
      debugPrint('[Cast] connect error: $e');
      debugPrintStack(stackTrace: st);
      _statusController.add(CastControlEvent(
        type: CastEventType.error,
        device: device,
        errorMessage: e.toString(),
      ));
      return false;
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    try {
      if (_activeDevice?.protocol == CastProtocol.dlna) {
        await _sendDlnaCommand('Stop');
      }
    } catch (_) {}

    _httpClient?.close();
    _httpClient = null;
    _activeDevice = null;
    _isConnected = false;

    _statusController.add(CastControlEvent(type: CastEventType.disconnected));
  }

  // ──────────── DLNA ────────────

  Future<void> _connectDlna(CastDevice device) async {
    // 获取设备描述 XML
    await _fetchDeviceDescription(device.location);
    // 解析 AVTransport URL
  }

  Future<String> _fetchDeviceDescription(String location) async {
    final uri = Uri.parse(location);
    final req = await _httpClient!.getUrl(uri);
    req.headers.set('User-Agent', 'PerchPlay/1.0 DLNA/1.0');
    final res = await req.close();
    return await res.transform(utf8.decoder).join();
  }

  /// 发送 DLNA SOAP 命令
  Future<String?> _sendDlnaCommand(
    String action, {
    Map<String, String>? params,
  }) async {
    if (_activeDevice == null || _httpClient == null) return null;

    final controlUrl = _activeDevice!.location
        .replaceFirst('/description.xml', '/AVTransport/control')
        .replaceFirst('/dmr.xml', '/AVTransport/control');

    final soapBody = _buildDlnaSoap(action, params ?? {});
    final uri = Uri.tryParse(controlUrl);
    if (uri == null) return null;

    try {
      final req = await _httpClient!.postUrl(uri);
      req.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      req.headers.set('SOAPACTION',
          '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
      req.headers.set('User-Agent', 'PerchPlay/1.0 DLNA/1.0');
      req.write(soapBody);

      final res = await req.close();
      return await res.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    }
  }

  String _buildDlnaSoap(String action, Map<String, String> params) {
    final paramsXml = params.entries
        .map((e) => '<${e.key}>${e.value}</${e.key}>')
        .join();

    return '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      $paramsXml
    </u:$action>
  </s:Body>
</s:Envelope>''';
  }

  // ──────────── Chromecast ────────────

  Future<void> _connectChromecast(CastDevice device) async {
    // Chromecast 使用自定义 JSON 协议 over WebSocket + HTTP
    // 通过 HTTP POST /apps/YouTube 等启动 receiver
    final uri = Uri.parse('http://${device.host}:8008/apps/WebReceiver');
    try {
      final req = await _httpClient!.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'v': '1.0'}));
      await req.close();
    } catch (_) {}
  }

  // ──────────── AirPlay ────────────

  Future<void> _connectAirPlay(CastDevice device) async {
    // AirPlay 通过 RTSP + HTTP 双通道
    // 实际连接由 iOS 原生层 AVPictureInPicture + AVRoutePickerView 处理
  }

  // ──────────── 通用控制方法 ────────────

  /// 播放指定 URL
  Future<bool> playUrl(String url, {String title = ''}) async {
    if (!_isConnected || _activeDevice == null) return false;

    try {
      switch (_activeDevice!.protocol) {
        case CastProtocol.dlna:
          await _sendDlnaCommand('SetAVTransportURI', params: {
            'InstanceID': '0',
            'CurrentURI': url,
            'CurrentURIMetaData': _buildDlnaMetadata(title, url),
          });
          await _sendDlnaCommand('Play', params: {'InstanceID': '0', 'Speed': '1'});
          break;

        case CastProtocol.chromecast:
          // 通过 HTTP 加载媒体
          final uri = Uri.parse(
              'http://${_activeDevice!.host}:8008/apps/WebReceiver');
          final req = await _httpClient!.postUrl(uri);
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({
            'type': 'LOAD',
            'media': {
              'contentId': url,
              'contentType': 'video/mp4',
              'streamType': 'BUFFERED',
            },
          }));
          await req.close();
          break;

        default:
          return false;
      }

      _statusController.add(CastControlEvent(
        type: CastEventType.playing,
        device: _activeDevice!,
      ));
      return true;
    } catch (e) {
      _statusController.add(CastControlEvent(
        type: CastEventType.error,
        errorMessage: e.toString(),
      ));
      return false;
    }
  }

  /// 暂停
  Future<void> pause() async {
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Pause',
          params: {'InstanceID': '0'});
    }
    _statusController.add(CastControlEvent(type: CastEventType.paused));
  }

  /// 继续播放
  Future<void> resume() async {
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Play',
          params: {'InstanceID': '0', 'Speed': '1'});
    }
    _statusController.add(CastControlEvent(type: CastEventType.playing));
  }

  /// 停止
  Future<void> stop() async {
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Stop',
          params: {'InstanceID': '0'});
    }
    _statusController.add(CastControlEvent(type: CastEventType.stopped));
  }

  /// 跳转到指定位置（秒）
  Future<void> seek(int seconds) async {
    final timeStr = _formatDlnaTime(seconds);
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Seek', params: {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': timeStr,
      });
    }
  }

  /// 设置音量 (0~100)
  Future<void> setVolume(int volume) async {
    final v = volume.clamp(0, 100);
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('SetVolume', params: {
        'InstanceID': '0',
        'Channel': 'Master',
        'DesiredVolume': '$v',
      });
    }
  }

  // ──────────── 工具 ────────────

  String _buildDlnaMetadata(String title, String url) {
    return '''<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
 xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>$title</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
  </item>
</DIDL-Lite>''';
  }

  String _formatDlnaTime(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ──────────── 事件类型 ────────────

enum CastEventType {
  connecting,
  connected,
  disconnected,
  playing,
  paused,
  stopped,
  error,
}

class CastControlEvent {
  final CastEventType type;
  final CastDevice? device;
  final String? errorMessage;

  const CastControlEvent({
    required this.type,
    this.device,
    this.errorMessage,
  });
}
