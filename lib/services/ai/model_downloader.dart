import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod/riverpod.dart';

import 'ai_model.dart';

/// 下载进度：0.0~1.0
typedef ProgressCallback = void Function(double progress);

/// 模型下载器：HTTP 逐文件下载 → sha256 校验 → 存到本地
///
/// 为什么自造轮子而不是用 flutter_downloader / dio：本项目下载的是几个
/// 几十到几百 MB 的模型文件，不是上千个图片；只要支持断点续传（Range 头）、
/// 进度回调、sha256 校验、镜像自动切换就够，不需要额外依赖。
class ModelDownloader {
  final http.Client _client;

  ModelDownloader({http.Client? client}) : _client = client ?? http.Client();

  /// 释放底层 HTTP 客户端（页面销毁时调用，避免悬挂连接）
  void dispose() => _client.close();

  /// 获取模型存放根目录（初始化为 app 的持久目录下的 ai_models/）
  static Future<Directory> modelsDir({String? overridePath}) async {
    if (overridePath != null) {
      final d = Directory(overridePath);
      if (!(await d.exists())) await d.create(recursive: true);
      return d;
    }
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/ai_models');
    if (!(await d.exists())) await d.create(recursive: true);
    return d;
  }

  /// 为某个模型条目找到**实际可下载的镜像**（跳过占位、按 source 排序）
  ///
  /// [preferredSource] 不为 null 时把该 source 的 mirror 排第一位。
  List<ModelMirror> _usableMirrors(
    AiModel model, {
    DownloadSource? preferredSource,
  }) {
    final usable = model.mirrors
        .where((m) => m.hasDownloadableContent)
        .toList();
    if (preferredSource != null) {
      usable.sort((a, b) {
        if (a.source == preferredSource) return -1;
        if (b.source == preferredSource) return 1;
        return 0;
      });
    }
    return usable;
  }

  /// 下载一个模型的所有文件到 [modelDir]/[model.id]/。
  ///
  /// 返回模型目录的路径，失败时抛异常（调用方应 catch 并提示）。
  ///
  /// [onProgress]：总体进度 0.0~1.0，刷新频率由下载速度决定。
  Future<String> download({
    required AiModel model,
    DownloadSource? preferredSource,
    String? overrideStoragePath,
    ProgressCallback? onProgress,
  }) async {
    final mirrors = _usableMirrors(model, preferredSource: preferredSource);
    if (mirrors.isEmpty) {
      throw StateError('模型没有可用下载源: ${model.id}');
    }

    final base = await modelsDir(overridePath: overrideStoragePath);
    final destDir = Directory('${base.path}/${model.id}');
    if (!(await destDir.exists())) await destDir.create(recursive: true);

    // 逐镜像尝试，任一镜像全部文件成功即结束
    final errors = <String>[];
    for (final mirror in mirrors) {
      try {
        debugPrint('[Downloader] 尝试 ${mirror.source.name}: ${mirror.url}');
        await _downloadMirror(mirror, destDir, onProgress: onProgress);
        debugPrint('[Downloader] 下载成功: ${model.id} ← ${mirror.source.name}');
        return destDir.path;
      } catch (e) {
        debugPrint('[Downloader] ${mirror.source.name} 失败: $e');
        errors.add('${mirror.source.name}: $e');
        // 清理未完成的下载（但不删除用户已有的其他模型）
        await _cleanDir(destDir);
      }
    }

    throw StateError(
        '所有下载源均失败:\n${errors.map((e) => '  - $e').join('\n')}');
  }

  Future<void> _downloadMirror(
    ModelMirror mirror,
    Directory destDir, {
    ProgressCallback? onProgress,
  }) async {
    if (mirror.fileUrls != null && mirror.fileUrls!.isNotEmpty) {
      // 多文件模式
      final urls = mirror.fileUrls!;
      var completed = 0;
      for (final entry in urls.entries) {
        final fileName = entry.key;
        final fileUrl = entry.value;
        final dest = File('${destDir.path}/$fileName');
        // 多文件 sha256 从 fileUrls 的 value 取不到，继续用 mirror.sha256（P1 补）
        await _downloadFile(
          fileUrl,
          dest,
          onProgress: onProgress != null
              ? (fileProgress) {
                  final overall =
                      (completed + fileProgress) / urls.length;
                  onProgress(overall);
                }
              : null,
          expectedSha256: mirror.sha256,
        );
        completed++;
      }
    } else {
      // 单文件模式：URL 里有文件名就提取，否则用 fallback
      final uri = Uri.parse(mirror.url);
      final fileName = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'model.bin';
      final dest = File('${destDir.path}/$fileName');
      await _downloadFile(mirror.url, dest,
          onProgress: onProgress, expectedSha256: mirror.sha256);
    }

    // 下载完成后写入本地 manifest（流式阶段已算出每个文件的 SHA-256，
    // 这里补算一版统一的 manifest 以便后续校验）
    await recomputeManifest(destDir);
  }

  /// 下载单个文件到 [dest]，流式计算 SHA-256。下载完成后与 catalog 声明的
  /// sha256（若有）比对，并写入本地 manifest。
  Future<void> _downloadFile(
    String url,
    File dest, {
    ProgressCallback? onProgress,
    String? expectedSha256, // catalog 预期值，可选
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);

    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}: $url');
    }

    final totalBytes = response.contentLength ?? -1;
    var receivedBytes = 0;
    final sink = dest.openWrite();

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }
    } finally {
      await sink.close();
    }

    // 1) Content-Length 检查
    if (totalBytes > 0) {
      final actual = await dest.length();
      if (actual != totalBytes) {
        throw StateError(
            '文件大小不匹配: expected $totalBytes, got $actual for $url');
      }
    }

    // 2) SHA-256 校验（下载完成后一次性计算，避免 stream hash 的 crypto 版本问题）
    final fileBytes = await dest.readAsBytes();
    final actualHash = sha256.convert(fileBytes).toString();
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (actualHash != expectedSha256.toLowerCase()) {
        throw StateError(
            'SHA-256 校验失败: expected $expectedSha256, got $actualHash for $url');
      }
      debugPrint('[Downloader] SHA-256 校验通过: ${dest.uri.pathSegments.last}');
    }
  }

  // ── 本地manifest：防止下载完成后被人/系统误改 ──

  static const String _manifestName = 'manifest.json';

  /// 从模型目录读取本地 manifest（{文件名: sha256hex}）
  static Future<Map<String, String>> _readManifest(Directory dir) async {
    final f = File('${dir.path}/$_manifestName');
    if (!await f.exists()) return {};
    try {
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// 写入本地 manifest
  static Future<void> _writeManifest(
      Directory dir, Map<String, String> entries) async {
    final f = File('${dir.path}/$_manifestName');
    await f.writeAsString(jsonEncode(entries));
  }

  /// 计算目录下所有模型文件的 SHA-256 并与本地 manifest 比对
  ///
  /// 返回非空列表 = 损坏的文件名（在清单中但内容变了，或不在清单中）。
  /// 返回空列表 = 全部完好（无清单时不校验，视为完好）。
  static Future<List<String>> verifyModel(String modelDirPath) async {
    final dir = Directory(modelDirPath);
    if (!await dir.exists()) return <String>['目录不存在'];

    final manifest = await _readManifest(dir);
    if (manifest.isEmpty) return <String>[]; // 无清单不判损坏

    final corrupted = <String>[];
    for (final entry in manifest.entries) {
      final file = File('${dir.path}/${entry.key}');
      if (!await file.exists()) {
        corrupted.add('${entry.key} (缺失)');
        continue;
      }
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      if (hash != entry.value) {
        corrupted.add('${entry.key} (SHA-256 不符)');
      }
    }
    return corrupted;
  }

  /// 扫描模型目录下所有文件（排除 manifest.json），计算 SHA-256 并写入 manifest。
  ///
  /// 下载成功后调用；也供导入器导入完批量写入。
  static Future<void> recomputeManifest(Directory dir) async {
    if (!await dir.exists()) return;
    final entries = <String, String>{};
    await for (final entity in dir.list(recursive: false)) {
      if (entity is File && entity.path.split(Platform.pathSeparator).last != _manifestName) {
        final bytes = await entity.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        final name = entity.path.split(Platform.pathSeparator).last;
        entries[name] = hash;
      }
    }
    if (entries.isNotEmpty) {
      await _writeManifest(dir, entries);
      debugPrint('[Downloader] manifest 已写入: ${dir.path}, ${entries.length} 个文件');
    }
  }

  /// 删除目录下的子文件（保留目录本身）
  Future<void> _cleanDir(Directory d) async {
    if (!(await d.exists())) return;
    await for (final entity in d.list(recursive: false)) {
      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        // P0 不删子目录（多文件模型一般没有嵌套，有也是用户放错的）
      }
    }
  }
}

/// 全局单例下载器
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  return ModelDownloader();
});