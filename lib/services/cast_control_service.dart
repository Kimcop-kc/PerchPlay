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

  /// 从设备描述 XML 里解析出来的 AVTransport 控制地址（不要再靠猜）
  Uri? _avTransportControlUrl;
  String _avTransportServiceType = 'urn:schemas-upnp-org:service:AVTransport:1';

  /// RenderingControl 控制地址与 serviceType（音量命令走它，不是 AVTransport）。
  ///
  /// 之前的 SetVolume 复用 AVTransport 的 URL 与 SOAPAction，电视端收到
  /// 一个不属于该服务的 action，直接回 Fault/404，音量永远调不动。
  Uri? _renderingControlUrl;
  String _renderingServiceType =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  /// 最近一次错误（UI 用来提示，而不是静默失败）
  String? lastError;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  final _statusController = StreamController<CastControlEvent>.broadcast();
  Stream<CastControlEvent> get statusStream => _statusController.stream;

  // ──────────── 连接 / 断开 ────────────

  /// 连接到投屏设备
  Future<bool> connect(CastDevice device) async {
    _activeDevice = device;
    _avTransportControlUrl = null;
    _renderingControlUrl = null;
    lastError = null;
    _httpClient = HttpClient();
    _httpClient!.connectionTimeout = const Duration(seconds: 5);

    try {
      switch (device.protocol) {
        case CastProtocol.dlna:
          await _connectDlna(device);
          break;
        case CastProtocol.chromecast:
          // Chromecast 需要 CASTV2(TLS+protobuf) 协议，尚未实现，
          // 不能假装连上（否则界面显示已连接却什么都放不出来）
          lastError = 'Chromecast 暂不支持，请选择 DLNA 设备';
          _httpClient?.close();
          _httpClient = null;
          return false;
        case CastProtocol.airplay:
          lastError = 'AirPlay 暂不支持（需要 iOS 端原生支持）';
          _httpClient?.close();
          _httpClient = null;
          return false;
        default:
          lastError = '未知设备类型';
          return false;
      }

      // DLNA 必须拿到 AVTransport 控制地址才算连接成功
      if (device.protocol == CastProtocol.dlna &&
          _avTransportControlUrl == null) {
        lastError = '设备未提供 AVTransport 服务，无法投屏';
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
      lastError = '连接失败：$e';
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

    _httpClient?.close(force: true);
    _httpClient = null;
    _activeDevice = null;
    _avTransportControlUrl = null;
    _renderingControlUrl = null;
    _isConnected = false;

    _statusController.add(const CastControlEvent(type: CastEventType.disconnected));
  }

  // ──────────── DLNA ────────────

  Future<void> _connectDlna(CastDevice device) async {
    // 拉取设备描述 XML，解析出 AVTransport 的真实 controlURL。
    // 之前是拿 location 硬拼 /AVTransport/control，绝大多数设备都不是这个
    // 路径，POST 过去直接 404 → 「显示已连接但电视没反应」。
    final xml = await _fetchDeviceDescription(device.location);
    if (xml.isEmpty) return;
    _parseAvTransport(xml, device.location);
  }

  /// 解析 UPnP 设备描述，找出 AVTransport 与 RenderingControl 的 controlURL。
  void _parseAvTransport(String xml, String descriptionUrl) {
    final serviceBlocks = RegExp(r'<service>(.*?)</service>', dotAll: true)
        .allMatches(xml)
        .map((m) => m.group(1) ?? '')
        .toList();

    for (final block in serviceBlocks) {
      final type = _tag(block, 'serviceType');
      if (type == null) continue;
      final control = _tag(block, 'controlURL');
      if (control == null || control.isEmpty) continue;

      final base = Uri.parse(descriptionUrl);
      final uri = control.startsWith('http')
          ? Uri.tryParse(control)
          : base.resolve(control);
      if (uri == null) continue;

      if (type.contains('RenderingControl')) {
        _renderingControlUrl = uri;
        _renderingServiceType = type;
        debugPrint('[Cast] RenderingControl controlURL = $uri');
      } else if (type.contains('AVTransport')) {
        _avTransportControlUrl = uri;
        _avTransportServiceType = type;
        debugPrint('[Cast] AVTransport controlURL = $uri');
      }
    }
    if (_avTransportControlUrl == null) {
      lastError = '设备描述里没有 AVTransport 控制地址';
    }
  }

  /// 取标签文本（容忍命名空间前缀与大小写）
  String? _tag(String xml, String name) {
    final m = RegExp(
            '<(?:[A-Za-z0-9]+:)?$name[^>]*>(.*?)</(?:[A-Za-z0-9]+:)?$name>',
            dotAll: true,
            caseSensitive: false)
        .firstMatch(xml);
    return m?.group(1)?.trim();
  }

  Future<String> _fetchDeviceDescription(String location) async {
    try {
      final uri = Uri.parse(location);
      final req = await _httpClient!.getUrl(uri);
      req.headers.set('User-Agent', 'PerchPlay/1.0 DLNA/1.0');
      final res = await req.close();
      if (res.statusCode != 200) {
        lastError = '设备描述返回 ${res.statusCode}';
        return '';
      }
      return await res.transform(utf8.decoder).join();
    } catch (e) {
      lastError = '读取设备描述失败：$e';
      return '';
    }
  }

  /// 发送 DLNA SOAP 命令
  ///
  /// [rendering] 为 true 时使用 RenderingControl 的 controlURL 与 serviceType
  /// （音量命令），否则用 AVTransport（播放/暂停/跳转/停止）。
  ///
  /// 返回 null 表示**失败**（HTTP>=400、SOAP Fault、网络异常、地址缺失），
  /// 非 null 表示成功。调用方必须据此判断，不能再「响应体非空就当成功」。
  Future<String?> _sendDlnaCommand(
    String action, {
    Map<String, String>? params,
    bool rendering = false,
  }) async {
    if (_activeDevice == null || _httpClient == null) return null;
    final uri = rendering ? _renderingControlUrl : _avTransportControlUrl;
    final serviceType =
        rendering ? _renderingServiceType : _avTransportServiceType;
    if (uri == null) {
      lastError = rendering ? '设备未提供音量控制服务' : '未找到 AVTransport 控制地址';
      return null;
    }

    final soapBody = _buildDlnaSoap(action, params ?? {}, serviceType);
    final bodyBytes = utf8.encode(soapBody);

    // 便宜的 DLNA 设备常在响应后直接关连接，复用 keep-alive 会导致
    // 第二条命令（Play）Write failed。这里每条命令独立连接，并重试一次。
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final req = await _httpClient!.postUrl(uri);
        req.headers.contentType = ContentType(
          'text',
          'xml',
          charset: 'utf-8',
        );
        req.headers.set('SOAPACTION', '"$serviceType#$action"');
        req.headers.set('User-Agent', 'PerchPlay/1.0 DLNA/1.0');
        req.headers.set(HttpHeaders.connectionHeader, 'close');
        // 显式 Content-Length：不能用 chunked，很多电视不认 chunked 的 SOAP
        req.contentLength = bodyBytes.length;
        req.add(bodyBytes);

        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();

        // HTTP 错误码 → 失败
        if (res.statusCode >= 400) {
          lastError = 'DLNA $action 失败（HTTP ${res.statusCode}）';
          debugPrint('[Cast] $action -> ${res.statusCode}: $body');
          return null;
        }

        // SOAP Fault：HTTP 200 但 body 里带 <Fault>，也必须判失败。
        // 之前只查 HTTP 码，非空 Fault 体会被当成成功穿过，导致
        // 「电视拒绝播放，业务层仍返回成功」。
        if (RegExp(r'<(?:[\w-]+:)?Fault(?:\s|>)', caseSensitive: false)
            .hasMatch(body)) {
          lastError = 'DLNA $action 失败（SOAP Fault）';
          debugPrint('[Cast] $action -> SOAP Fault: $body');
          return null;
        }

        lastError = null;
        return body;
      } catch (e) {
        debugPrint('[Cast] DLNA $action 第 ${attempt + 1} 次失败: $e');
        if (attempt == 1) {
          lastError = 'DLNA $action 异常：$e';
          return null;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return null;
  }

  /// XML 文本转义（片名带 & < > 会让 SOAP 请求变成非法 XML）
  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  String _buildDlnaSoap(
      String action, Map<String, String> params, String serviceType) {
    final paramsXml = params.entries
        .map((e) => '<${e.key}>${_esc(e.value)}</${e.key}>')
        .join();

    return '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
 s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="$serviceType">
      $paramsXml
    </u:$action>
  </s:Body>
</s:Envelope>''';
  }

  // ──────────── Chromecast / AirPlay：暂未实现 ────────────
  //
  // Chromecast 需要 CASTV2（TLS + protobuf 长连接）协议栈，
  // AirPlay 需要 RTSP/原生层支持，目前都没有实现。
  // connect() 里会明确返回失败并给出原因，不再假装“已连接”。

  // ──────────── 通用控制方法 ────────────

  /// 播放指定 URL（必须是对设备可达的 http 地址，见 LocalMediaServer）
  Future<bool> playUrl(String url, {String title = ''}) async {
    if (!_isConnected || _activeDevice == null) {
      lastError = '尚未连接设备';
      return false;
    }
    // 本机文件路径设备读不到，直接给出明确错误
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      lastError = '投屏地址必须是 http 地址（本地文件需先通过内置媒体服务暴露）';
      return false;
    }

    try {
      switch (_activeDevice!.protocol) {
        case CastProtocol.dlna:
          final setRes = await _sendDlnaCommand('SetAVTransportURI', params: {
            'InstanceID': '0',
            'CurrentURI': url,
            'CurrentURIMetaData': _buildDlnaMetadata(title, url),
          });
          // null = 失败（HTTP>=400 / SOAP Fault / 网络异常），必须传播。
          // 之前是 `setRes == null && lastError != null`，非空 Fault 体会穿过。
          if (setRes == null) return false;
          final playRes = await _sendDlnaCommand('Play',
              params: {'InstanceID': '0', 'Speed': '1'});
          if (playRes == null) return false;
          break;

        case CastProtocol.chromecast:
        case CastProtocol.airplay:
          lastError = '该协议暂不支持投屏';
          return false;

        default:
          lastError = '未知设备类型';
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
      await _sendDlnaCommand('Pause', params: {'InstanceID': '0'});
    }
    _statusController.add(const CastControlEvent(type: CastEventType.paused));
  }

  /// 继续播放
  Future<void> resume() async {
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Play', params: {'InstanceID': '0', 'Speed': '1'});
    }
    _statusController.add(const CastControlEvent(type: CastEventType.playing));
  }

  /// 停止
  Future<void> stop() async {
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      await _sendDlnaCommand('Stop', params: {'InstanceID': '0'});
    }
    _statusController.add(const CastControlEvent(type: CastEventType.stopped));
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
  ///
  /// 走 RenderingControl 服务（controlURL + SOAPAction 都是 RenderingControl 的），
  /// 不是 AVTransport。之前复用 AVTransport 导致电视端收不到合法命令。
  Future<void> setVolume(int volume) async {
    final v = volume.clamp(0, 100);
    if (_activeDevice?.protocol == CastProtocol.dlna) {
      final res = await _sendDlnaCommand('SetVolume', rendering: true, params: {
        'InstanceID': '0',
        'Channel': 'Master',
        'DesiredVolume': '$v',
      });
      // 失败要透出给 UI，不能静默吞掉
      if (res == null) {
        _statusController.add(CastControlEvent(
            type: CastEventType.error, errorMessage: lastError));
      }
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
