import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';
import 'native_bridge_service.dart';

/// 一次更新检查的结果。
class UpdateInfo {
  final bool hasUpdate;
  final String latestVersion;
  final String downloadUrl;
  final String? releaseNotes;

  const UpdateInfo({
    required this.hasUpdate,
    required this.latestVersion,
    required this.downloadUrl,
    this.releaseNotes,
  });
}

/// 应用内更新服务：查询 GitHub 最新 release，下载 APK，触发系统安装。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// GitHub 仓库（与 pubspec 的 repository 一致）。
  static const String _repo = 'Kimcop-kc/PerchPlay';

  /// 下载进度回调（0.0 ~ 1.0），null 表示不关心进度。
  void Function(double progress)? onProgress;

  /// 检查是否有新版本。
  ///
  /// 通过 GitHub Releases API 拿最新非预发布 release，比较 tag 里的版本号
  /// （形如 `v1.0.90`）与当前 [AppVersion.version]。
  Future<UpdateInfo> checkForUpdate() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(
          Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        );
        req.headers.set(HttpHeaders.userAgentHeader, 'PerchPlay');
        req.headers
            .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          return const UpdateInfo(
            hasUpdate: false,
            latestVersion: '',
            downloadUrl: '',
          );
        }
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        // prerelease / draft 跳过（只认正式版）
        if (json['prerelease'] == true || json['draft'] == true) {
          return const UpdateInfo(
            hasUpdate: false,
            latestVersion: '',
            downloadUrl: '',
          );
        }

        final tag = (json['tag_name'] as String?) ?? '';
        final latestVersion = _stripV(tag);

        // 找可下载的资产：
        //  - Android：arm64-v8a 的 APK（本应用只打包 64 位）
        //  - iOS：IPA（iOS 不允许应用自安装，只用于「去下载」引导）
        final assets = (json['assets'] as List<dynamic>?) ?? const [];
        String? apkUrl;
        String? ipaUrl;
        for (final a in assets) {
          final name = (a as Map)['name'] as String? ?? '';
          final url = a['browser_download_url'] as String? ?? '';
          final lower = name.toLowerCase();
          if (lower.endsWith('.apk')) {
            // 优先带 arm64 标识的；否则就用第一个 apk
            if (apkUrl == null || lower.contains('arm64')) apkUrl = url;
            if (lower.contains('arm64')) break;
          } else if (lower.endsWith('.ipa') && ipaUrl == null) {
            ipaUrl = url;
          }
        }

        // iOS 上没有 apk 也要能报出新版本（否则「检查更新」永远说已是最新）
        final downloadUrl = !kIsWeb && Platform.isIOS
            ? (ipaUrl ?? '')
            : (apkUrl ?? '');
        final hasUpdate = latestVersion.isNotEmpty &&
            _compareVersions(latestVersion, AppVersion.version) > 0 &&
            (kIsWeb || Platform.isIOS || apkUrl != null);

        return UpdateInfo(
          hasUpdate: hasUpdate,
          latestVersion: latestVersion,
          downloadUrl: downloadUrl,
          releaseNotes: json['body'] as String?,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Update] 检查更新失败: $e');
      return const UpdateInfo(
        hasUpdate: false,
        latestVersion: '',
        downloadUrl: '',
      );
    }
  }

  /// 下载 APK 到缓存目录并返回本地路径。
  ///
  /// 下载过程中通过 [onProgress] 回报进度（0.0~1.0）。
  Future<String?> downloadApk(String url) async {
    try {
      final dir = await getTemporaryDirectory();
      final updatesDir = Directory('${dir.path}/updates');
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }
      final file = File('${updatesDir.path}/perchplay_update.apk');

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        if (resp.statusCode != 200) return null;

        final total = resp.contentLength;
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress?.call(received / total);
          }
        }
        await sink.close();

        return file.path;
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[Update] 下载失败: $e');
      return null;
    }
  }

  /// 触发系统安装器安装 APK。
  Future<bool> installApk(String path) {
    return NativeBridgeService.instance.installApk(path);
  }

  /// 去掉 tag 前面的 v（`v1.0.90` → `1.0.90`）。
  static String _stripV(String tag) {
    return tag.startsWith('v') ? tag.substring(1) : tag;
  }

  /// 比较两个 x.y.z 版本号。返回 >0 表示 [a] 更新，<0 表示 [a] 更旧，0 相同。
  static int _compareVersions(String a, String b) {
    final pa = _parseVersion(a);
    final pb = _parseVersion(b);
    for (var i = 0; i < 3; i++) {
      final d = pa[i] - pb[i];
      if (d != 0) return d;
    }
    return 0;
  }

  static List<int> _parseVersion(String v) {
    final parts = v.split('.');
    return [
      parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
    ];
  }
}
