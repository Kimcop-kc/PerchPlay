import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

final permissionProvider =
    StateNotifierProvider<PermissionNotifier, PermissionState>(
  (ref) => PermissionNotifier(),
);

class PermissionState {
  final bool hasStoragePermission;

  const PermissionState({this.hasStoragePermission = false});

  PermissionState copyWith({bool? hasStoragePermission}) {
    return PermissionState(
      hasStoragePermission: hasStoragePermission ?? this.hasStoragePermission,
    );
  }
}

class PermissionNotifier extends StateNotifier<PermissionState> {
  PermissionNotifier() : super(const PermissionState()) {
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final status = await Permission.storage.status;
    state = state.copyWith(hasStoragePermission: status.isGranted);
  }

  Future<bool> requestStoragePermission() async {
    final status = await Permission.storage.request();
    final granted = status.isGranted;
    state = state.copyWith(hasStoragePermission: granted);
    return granted;
  }
}