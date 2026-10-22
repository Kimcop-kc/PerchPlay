import 'package:package_info_plus/package_info_plus.dart';

/// 应用版本信息服务。
///
/// 用 package_info_plus 从系统读真实版本号（pubspec 的 version），
/// 避免 [AppConstants.appVersion] 硬编码与 pubspec 脱节的问题。
/// 应用内更新检查、关于页展示都从这里取。
class AppVersion {
  AppVersion._();

  static String _version = '';
  static String _buildNumber = '';

  /// 是否已从系统读取。
  static bool get isLoaded => _version.isNotEmpty;

  /// 版本号，如 `1.0.90`。
  static String get version => _version;

  /// 构建号，如 `90`。
  static String get buildNumber => _buildNumber;

  /// 完整显示串，如 `1.0.90`。
  static String get display => _version;

  /// 从系统读取版本信息（幂等，只在首次真正读取）。
  static Future<void> ensureLoaded() async {
    if (isLoaded) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version;
      _buildNumber = info.buildNumber;
    } catch (_) {
      // 读取失败时回退到空串，调用方自行兜底
    }
  }
}
