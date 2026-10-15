import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/nas_connection_model.dart';
import '../services/nas_client_service.dart';
import '../services/nas_discovery_service.dart';

/// NAS 连接管理状态
class NasState {
  final List<NasConnection> connections;
  final NasConnection? activeConnection;
  final List<NasFileItem> currentFiles;
  final String currentPath;
  final bool isLoading;
  final String? errorMessage;
  final bool isConnected;

  /// 局域网自动发现
  final bool isDiscovering;
  final List<NasCandidate> candidates;
  final double discoverProgress;

  const NasState({
    this.connections = const [],
    this.activeConnection,
    this.currentFiles = const [],
    this.currentPath = '/',
    this.isLoading = false,
    this.errorMessage,
    this.isConnected = false,
    this.isDiscovering = false,
    this.candidates = const [],
    this.discoverProgress = 0,
  });

  NasState copyWith({
    List<NasConnection>? connections,
    NasConnection? activeConnection,
    List<NasFileItem>? currentFiles,
    String? currentPath,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    bool? isConnected,
    bool? isDiscovering,
    List<NasCandidate>? candidates,
    double? discoverProgress,
  }) {
    return NasState(
      connections: connections ?? this.connections,
      activeConnection: activeConnection ?? this.activeConnection,
      currentFiles: currentFiles ?? this.currentFiles,
      currentPath: currentPath ?? this.currentPath,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isConnected: isConnected ?? this.isConnected,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      candidates: candidates ?? this.candidates,
      discoverProgress: discoverProgress ?? this.discoverProgress,
    );
  }
}

class NasNotifier extends StateNotifier<NasState> {
  final NasClientService _service = NasClientService.instance;
  static const _kNasConnectionsKey = 'nas.connections';

  NasNotifier() : super(const NasState()) {
    _loadSavedConnections();
  }

  /// 从 SharedPreferences 恢复连接配置
  Future<void> _loadSavedConnections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kNasConnectionsKey);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List)
          .map((e) => NasConnection.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(connections: list);
    } catch (_) {
      // 解析失败时忽略历史配置
    }
  }

  Future<void> _persistConnections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = state.connections.map((c) => c.toJson()).toList();
      await prefs.setString(_kNasConnectionsKey, jsonEncode(list));
    } catch (_) {}
  }

  // ──── 连接管理 ────

  /// 局域网自动发现 NAS（群晖/威联通/TrueNAS/自建…）
  ///
  /// 页面打开时与定时刷新时后台静默调用，不需要用户点按钮；
  /// 重新扫描期间保留上一次结果，避免列表闪烁。
  DateTime? _lastScanAt;

  Future<void> discoverNas({bool force = false}) async {
    if (state.isDiscovering) return;
    final now = DateTime.now();
    if (!force &&
        _lastScanAt != null &&
        now.difference(_lastScanAt!) < const Duration(seconds: 30)) {
      return; // 刚扫过，别重复占网络
    }
    _lastScanAt = now;
    state = state.copyWith(isDiscovering: true, discoverProgress: 0);
    try {
      final list = await NasDiscoveryService.instance.discover(
        onProgress: (done, total) {
          if (mounted && total > 0) {
            state = state.copyWith(discoverProgress: done / total);
          }
        },
      );
      // 没有局域网（如刚开机还没拿到 IP）→ 不记“已扫描”，尽快重试
      if (list.isEmpty && !await NasDiscoveryService.instance.hasLocalNetwork()) {
        _lastScanAt = null;
      }
      state = state.copyWith(
        isDiscovering: false,
        candidates: list,
        discoverProgress: 1,
      );
    } catch (e) {
      state = state.copyWith(
        isDiscovering: false,
        errorMessage: '搜索失败：$e',
      );
    }
  }

  void clearCandidates() {
    state = state.copyWith(candidates: const []);
  }

  Future<bool> addConnection(NasConnection config) async {
    final connections = List<NasConnection>.from(state.connections);
    connections.add(config);
    state = state.copyWith(connections: connections);
    await _persistConnections();
    return true;
  }

  Future<void> removeConnection(String id) async {
    final connections = state.connections.where((c) => c.id != id).toList();
    if (state.activeConnection?.id == id) {
      await disconnect();
    }
    state = state.copyWith(connections: connections);
    await _persistConnections();
  }

  Future<bool> connect(NasConnection config) async {
    state = state.copyWith(isLoading: true, clearError: true);

    final ok = await _service.connect(config);
    if (ok) {
      state = state.copyWith(
        isLoading: false,
        isConnected: true,
        activeConnection: config,
        currentPath: config.remotePath,
        clearError: true,
      );
      await navigateTo(config.remotePath);
    } else {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '连接失败，请检查地址、端口和账号密码',
      );
    }
    return ok;
  }

  Future<void> disconnect() async {
    await _service.disconnect();
    state = state.copyWith(
      isConnected: false,
      activeConnection: null,
      currentFiles: [],
      currentPath: '/',
    );
  }

  // ──── 文件浏览 ────

  Future<void> navigateTo(String path) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final files = await _service.listDirectory(path);
      state = state.copyWith(
        currentFiles: files,
        currentPath: path,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: '读取目录失败，请检查连接或目录权限',
      );
    }
  }

  void navigateUp() {
    final path = state.currentPath;
    if (path == '/' || path.isEmpty) return;
    final parent = path.substring(0, path.lastIndexOf('/'));
    navigateTo(parent.isEmpty ? '/' : parent);
  }

  /// 清除错误提示
  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(clearError: true);
    }
  }

  // ──── 获取播放 URL ────

  String getPlayableUrl(String path) {
    return _service.getPlayableUrl(path);
  }

  /// 检测 URL 是否可被 media_kit 播放
  bool isStreamable(NasFileItem file) {
    return file.isVideo;
  }
}

final nasProvider = StateNotifierProvider<NasNotifier, NasState>((ref) {
  return NasNotifier();
});