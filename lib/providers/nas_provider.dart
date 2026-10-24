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
      if (mounted) {
        state = state.copyWith(connections: list);
      }
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
  DateTime? _lastScanAt;

  Future<void> discoverNas({bool force = false}) async {
    if (state.isDiscovering) return;
    final now = DateTime.now();
    if (!force &&
        _lastScanAt != null &&
        now.difference(_lastScanAt!) < const Duration(seconds: 30)) {
      return;
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
      if (list.isEmpty &&
          !await NasDiscoveryService.instance.hasLocalNetwork()) {
        _lastScanAt = null;
      }
      if (mounted) {
        state = state.copyWith(
          isDiscovering: false,
          candidates: list,
          discoverProgress: 1,
        );
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isDiscovering: false,
          errorMessage: '搜索失败：$e',
        );
      }
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
      await disconnectFrom(id);
    }
    state = state.copyWith(connections: connections);
    await _persistConnections();
  }

  /// 修改已有连接的配置（地址 / 账号 / 路径等）。
  ///
  /// 三个必须做的动作：
  ///  1. 换掉列表里那一项（按 id 匹配）
  ///  2. **断开旧连接**：`_NasConnection` 里缓存着 HttpClient / FTP socket /
  ///     SMB pool，都还拿着旧的主机与凭据。不先断开的话，改完密码再连接
  ///     仍会走旧连接，表现为「改了没用」。
  ///  3. 如果改的是当前活跃连接，重新连一次并回到配置的路径
  Future<bool> updateConnection(NasConnection config) async {
    final idx = state.connections.indexWhere((c) => c.id == config.id);
    if (idx < 0) return false;

    final wasActive = state.activeConnection?.id == config.id;

    // 先断开旧连接，避免复用带旧凭据的连接对象
    await _service.disconnect(config.id);

    final connections = List<NasConnection>.from(state.connections);
    connections[idx] = config;
    state = state.copyWith(
      connections: connections,
      // 活跃连接同步换成新配置（否则界面上显示的仍是旧地址）
      activeConnection: wasActive ? config : state.activeConnection,
    );
    await _persistConnections();

    if (wasActive) {
      // 重连：拿新凭据建立连接并回到配置路径
      return connect(config);
    }
    return true;
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

  /// 断开某个连接并回到列表
  Future<void> disconnectFrom(String id) async {
    await _service.disconnect(id);
    if (state.activeConnection?.id == id) {
      state = state.copyWith(
        isConnected: false,
        activeConnection: null,
        currentFiles: [],
        currentPath: '/',
      );
    }
  }

  /// 切换到另一个 NAS 连接（当前有活跃连接时）
  Future<bool> switchTo(NasConnection config) async {
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

  /// 回到连接列表（不断开当前连接，允许再切回）
  void backToList() {
    state = state.copyWith(
      isConnected: false,
      activeConnection: null,
      currentFiles: [],
      currentPath: '/',
    );
  }

  // ──── 文件浏览 ────

  Future<void> navigateTo(String path) async {
    final connId = state.activeConnection?.id;
    if (connId == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final files = await _service.listDirectory(connId, path);
      // 服务层把异常转成空数组了，靠标记区分「真的空」和「读取失败」。
      // 不这样处理的话，路径写错 / 认证失败都会显示成「空目录」，
      // 用户完全看不出哪里错了 —— 这正是「连接没报错但看不到文件」的来源。
      final failed = _service.lastListFailed;
      final errDetail = _service.lastListError;
      if (mounted) {
        state = state.copyWith(
          currentFiles: failed ? const [] : files,
          currentPath: path,
          isLoading: false,
          errorMessage: failed
              ? (errDetail.isNotEmpty
                  ? '读取目录失败：$errDetail'
                  : '读取目录失败，请检查连接或目录权限')
              : null,
          clearError: !failed,
        );
      }
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: '读取目录失败：$e',
        );
      }
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
    final connId = state.activeConnection?.id;
    if (connId == null) return '';
    return _service.getPlayableUrl(connId, path);
  }

  /// 检测 URL 是否可被 media_kit 播放
  bool isStreamable(NasFileItem file) {
    return file.isVideo;
  }
}

final nasProvider = StateNotifierProvider<NasNotifier, NasState>((ref) {
  return NasNotifier();
});