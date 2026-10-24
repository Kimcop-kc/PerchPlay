import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/cast_device_model.dart';
import '../services/cast_discovery_service.dart';
import '../services/cast_control_service.dart';
import '../services/local_media_import_service.dart';
import '../services/local_media_server.dart';

/// 投屏设备列表状态
class CastState {
  final List<CastDevice> devices;
  final CastDevice? activeDevice;
  final bool isDiscovering;
  final bool isConnected;
  final bool isPlaying;
  final String? errorMessage;

  const CastState({
    this.devices = const [],
    this.activeDevice,
    this.isDiscovering = false,
    this.isConnected = false,
    this.isPlaying = false,
    this.errorMessage,
  });

  CastState copyWith({
    List<CastDevice>? devices,
    CastDevice? activeDevice,
    bool? isDiscovering,
    bool? isConnected,
    bool? isPlaying,
    String? errorMessage,
    bool clearError = false,
  }) {
    return CastState(
      devices: devices ?? this.devices,
      activeDevice: activeDevice ?? this.activeDevice,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      isConnected: isConnected ?? this.isConnected,
      isPlaying: isPlaying ?? this.isPlaying,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class CastNotifier extends StateNotifier<CastState> {
  final CastDiscoveryService _discovery = CastDiscoveryService.instance;
  final CastControlService _control = CastControlService.instance;

  StreamSubscription<CastDevice>? _deviceSub;
  StreamSubscription<CastControlEvent>? _controlSub;

  CastNotifier() : super(const CastState()) {
    _deviceSub = _discovery.deviceStream.listen(_onDeviceDiscovered);
    _controlSub = _control.statusStream.listen(_onControlEvent);
  }

  /// 安全更新 state（防止 dispose 后写入导致崩溃）
  void _safeUpdate(CastState Function(CastState) updater) {
    if (!mounted) return;
    try {
      state = updater(state);
    } catch (e) {
      debugPrint('[Cast] state 更新失败（可能已 dispose）: $e');
    }
  }

  void _onDeviceDiscovered(CastDevice device) {
    _safeUpdate((s) {
      final updated = List<CastDevice>.from(s.devices);
      final idx = updated.indexWhere((d) => d.id == device.id);
      if (idx >= 0) {
        updated[idx] = device;
      } else {
        updated.add(device);
      }
      return s.copyWith(devices: updated);
    });
  }

  void _onControlEvent(CastControlEvent event) {
    _safeUpdate((s) {
      switch (event.type) {
        case CastEventType.connected:
          return s.copyWith(
            isConnected: true,
            activeDevice: event.device ?? s.activeDevice,
            clearError: true,
          );
        case CastEventType.disconnected:
          return s.copyWith(
            isConnected: false,
            isPlaying: false,
            activeDevice: null,
          );
        case CastEventType.playing:
          return s.copyWith(isPlaying: true);
        case CastEventType.paused:
        case CastEventType.stopped:
          return s.copyWith(isPlaying: false);
        case CastEventType.error:
          return s.copyWith(
            errorMessage: event.errorMessage,
            isConnected: false,
          );
        default:
          return s;
      }
    });
  }

  void startDiscovery() {
    _safeUpdate((s) => s.copyWith(isDiscovering: true));
    _discovery.startDiscovery();
  }

  void stopDiscovery() {
    _discovery.stopDiscovery();
    _safeUpdate((s) => s.copyWith(isDiscovering: false));
  }

  void refresh() {
    _discovery.refresh();
  }

  Future<void> connect(CastDevice device) async {
    _safeUpdate((s) {
      final updated = List<CastDevice>.from(s.devices);
      final idx = updated.indexWhere((d) => d.id == device.id);
      if (idx >= 0) {
        updated[idx] = updated[idx].copyWith(status: CastDeviceStatus.connecting);
        return s.copyWith(devices: updated);
      }
      return s;
    });
    
    final ok = await _control.connect(device);
    
    _safeUpdate((s) {
      if (!ok) {
        return s.copyWith(
          isConnected: false,
          errorMessage: _control.lastError ?? '连接失败',
        );
      }
      return s;
    });
  }

  /// 把本地视频投到已连接的设备
  ///
  /// 先用手机会话内的 HTTP 服务把文件暴露到局域网（电视读不到
  /// /storage/... 路径），再把该 URL 交给设备播放。
  Future<bool> castLocalFile(String filePath, {String title = ''}) async {
    // 照片库资产是虚拟路径（phasset://<id>），磁盘上没有文件。
    // 投屏前先按需导出成真实文件（走同一个临时缓存 + LRU），否则局域网
    // HTTP 服务找不到文件，电视端会直接报错。
    var localPath = filePath;
    final assetId = LocalMediaImportService.assetIdFromPath(filePath);
    if (assetId != null) {
      final resolved = await LocalMediaImportService.instance
          .resolveAssetForPlayback(assetId);
      if (resolved == null) {
        _safeUpdate((s) => s.copyWith(errorMessage: '无法读取该相册视频'));
        return false;
      }
      localPath = resolved;
    }

    final url = await LocalMediaServer.instance.urlFor(localPath, title: title);
    
    if (url == null) {
      _safeUpdate((s) => s.copyWith(errorMessage: '无法启动本地投屏服务（检查网络）'));
      return false;
    }
    
    final ok = await _control.playUrl(url, title: title);
    
    _safeUpdate((s) {
      if (!ok) {
        return s.copyWith(errorMessage: _control.lastError ?? '投屏失败');
      } else {
        return s.copyWith(isPlaying: true, clearError: true);
      }
    });
    
    return ok;
  }

  Future<void> disconnect() async {
    await _control.disconnect();
  }

  Future<bool> castVideo(String url, {String title = ''}) async {
    return await _control.playUrl(url, title: title);
  }

  Future<void> pause() async {
    await _control.pause();
  }

  Future<void> resume() async {
    await _control.resume();
  }

  Future<void> stop() async {
    await _control.stop();
  }

  Future<void> seek(int seconds) async {
    await _control.seek(seconds);
  }

  Future<void> setVolume(int volume) async {
    await _control.setVolume(volume);
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _controlSub?.cancel();
    _discovery.stopDiscovery();
    _control.disconnect();
    super.dispose();
  }
}

final castProvider = StateNotifierProvider<CastNotifier, CastState>((ref) {
  return CastNotifier();
});
