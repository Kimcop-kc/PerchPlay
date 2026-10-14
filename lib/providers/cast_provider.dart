import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/cast_device_model.dart';
import '../services/cast_discovery_service.dart';
import '../services/cast_control_service.dart';

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
  }) {
    return CastState(
      devices: devices ?? this.devices,
      activeDevice: activeDevice ?? this.activeDevice,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      isConnected: isConnected ?? this.isConnected,
      isPlaying: isPlaying ?? this.isPlaying,
      errorMessage: errorMessage,
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

  void _onDeviceDiscovered(CastDevice device) {
    final updated = List<CastDevice>.from(state.devices);
    final idx = updated.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      updated[idx] = device;
    } else {
      updated.add(device);
    }
    state = state.copyWith(devices: updated);
  }

  void _onControlEvent(CastControlEvent event) {
    switch (event.type) {
      case CastEventType.connected:
        state = state.copyWith(
          isConnected: true,
          activeDevice: event.device ?? state.activeDevice,
          errorMessage: null,
        );
        break;
      case CastEventType.disconnected:
        state = state.copyWith(
          isConnected: false,
          isPlaying: false,
          activeDevice: null,
        );
        break;
      case CastEventType.playing:
        state = state.copyWith(isPlaying: true);
        break;
      case CastEventType.paused:
      case CastEventType.stopped:
        state = state.copyWith(isPlaying: false);
        break;
      case CastEventType.error:
        state = state.copyWith(
          errorMessage: event.errorMessage,
          isConnected: false,
        );
        break;
      default:
        break;
    }
  }

  void startDiscovery() {
    state = state.copyWith(isDiscovering: true);
    _discovery.startDiscovery();
  }

  void stopDiscovery() {
    _discovery.stopDiscovery();
    state = state.copyWith(isDiscovering: false);
  }

  void refresh() {
    _discovery.refresh();
  }

  Future<void> connect(CastDevice device) async {
    final updated = List<CastDevice>.from(state.devices);
    final idx = updated.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      updated[idx] = updated[idx]
          .copyWith(status: CastDeviceStatus.connecting);
      state = state.copyWith(devices: updated);
    }
    await _control.connect(device);
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