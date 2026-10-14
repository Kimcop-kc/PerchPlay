import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/nas_connection_model.dart';
import '../services/nas_client_service.dart';

/// NAS 连接管理状态
class NasState {
  final List<NasConnection> connections;
  final NasConnection? activeConnection;
  final List<NasFileItem> currentFiles;
  final String currentPath;
  final bool isLoading;
  final String? errorMessage;
  final bool isConnected;

  const NasState({
    this.connections = const [],
    this.activeConnection,
    this.currentFiles = const [],
    this.currentPath = '/',
    this.isLoading = false,
    this.errorMessage,
    this.isConnected = false,
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
  }) {
    return NasState(
      connections: connections ?? this.connections,
      activeConnection: activeConnection ?? this.activeConnection,
      currentFiles: currentFiles ?? this.currentFiles,
      currentPath: currentPath ?? this.currentPath,
      isLoading: isLoading ?? this.isLoading,
      errorMessage:
          clearError ? null : (errorMessage ?? this.errorMessage),
      isConnected: isConnected ?? this.isConnected,
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