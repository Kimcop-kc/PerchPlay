import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod/riverpod.dart';

import 'ai_model.dart';

/// 下载进度：0.0~1.0
typedef ProgressCallback = void Function(double progress);

/// 模型下载器：分片并发 + 断点续传 + SHA-256 完整性校验
///
/// 核心机制（对标 Hydra / pdman）：
/// - HTTP Range 请求把一个大文件切成 N 片，最多 4 片并发下载
/// - 每片落到 .part.N 临时文件，进度记在 .dstate
/// - 网络中断 → 下次启动读取 .dstate → 跳过已完成的片 → 只补未完成的
/// - 所有片完成 → 合并 .part → 全量 SHA-256 校验 → 删 .part / .dstate
/// - 服务器不支持 Range → 回退到单流下载
class ModelDownloader {
  final http.Client _client;

  ModelDownloader({http.Client? client}) : _client = client ?? http.Client();

  /// 释放底层 HTTP 客户端（页面销毁时调用，避免悬挂连接）
  void dispose() => _client.close();

  // ── 分片参数 ──
  /// 每片大约 16 MB
  static const int _chunkTargetSize = 16 * 1024 * 1024;

  /// 最多 16 片
  static const int _maxChunks = 16;

  /// 最多 4 片同时下载（太高会被运营商限速/封 IP）
  static const int _maxParallel = 4;

  /// 单片重试次数
  static const int _chunkRetries = 2;

  // ── 路径 ──

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

  // ── 镜像选择 ──

  /// 为某个模型条目找到**实际可下载的镜像**（跳过占位、按 source 排序）
  ///
  /// [preferredSource] 不为 null 时把该 source 的 mirror 排第一位。
  List<ModelMirror> _usableMirrors(
    AiModel model, {
    DownloadSource? preferredSource,
  }) {
    final usable =
        model.mirrors.where((m) => m.hasDownloadableContent).toList();
    if (preferredSource != null) {
      usable.sort((a, b) {
        if (a.source == preferredSource) return -1;
        if (b.source == preferredSource) return 1;
        return 0;
      });
    }
    return usable;
  }

  // ── 顶层入口 ──

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
        debugPrint(
            '[Downloader] 下载成功: ${model.id} ← ${mirror.source.name}');
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

  // ── 镜像下载 ──

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
        final expected = mirror.sha256ForFile(fileName);
        await _downloadFile(
          fileUrl,
          dest,
          onProgress: onProgress != null
              ? (fileProgress) {
                  final overall = (completed + fileProgress) / urls.length;
                  onProgress(overall);
                }
              : null,
          expectedSha256: expected,
        );
        completed++;
      }
    } else {
      // 单文件模式
      final uri = Uri.parse(mirror.url);
      final fileName = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'model.bin';
      final dest = File('${destDir.path}/$fileName');
      await _downloadFile(mirror.url, dest,
          onProgress: onProgress, expectedSha256: mirror.sha256);

      // GitHub Release .tar.bz2 → 自动解压到目标目录
      if (fileName.endsWith('.tar.bz2') || fileName.endsWith('.tar.gz') || fileName.endsWith('.zip')) {
        await _decompressArchive(dest, destDir);
      }
    }

    // 下载完成后写入本地 manifest
    await recomputeManifest(destDir);
  }

  // ── 单文件下载（分片 / 断点续传 / 回退） ──

  /// 下载单个文件。
  ///
  /// 优先走分片并发 + 断点续传；服务器不支持 Range 则回退到单流。
  Future<void> _downloadFile(
    String url,
    File dest, {
    ProgressCallback? onProgress,
    String? expectedSha256,
  }) async {
    // 1) 读已有 .dstate，看能不能续传
    final dstateFile = File('${dest.path}.dstate');
    final Map<String, dynamic>? saved = await _loadDState(dstateFile);

    if (saved != null) {
      final savedUrl = saved['url'] as String?;
      final savedSha = saved['expectedSha256'] as String?;
      // 同 URL + 同预期 SHA = 可续传
      if (savedUrl == url && _sameSha(savedSha, expectedSha256)) {
        debugPrint('[Downloader] 发现断点续传状态，恢复下载: ${dest.uri.pathSegments.last}');
        await _resumeChunked(url, dest, dstateFile, saved,
            onProgress: onProgress);
        return;
      }
      // URL 或预期 SHA 变了 → 旧状态作废
      debugPrint('[Downloader] 下载源已变，丢弃旧 .dstate');
      await _deleteParts(dest, (saved['chunkCount'] as int?) ?? 0);
      await dstateFile.delete();
    }

    // 2) HEAD 探测 Range 支持 + 总大小
    final (totalBytes, supportsRange) = await _probeServer(url);

    if (totalBytes == null || totalBytes <= 0 || !supportsRange) {
      // 回退：单连接流式下载（带 SHA-256 即时校验）
      await _downloadStreaming(url, dest,
          onProgress: onProgress, expectedSha256: expectedSha256);
      return;
    }

    // 3) 分片并发下载（HF LFS CDN 可能吞 Range 头 → 失败时自动回退流式）
    try {
      await _downloadChunked(url, dest, dstateFile, totalBytes,
          onProgress: onProgress, expectedSha256: expectedSha256);
    } catch (e) {
      debugPrint('[Downloader] 分片下载失败，回退到单流: $e');
      final (chunkCount, _) = _chunkPlan(totalBytes);
      await _cleanChunkState(dest, dstateFile, chunkCount);
      await _downloadStreaming(url, dest,
          onProgress: onProgress, expectedSha256: expectedSha256);
    }
  }

  // ── 服务器探测 ──

  /// HEAD 请求拿到 Content-Length 和 Accept-Ranges。
  /// 返回 (totalBytes, supportsRange)。
  Future<(int?, bool)> _probeServer(String url) async {
    try {
      final headReq = http.Request('HEAD', Uri.parse(url));
      final headResp = await _client.send(headReq);
      final totalBytes = headResp.contentLength;
      final headers = headResp.headers;
      // 有些 CDN 返回 Accept-Ranges: bytes，有些不返回但实际支持
      // 以 Content-Length > 0 为主要判断
      final hasRange = headers['accept-ranges'] == 'bytes';
      // 即使没声明，Content-Length > 0 也尝试分片（实际 Range 支持的概率很高）
      final supports = hasRange || (totalBytes != null && totalBytes > 0);
      debugPrint(
          '[Downloader] HEAD: total=$totalBytes, accept-ranges=${headers['accept-ranges']}, '
          'willChunk=$supports');
      return (totalBytes, supports);
    } catch (e) {
      debugPrint('[Downloader] HEAD 失败: $e，回退到流式下载');
      return (null, false);
    }
  }

  // ── 分片规划 ──

  /// 根据文件大小决定片数和每片大小。
  (int count, int size) _chunkPlan(int totalBytes) {
    if (totalBytes <= _chunkTargetSize) return (1, totalBytes);
    var count = (totalBytes / _chunkTargetSize).ceil();
    count = count.clamp(2, _maxChunks);
    final size = (totalBytes / count).ceil();
    return (count, size);
  }

  // ── 全新分片下载 ──

  Future<void> _downloadChunked(
    String url,
    File dest,
    File dstateFile,
    int totalBytes, {
    ProgressCallback? onProgress,
    String? expectedSha256,
  }) async {
    final (chunkCount, chunkSize) = _chunkPlan(totalBytes);

    final dstate = <String, dynamic>{
      'url': url,
      'expectedSha256': expectedSha256,
      'totalBytes': totalBytes,
      'chunkCount': chunkCount,
      'chunkSize': chunkSize,
      'chunks': <Map<String, dynamic>>[
        for (var i = 0; i < chunkCount; i++)
          <String, dynamic>{
            'index': i,
            'sha256': null, // null = 未完成
          },
      ],
    };
    await _saveDState(dstateFile, dstate);

    await _downloadRemainingChunks(
        url, dest, dstateFile, dstate, chunkSize, totalBytes,
        onProgress: onProgress);

    await _mergeAndVerify(dest, dstateFile, chunkCount,
        expectedSha256: expectedSha256);
  }

  // ── 续传 ──

  Future<void> _resumeChunked(
    String url,
    File dest,
    File dstateFile,
    Map<String, dynamic> dstate, {
    ProgressCallback? onProgress,
  }) async {
    final totalBytes = dstate['totalBytes'] as int;
    final chunkCount = dstate['chunkCount'] as int;
    final chunkSize = dstate['chunkSize'] as int;
    final chunks = dstate['chunks'] as List<dynamic>;

    // 重验所有标记为已完成的 .part 文件（防止磁盘位翻转或被截断）
    var verified = 0;
    for (final c in chunks) {
      final chunk = c as Map<String, dynamic>;
      final index = chunk['index'] as int;
      final savedSha = chunk['sha256'] as String?;
      if (savedSha == null) break; // 从这里往后全是未完成的
      final part = _partFile(dest, index);
      if (await part.exists()) {
        final actual = await _sha256File(part);
        if (actual == savedSha) {
          verified++;
          continue;
        }
        // 校验失败：重置此片及之后所有片
        debugPrint('[Downloader] 分片 $index 校验失败（expected $savedSha got $actual），重新下载');
      }
      // 从此片开始全部重置
      for (var j = index; j < chunkCount; j++) {
        (chunks[j] as Map<String, dynamic>)['sha256'] = null;
        final p = _partFile(dest, j);
        if (await p.exists()) await p.delete();
      }
      break;
    }

    if (verified > 0) {
      debugPrint('[Downloader] 续传：$verified / $chunkCount 片已通过校验，继续下载剩余');
    }

    await _saveDState(dstateFile, dstate);
    await _downloadRemainingChunks(
        url, dest, dstateFile, dstate, chunkSize, totalBytes,
        onProgress: onProgress, completedChunks: verified);

    await _mergeAndVerify(dest, dstateFile, chunkCount,
        expectedSha256: dstate['expectedSha256'] as String?);
  }

  // ── 下载所有未完成的片 ──

  Future<void> _downloadRemainingChunks(
    String url,
    File dest,
    File dstateFile,
    Map<String, dynamic> dstate,
    int chunkSize,
    int totalBytes, {
    ProgressCallback? onProgress,
    int completedChunks = 0,
  }) async {
    final chunkCount = dstate['chunkCount'] as int;
    final chunks = dstate['chunks'] as List<dynamic>;

    // 每片进度（0.0~1.0），用于跨片聚合
    final chunkProgress = List<double>.filled(chunkCount, 0.0);

    void notifyProgress() {
      if (onProgress == null) return;
      var sum = completedChunks.toDouble();
      for (var i = 0; i < chunkCount; i++) {
        if ((chunks[i] as Map<String, dynamic>)['sha256'] != null) {
          // 已经完成 → 1.0
          sum += 1.0;
        } else {
          sum += chunkProgress[i];
        }
      }
      onProgress(sum / chunkCount);
    }

    // 找出所有未完成的片索引
    final pending = <int>[];
    for (final c in chunks) {
      final chunk = c as Map<String, dynamic>;
      if (chunk['sha256'] == null) {
        pending.add(chunk['index'] as int);
      }
    }

    if (pending.isEmpty) return; // 全部完成了

    debugPrint('[Downloader] 剩余 ${pending.length} 片待下载，最多 $_maxParallel 并发');

    // 分批处理（每批最多 _maxParallel）
    for (var batchStart = 0;
        batchStart < pending.length;
        batchStart += _maxParallel) {
      final batch = pending
          .skip(batchStart)
          .take(_maxParallel)
          .toList();

      await Future.wait(batch.map((index) async {
        final start = index * chunkSize;
        final end = min(start + chunkSize - 1, totalBytes - 1);
        final part = _partFile(dest, index);

        // 带重试的单片下载
        for (var retry = 0; retry <= _chunkRetries; retry++) {
          try {
            await _downloadChunk(url, part, start, end, totalBytes,
                onProgress: (p) {
              chunkProgress[index] = p;
              notifyProgress();
            });
            // 成功 → 计算 SHA-256 并存盘
            final partSha = await _sha256File(part);
            (chunks[index] as Map<String, dynamic>)['sha256'] = partSha;
            await _saveDState(dstateFile, dstate);
            completedChunks++;
            notifyProgress();
            debugPrint('[Downloader] 分片 $index / $chunkCount 完成 ($start-$end)');
            return; // 跳出重试循环
          } catch (e) {
            if (retry < _chunkRetries) {
              debugPrint('[Downloader] 分片 $index 失败，第 ${retry + 1} 次重试: $e');
              await Future.delayed(
                  Duration(seconds: 1 + retry * 2)); // 递增退避
              // 重试前清理残留的 part 文件
              if (await part.exists()) await part.delete();
            } else {
              // 所有重试用完
              debugPrint('[Downloader] 分片 $index 重试 $_chunkRetries 次后仍失败');
              rethrow;
            }
          }
        }
      }));
    }
  }

  // ── 单片下载 ──

  /// 用 Range 请求下载 [start]-[end] 字节，写入 [part] 文件。
  Future<void> _downloadChunk(
    String url,
    File part,
    int start,
    int end,
    int totalBytes,
    {ProgressCallback? onProgress}) async {
    final request = http.Request('GET', Uri.parse(url));
    request.headers['Range'] = 'bytes=$start-$end';

    final response = await _client.send(request);
    final status = response.statusCode;

    if (status != 206 && status != 200) {
      throw HttpException('分片下载失败 HTTP $status: $url [Range: $start-$end]');
    }

    final expectedChunkSize = end - start + 1;
    var received = 0;
    final sink = part.openWrite();

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && expectedChunkSize > 0) {
          onProgress(received / expectedChunkSize);
        }
      }
    } finally {
      await sink.close();
    }

    // 大小验证
    final actual = await part.length();
    if (actual != expectedChunkSize) {
      await part.delete();
      throw StateError(
          '分片大小不匹配: expected $expectedChunkSize, got $actual ($start-$end)');
    }
  }

  // ── 合并 + 最终校验 + 清理 ──

  /// 合并所有 .part.N 成最终文件，做全量 SHA-256 校验，清理临时文件。
  Future<void> _mergeAndVerify(
    File dest,
    File dstateFile,
    int chunkCount, {
    String? expectedSha256,
  }) async {
    debugPrint('[Downloader] 合并 $chunkCount 个分片...');
    final sink = dest.openWrite();
    final hashAccum = sha256; // 每次 .convert() 返回新的，所以这里逐个更新

    // 先计算合并后的全量 SHA-256（边合并边算）
    final bytesBuilder = BytesBuilder(copy: false);
    try {
      for (var i = 0; i < chunkCount; i++) {
        final part = _partFile(dest, i);
        final data = await part.readAsBytes();
        sink.add(data);
        bytesBuilder.add(data);
        await part.delete(); // 合并完立即删
      }
    } finally {
      await sink.close();
    }

    final finalHash = sha256.convert(bytesBuilder.takeBytes()).toString();

    // 校验
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (finalHash != expectedSha256.toLowerCase()) {
        // 校验失败：删最终文件 + 清 dstate（下次重新下载）
        await dest.delete();
        await dstateFile.delete();
        throw StateError(
            '全量 SHA-256 校验失败: expected $expectedSha256, got $finalHash '
            'for ${dest.uri.pathSegments.last}');
      }
      debugPrint(
          '[Downloader] SHA-256 校验通过: ${dest.uri.pathSegments.last}');
    }

    // 清理
    await dstateFile.delete();
    debugPrint('[Downloader] 下载完成: ${dest.uri.pathSegments.last}');
  }

  // ── 回退：单流下载（不支持 Range 时） ──

  Future<void> _downloadStreaming(
    String url,
    File dest, {
    ProgressCallback? onProgress,
    String? expectedSha256,
  }) async {
    debugPrint('[Downloader] 回退到单流下载（不支持 Range）');
    final request = http.Request('GET', Uri.parse(url));
    final response = await _client.send(request);

    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}: $url');
    }

    final totalBytes = response.contentLength ?? -1;
    var receivedBytes = 0;
    final sink = dest.openWrite();
    final bytesBuilder = BytesBuilder(copy: false);

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        bytesBuilder.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }
    } finally {
      await sink.close();
    }

    if (totalBytes > 0) {
      final actual = await dest.length();
      if (actual != totalBytes) {
        await dest.delete();
        throw StateError(
            '文件大小不匹配: expected $totalBytes, got $actual for $url');
      }
    }

    final actualHash = sha256.convert(bytesBuilder.takeBytes()).toString();
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (actualHash != expectedSha256.toLowerCase()) {
        await dest.delete();
        throw StateError(
            'SHA-256 校验失败: expected $expectedSha256, got $actualHash for $url');
      }
      debugPrint(
          '[Downloader] SHA-256 校验通过: ${dest.uri.pathSegments.last}');
    }
  }

  // ── .dstate 进度文件 ──

  /// .part.N 文件路径
  File _partFile(File dest, int index) =>
      File('${dest.path}.part.$index');

  /// 读取 .dstate JSON，文件不存在或损坏返回 null
  Future<Map<String, dynamic>?> _loadDState(File f) async {
    if (!await f.exists()) return null;
    try {
      final data = jsonDecode(await f.readAsString());
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    return null;
  }

  /// 原子写入 .dstate（先写临时文件再 rename）
  Future<void> _saveDState(File f, Map<String, dynamic> data) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(f.path);
  }

  /// 删除所有 .part.N 文件
  Future<void> _deleteParts(File dest, int chunkCount) async {
    for (var i = 0; i < chunkCount; i++) {
      final p = _partFile(dest, i);
      if (await p.exists()) await p.delete();
    }
  }

  /// 清分片临时文件 + .dstate（用于分片失败回退到单流前）
  Future<void> _cleanChunkState(File dest, File dstateFile, int chunkCount) async {
    await _deleteParts(dest, chunkCount);
    if (await dstateFile.exists()) await dstateFile.delete();
  }

  // ── 工具 ──

  /// 计算文件的 SHA-256 hex
  Future<String> _sha256File(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// 两个 SHA-256 是否相同（忽略大小写、null 兼容）
  bool _sameSha(String? a, String? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.toLowerCase() == b.toLowerCase();
  }

  /// 检查响应头是否声明了 Range 支持
  bool _supportsRangeHeader(http.BaseResponse resp) {
    return resp.headers['accept-ranges'] == 'bytes';
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
      if (entity is File &&
          entity.path.split(Platform.pathSeparator).last != _manifestName) {
        final bytes = await entity.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        final name = entity.path.split(Platform.pathSeparator).last;
        entries[name] = hash;
      }
    }
    if (entries.isNotEmpty) {
      await _writeManifest(dir, entries);
      debugPrint(
          '[Downloader] manifest 已写入: ${dir.path}, ${entries.length} 个文件');
    }
  }

  /// 解压 .tar.bz2 / .tar.gz / .zip 归档到目标目录
  ///
  /// 解压成功后删除归档文件。
  Future<void> _decompressArchive(File archive, Directory destDir) async {
    debugPrint('[Downloader] 解压: ${archive.path} → ${destDir.path}');
    final bytes = await archive.readAsBytes();
    final name = archive.path.split(Platform.pathSeparator).last;

    if (name.endsWith('.tar.bz2')) {
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      final tar = TarDecoder().decodeBytes(tarBytes);
      for (final entry in tar) {
        if (!entry.isFile) continue;
        final dest = File('${destDir.path}/${entry.name}');
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(entry.content as List<int>);
      }
    } else if (name.endsWith('.tar.gz')) {
      final tarBytes = GZipDecoder().decodeBytes(bytes);
      final tar = TarDecoder().decodeBytes(tarBytes);
      for (final entry in tar) {
        if (!entry.isFile) continue;
        final dest = File('${destDir.path}/${entry.name}');
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(entry.content as List<int>);
      }
    } else if (name.endsWith('.zip')) {
      final zip = ZipDecoder().decodeBytes(bytes);
      for (final entry in zip) {
        if (entry.isFile) {
          final dest = File('${destDir.path}/${entry.name}');
          await dest.parent.create(recursive: true);
          await dest.writeAsBytes(entry.content as List<int>);
        }
      }
    }

    // 解压后删除归档
    await archive.delete();
    debugPrint('[Downloader] 解压完成，已删归档: ${archive.path}');
  }

  /// 删除目录下的子文件 + .part / .dstate（保留目录本身）
  Future<void> _cleanDir(Directory d) async {
    if (!(await d.exists())) return;
    await for (final entity in d.list(recursive: false)) {
      if (entity is File) {
        // 删除普通文件 + .part.N + .dstate
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.endsWith('.dstate') ||
            name.contains('.part.') ||
            name != _manifestName) {
          await entity.delete();
        }
      }
    }
  }
}

/// 全局单例下载器
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  return ModelDownloader();
});