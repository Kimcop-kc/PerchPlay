import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/local_media_import_service.dart';
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
    } else if (Platform.isIOS) {
      // iOS 关键差异：照片库权限只影响「能否扫描相册视频」，
      // 沙盒 Documents 里的文件（用户通过「文件」App 放进来的、以及
      // 我们导入/导出的）**不需要任何权限**就能读。
      // 所以 iOS 上这个标志位恒为 true —— 否则用户拒绝照片库后，
      // 首页会一直卡在「需要授权读取本地视频」，连 Documents 里的
      // 视频都看不到（这是真实发生过的体验问题）。
      granted = true;
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
  ///
  /// iOS 语义不同：这里返回 true 表示「可以扫描本地文件」，而 iOS 的
  /// Documents 本来就不需要权限；照片库权限由 LocalMediaImportService
  /// 单独请求（只影响相册视频能否导出，不影响 Documents 扫描）。
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
    }
    if (Platform.isIOS) {
      // 顺带请求一次照片库权限（用户拒绝也不阻塞 Documents 扫描）
      try {
        await LocalMediaImportService.instance.requestPhotoLibraryPermission();
      } catch (_) {}
      state = state.copyWith(hasVideoPermission: true);
      return true;
    }
    final p = await _videoPermission.request();
    final ok = p.isGranted || p.isLimited;
    state = state.copyWith(hasVideoPermission: ok);
    return ok;
  }

  /// 打开应用设置（权限被永久拒绝时引导用户手动开启）
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
