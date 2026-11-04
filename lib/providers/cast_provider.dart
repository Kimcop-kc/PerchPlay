import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/cast_device_model.dart';
import '../services/cast_discovery_service.dart';
import '../services/cast_control_service.dart';
import '../services/local_media_import_service.dart';
import '../services/local_media_server.dart';
import '../services/cloud/stream_proxy_server.dart';
import '../services/cloud/cloud_drive_service.dart';

/// 投屏设备列表状态
class CastState {
  final List<CastDevice> devices;
  final CastDevice? activeDevice;
  final bool isDiscovering;
  final bool isConnected;
  final bool isPlaying;
  final int volume;
  final int seekPosition;
  final String? errorMessage;

  const CastState({
    this.devices = const [],
    this.activeDevice,
    this.isDiscovering = false,
    this.isConnected = false,
    this.isPlaying = false,
    this.volume = 0,
    this.seekPosition = 0,
    this.errorMessage,
  });

  CastState copyWith({
    List<CastDevice>? devices,
    CastDevice? activeDevice,
    bool? isDiscovering,
    bool? isConnected,
    bool? isPlaying,
    int? volume,
    int? seekPosition,
    String? errorMessage,
    bool clearError = false,
    bool clearActiveDevice = false,
  }) {
    return CastState(
      devices: devices ?? this.devices,
      // 断开时要用 clearActiveDevice 显式清空，不能写 activeDevice: null：
      // `activeDevice ?? this.activeDevice` 会把 null 当成「不修改」，
      // 导致断开后旧设备一直挂着（M07）。
      activeDevice:
          clearActiveDevice ? null : (activeDevice ?? this.activeDevice),
      isDiscovering: isDiscovering ?? this.isDiscovering,
      isConnected: isConnected ?? this.isConnected,
      isPlaying: isPlaying ?? this.isPlaying,
      volume: volume ?? this.volume,
      seekPosition: seekPosition ?? this.seekPosition,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class CastNotifier extends StateNotifier<CastState> {
  final CastDiscoveryService _discovery = CastDiscoveryService.instance;
  final CastControlService _control = CastControlService.instance;

  StreamSubscription<CastDevice>? _deviceSub;
  StreamSubscription<CastControlEvent>? _controlSub;

  /// 投屏会话版本号：connect/换媒体/disconnect 都递增。
  /// 旧会话的迟到清理（_releaseRemoteProxy / _releaseMedia）据此作废，
  /// 避免「旧清理误关新会话」的并发 bug。
  int _castVersion = 0;

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
            clearActiveDevice: true,
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
    final version = ++_castVersion;
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
    if (!mounted || version != _castVersion) return;
    
    _safeUpdate((s) {
      if (!ok) {
        return s.copyWith(
          isConnected: false,
          clearActiveDevice: true,
          errorMessage: _control.lastError ?? '连接失败',
        );
      }
      // 连接成功直接落状态，不依赖 statusStream 的异步事件：
      // stream 是 broadcast + 异步派发，await connect 返回的瞬间事件
      // 可能还没送达，调用方读到的 isConnected 仍是 false。
      return s.copyWith(
        isConnected: true,
        activeDevice: device,
        clearError: true,
      );
    });
  }

  /// 把当前播放的文件投到已连接的设备。
  ///
  /// 按来源分流（M06）：
  ///  - 本地文件 / 照片库资产：走内置 HTTP 服务暴露到局域网；
  ///  - http/https 远程地址（NAS WebDAV / 网盘直链 / 串流代理）：
  ///    起一个绑定 LAN 的转发代理，电视连它、它再带鉴权连源；
  ///  - smb/ftp/nfs：没有可直接转接的 HTTP 地址，明确报错（不静默失败）。
  Future<bool> castLocalFile(String filePath,
      {String title = '', Map<String, String> headers = const {}}) async {
    final lower = filePath.trim().toLowerCase();

    // ── 远程 HTTP(S) 源 ──
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return _castRemoteUrl(filePath, title: title, headers: headers);
    }

    // ── SMB / FTP / NFS：没有可转接的 HTTP 地址 ──
    if (lower.startsWith('smb://') ||
        lower.startsWith('ftp://') ||
        lower.startsWith('sftp://') ||
        lower.startsWith('nfs://')) {
      final proto = lower.split('://').first.toUpperCase();
      _safeUpdate((s) => s.copyWith(
          errorMessage: '$proto 源无法直接投屏：电视端不支持该协议，'
              '请先将文件复制到手机本地后再投屏'));
      return false;
    }

    // ── 本地文件 / 照片库资产 ──
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

  /// 当前远程转发代理（远程视频投屏用，断开/换媒体时释放）。
  StreamProxyServer? _remoteProxy;

  /// 把远程 http(s) 源经 LAN 可达代理投给电视。
  ///
  /// 不能直接把源 URL 给电视：源可能是网盘直链（带时效、要鉴权头），
  /// 也可能就是 127.0.0.1 串流代理（电视连不上手机回环）。这里再起一层
  /// 绑定局域网地址的转发代理，由它带鉴权头拉源。
  Future<bool> _castRemoteUrl(String url,
      {String title = '', Map<String, String> headers = const {}}) async {
    final version = ++_castVersion;
    // 先释放上一次的代理，避免端口泄漏
    await _releaseRemoteProxy();
    if (!mounted || version != _castVersion) return false;
    final ip = await LocalMediaServer.instance.localIp();
    if (ip == null) {
      _safeUpdate((s) => s.copyWith(errorMessage: '未找到电视可访问的局域网地址'));
      return false;
    }
    final proxy = await StreamProxyServer.start(
      resolveUrl: () async => url,
      headers: () => Map<String, String>.from(headers),
      bindAddress: InternetAddress.anyIPv4,
    );
    // 起代理的 await 期间可能已断开/换媒体，旧代理不能残留占用
    if (!mounted || version != _castVersion) {
      await proxy.stop();
      return false;
    }
    _remoteProxy = proxy;
    final proxyUrl = 'http://$ip:${proxy.port}/';
    final ok = await _control.playUrl(proxyUrl, title: title);
    if (!ok) {
      await _releaseRemoteProxy();
    }
    _safeUpdate((s) {
      if (!ok) {
        return s.copyWith(errorMessage: _control.lastError ?? '投屏失败');
      } else {
        return s.copyWith(isPlaying: true, clearError: true);
      }
    });
    return ok;
  }

  Future<void> _releaseRemoteProxy() async {
    final p = _remoteProxy;
    _remoteProxy = null;
    await p?.stop();
  }

  Future<void> disconnect() async {
    ++_castVersion;
    await _releaseRemoteProxy();
    await _control.disconnect();
    // 直接落状态，不依赖 statusStream 的异步 disconnected 事件。
    // 同时释放投屏用的本地媒体服务（M08）：断开后端口和文件引用必须释放。
    _safeUpdate((s) => s.copyWith(
          isConnected: false,
          isPlaying: false,
          volume: 0,
          seekPosition: 0,
          clearActiveDevice: true,
          clearError: true,
        ));
    await LocalMediaServer.instance.stop();
  }

  /// 投一个已知的 http(s) 视频地址（旧入口，保留兼容）。
  ///
  /// 修复（缺口2）：之前这里直接 `_control.playUrl(url)`，把裸直链塞给电视，
  /// 电视端拿不到鉴权头、也连不上 127.0.0.1，重蹈 M06。现在统一走
  /// [castLocalFile] 的远程分流——远程 http(s) 一律经 LAN 可达转发代理。
  Future<bool> castVideo(String url,
      {String title = '', Map<String, String> headers = const {}}) async {
    return castLocalFile(url, title: title, headers: headers);
  }

  /// 投一个网盘文件（缺口3 修复）。
  ///
  /// 播放器里的 videoPath 是本地 127.0.0.1 串流代理地址，电视连不上回环，
  /// 而且本地播放停止时串流代理会被关掉 → 投屏跟着断流。这里不走那条链，
  /// 而是**重新取直链 + 复用资源鉴权头**，起一个独立、绑定局域网地址的
  /// 转发代理，电视直接连它，完全绕过中间那层 127.0.0.1。
  Future<bool> castCloudFile({
    required String accountId,
    required String fileId,
    String title = '',
  }) async {
    final version = ++_castVersion;
    await _releaseRemoteProxy();
    if (!mounted || version != _castVersion) return false;
    final ip = await LocalMediaServer.instance.localIp();
    if (ip == null) {
      _safeUpdate((s) => s.copyWith(errorMessage: '未找到电视可访问的局域网地址'));
      return false;
    }
    // 先取一次鉴权头（阿里要 await token）。投屏是短时操作，缓存这一次
    // 足够；Cookie 轮换主要影响长时播放，投屏转发代理不跨小时。
    final cloudHeaders =
        await CloudDriveService.instance.resourceHeaders(accountId);
    final proxy = await StreamProxyServer.start(
      resolveUrl: () =>
          CloudDriveService.instance.getDownloadUrl(accountId, fileId),
      headers: () => Map<String, String>.from(cloudHeaders),
      bindAddress: InternetAddress.anyIPv4,
    );
    if (!mounted || version != _castVersion) {
      await proxy.stop();
      return false;
    }
    _remoteProxy = proxy;
    final proxyUrl = 'http://$ip:${proxy.port}/';
    final ok = await _control.playUrl(proxyUrl, title: title);
    if (!ok) {
      await _releaseRemoteProxy();
    }
    _safeUpdate((s) {
      if (!ok) {
        return s.copyWith(errorMessage: _control.lastError ?? '投屏失败');
      } else {
        return s.copyWith(isPlaying: true, clearError: true);
      }
    });
    return ok;
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
    final v = volume.clamp(0, 100);
    await _control.setVolume(v);
    // 同步到 state：音量滑条要显示当前值（原始 bug「音量」环节闭环）
    _safeUpdate((s) => s.copyWith(volume: v));
  }

  /// 本地同步进度提示（DLNA 无可靠「当前位置」查询接口，
  /// 这里只是让 UI 显示最近一次下发的目标，不假装是真实位置）。
  void setSeekPosition(int seconds) {
    _safeUpdate((s) => s.copyWith(seekPosition: seconds.clamp(0, 24 * 3600)));
  }

  @override
  void dispose() {
    ++_castVersion;
    _deviceSub?.cancel();
    _controlSub?.cancel();
    _discovery.stopDiscovery();
    _control.disconnect();
    // M08：dispose 也要释放本地媒体服务与远程代理，不能只靠 disconnect()。
    unawaited(_releaseRemoteProxy());
    unawaited(LocalMediaServer.instance.stop());
    super.dispose();
  }
}

final castProvider = StateNotifierProvider<CastNotifier, CastState>((ref) {
  return CastNotifier();
});
