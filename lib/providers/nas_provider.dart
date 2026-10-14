import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    bool? isConnected,
  }) {
    return NasState(
      connections: connections ?? this.connections,
      activeConnection: activeConnection ?? this.activeConnection,
      currentFiles: currentFiles ?? this.currentFiles,
      currentPath: currentPath ?? this.currentPath,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

class NasNotifier extends StateNotifier<NasState> {
  final NasClientService _service = NasClientService.instance;

  NasNotifier() : super(const NasState());

  // ──── 连接管理 ────

  Future<bool> addConnection(NasConnection config) async {
    final connections = List<NasConnection>.from(state.connections);
    connections.add(config);
    state = state.copyWith(connections: connections);
    return true;
  }

  Future<void> removeConnection(String id) async {
    final connections = state.connections.where((c) => c.id != id).toList();
    if (state.activeConnection?.id == id) {
      await disconnect();
    }
    state = state.copyWith(connections: connections);
  }

  Future<bool> connect(NasConnection config) async {
    state = state.copyWith(isLoading: true, errorMessage: null);

    final ok = await _service.connect(config);
    if (ok) {
      state = state.copyWith(
        isLoading: false,
        isConnected: true,
        activeConnection: config,
        currentPath: config.remotePath,
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
    state = state.copyWith(isLoading: true);
    final files = await _service.listDirectory(path);
    state = state.copyWith(
      currentFiles: files,
      currentPath: path,
      isLoading: false,
    );
  }

  void navigateUp() {
    final path = state.currentPath;
    if (path == '/' || path.isEmpty) return;
    final parent = path.substring(0, path.lastIndexOf('/'));
    navigateTo(parent.isEmpty ? '/' : parent);
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