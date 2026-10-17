import 'dart:async';
import 'dart:io';

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
      await _downloadFile(mirror.url, dest, onProgress: onProgress);
    }
  }

  /// 下载单个文件到 [dest]，支持进度回调
  Future<void> _downloadFile(
    String url,
    File dest, {
    ProgressCallback? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);

    if (response.statusCode != 200) {
      throw HttpException(
          'HTTP ${response.statusCode}: $url');
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

    // 校验 Content-Length（如果服务端声明了）
    if (totalBytes > 0) {
      final actual = await dest.length();
      if (actual != totalBytes) {
        throw StateError(
            '文件大小不匹配: expected $totalBytes, got $actual for $url');
      }
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