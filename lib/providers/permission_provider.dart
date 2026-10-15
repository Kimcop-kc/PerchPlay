import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/native_bridge_service.dart';

final permissionProvider =
    StateNotifierProvider<PermissionNotifier, PermissionState>(
  (ref) => PermissionNotifier(),
);

class PermissionState {
  final bool hasVideoPermission;

  /// 是否已获得「所有文件访问权限」（Android 11+ MANAGE_EXTERNAL_STORAGE）
  final bool hasAllFilesAccess;

  const PermissionState({
    this.hasVideoPermission = false,
    this.hasAllFilesAccess = false,
  });

  PermissionState copyWith({
    bool? hasVideoPermission,
    bool? hasAllFilesAccess,
  }) {
    return PermissionState(
      hasVideoPermission: hasVideoPermission ?? this.hasVideoPermission,
      hasAllFilesAccess: hasAllFilesAccess ?? this.hasAllFilesAccess,
    );
  }
}

class PermissionNotifier extends StateNotifier<PermissionState> {
  PermissionNotifier() : super(const PermissionState()) {
    // 延迟到微任务后检查，避免 provider 首次读取（build 期间）时修改 state
    Future.microtask(_checkPermissions);
  }

  /// Android 13+ 用 READ_MEDIA_VIDEO（Permission.videos），
  /// Android ≤12 用 READ_EXTERNAL_STORAGE（Permission.storage）。
  /// iOS 用 photos。
  Permission get _videoPermission {
    if (kIsWeb) return Permission.storage;
    if (Platform.isIOS) return Permission.photos;
    return Permission.videos;
  }

  Permission get _legacyStoragePermission => Permission.storage;

  Future<void> _checkPermissions() async {
    var granted = false;
    if (Platform.isAndroid) {
      // Android 13+ videos；否则 storage
      final v = await _videoPermission.status;
      if (v.isGranted || v.isLimited) {
        granted = true;
      } else {
        final s = await _legacyStoragePermission.status;
        granted = s.isGranted;
      }
    } else {
      final p = await _videoPermission.status;
      granted = p.isGranted || p.isLimited;
    }
    final allFiles = Platform.isAndroid
        ? await NativeBridgeService.instance.hasAllFilesAccess()
        : true;
    state = state.copyWith(
      hasVideoPermission: granted,
      hasAllFilesAccess: allFiles,
    );
  }

  /// 刷新「所有文件访问」状态（从系统设置页返回后调用）
  Future<void> refreshAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    final ok = await NativeBridgeService.instance.hasAllFilesAccess();
    state = state.copyWith(hasAllFilesAccess: ok);
  }

  /// 跳到系统「所有文件访问」授权开关页
  Future<void> requestAllFilesAccess() async {
    await NativeBridgeService.instance.requestAllFilesAccess();
  }

  /// 请求视频读取权限，返回是否已授权。
  Future<bool> requestVideoPermission() async {
    if (Platform.isAndroid) {
      // 先尝试新权限（Android 13+ 才会真正弹窗）
      final v = await _videoPermission.request();
      if (v.isGranted || v.isLimited) {
        state = state.copyWith(hasVideoPermission: true);
        return true;
      }
      // 回退到旧权限（Android ≤12）
      final s = await _legacyStoragePermission.request();
      final ok = s.isGranted || s.isLimited;
      state = state.copyWith(hasVideoPermission: ok);
      return ok;
    } else {
      final p = await _videoPermission.request();
      final ok = p.isGranted || p.isLimited;
      state = state.copyWith(hasVideoPermission: ok);
      return ok;
    }
  }

  /// 打开应用设置（权限被永久拒绝时引导用户手动开启）
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
