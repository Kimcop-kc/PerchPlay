import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';

/// 把 Flutter assets 里的 mpv 着色器释放到磁盘，并返回可加载的目录。
///
/// ## 为什么必须释放到磁盘
///
/// mpv 的 `glsl-shader` 参数只接受**文件系统路径**。Flutter 的 asset 在
/// Android 上是 APK 内 zip 条目（`flutter_assets/...`），mpv 的 fopen
/// 读不到。所以必须先解到应用私有目录。
///
/// ## 为什么不能平铺
///
/// hdr-toys / Anime4K 的着色器虽然目前没有跨文件 `#include`，但它们的
/// `//!HOOK` 语法依赖**文件名**（mpv 用文件名做缓存 key）。保持原始
/// 文件名不变即可，目录层级可以扁平化 —— 但为了将来上游加了 include
/// 不至于失效，这里仍按原目录结构复制。
///
/// ## 幂等与版本
///
/// 用 `.version` 标记文件判断是否已释放。上游更新或 asset 内容变化时，
/// 改 [version] 即可触发重新释放。
class ShaderAssetInstaller {
  /// [assetDir]：assets 下的子目录，如 `assets/hdr-toys/shaders/hdr-toys`
  /// [version]：内容版本，变了就重新释放
  /// [cacheName]：磁盘上的目录名，避免两套着色器互相覆盖
  ShaderAssetInstaller({
    required this.assetDir,
    required this.version,
    required this.cacheName,
  });

  final String assetDir;
  final String version;
  final String cacheName;

  Directory? _root;

  /// 着色器根目录（mpv 的 glsl-shader 以此拼相对路径）。
  Directory? get root => _root;

  bool get isReady => _root != null;

  /// 确保已释放。重复调用安全。
  ///
  /// 返回着色器根目录；失败返回 null（调用方应回退到「关闭」）。
  Future<Directory?> ensureInstalled() async {
    if (_root != null) return _root;

    // gpu-next / hook 着色器目前只在 Android 的自建 libmpv 上有意义
    if (!animeOrHdrShaderSupported) {
      debugPrint('[Shader] 非 Android 平台，跳过 $cacheName');
      return null;
    }

    try {
      final support = await getApplicationSupportDirectory();
      final base = Directory('${support.path}/shaders/$cacheName');
      final marker = File('${base.path}/.version');
      final target = Directory(base.path);

      if (await marker.exists()) {
        final v = (await marker.readAsString()).trim();
        if (v == version) {
          // 至少确认有一个 .glsl，避免空目录被当成已释放
          final any = await _firstGlsl(target);
          if (any != null) {
            _root = target;
            debugPrint('[Shader] 复用 $cacheName: ${target.path}');
            return target;
          }
        }
      }

      if (await base.exists()) {
        await base.delete(recursive: true);
      }
      await base.create(recursive: true);

      final count = await _copyAssetTree(assetDir, base);
      if (count == 0) {
        debugPrint('[Shader] ⚠ $cacheName 没有释放出任何 .glsl，'
            '检查 pubspec assets 配置（$assetDir）');
        return null;
      }

      await marker.writeAsString(version);
      _root = base;
      debugPrint('[Shader] 已释放 $count 个 $cacheName 着色器到 ${base.path}');
      return base;
    } catch (e, st) {
      debugPrint('[Shader] 释放 $cacheName 失败: $e\n$st');
      return null;
    }
  }

  /// 递归复制 asset 目录树，返回复制的 .glsl 数量。
  Future<int> _copyAssetTree(String assetDir, Directory dest) async {
    // Flutter 没有「列 asset 目录」的 API，用 AssetManifest 反查。
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((a) => a.startsWith('$assetDir/') && a.endsWith('.glsl'))
        .toList();

    var n = 0;
    for (final a in assets) {
      try {
        final data = await rootBundle.load(a);
        final rel = a.substring(assetDir.length + 1);
        final out = File('${dest.path}/$rel');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        n++;
      } catch (e) {
        debugPrint('[Shader] 复制 $a 失败: $e');
      }
    }
    return n;
  }

  Future<String?> _firstGlsl(Directory dir) async {
    if (!await dir.exists()) return null;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.glsl')) return e.path;
    }
    return null;
  }
}

/// hook 着色器（gpu-next + libplacebo）在当前平台是否可用。
///
/// 只有 Android 的自建 libmpv 打开了 libplacebo / vulkan / shaderc。
/// 见 tools/patch_libplacebo.sh 与 tools/build_android_libmpv.sh。
bool get animeOrHdrShaderSupported {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

/// Anime4K 着色器释放器。
ShaderAssetInstaller get anime4kShaderInstaller => _anime4k;

final _anime4k = ShaderAssetInstaller(
  assetDir: 'assets/anime4k/shaders/anime4k',
  version: '1',
  cacheName: 'anime4k',
);

/// hdr-toys 着色器释放器。
ShaderAssetInstaller get hdrToysShaderInstaller => _hdrToys;

final _hdrToys = ShaderAssetInstaller(
  assetDir: 'assets/hdr-toys/shaders/hdr-toys',
  version: '1',
  cacheName: 'hdr-toys',
);
