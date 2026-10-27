import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants/app_constants.dart';
import '../models/subtitle_model.dart';
import 'cloud/cloud_drive_service.dart';

/// 网盘「同目录外挂字幕」查找与下载。
///
/// 为什么需要单独一个服务：本地视频可以 `Directory(dirname).list()` 直接扫同目录，
/// 但网盘（夸克/百度/115/阿里）只有 HTTP 直链，没有本地目录概念。
/// 之前 [SubtitleService.findExternalSubtitles] 对远程路径直接跳过，
/// 导致网盘视频永远没有外挂字幕可用。
///
/// 现在的做法：
///  1. 用云盘的 `listDirectory` 列出视频所在目录；
///  2. 按「与视频同名的 .srt/.ass/.vtt…」筛选（和本地规则一致）；
///  3. 对命中的字幕文件 `getDownloadUrl` 取直链，下载到本地缓存；
///  4. 返回本地路径，交给现有字幕加载链路（mpv 只能读本地文件）。
class CloudSubtitleService {
  CloudSubtitleService._();
  static final instance = CloudSubtitleService._();

  /// 字幕缓存目录名（在系统临时目录下，可被系统回收）。
  static const _cacheDirName = 'cloud_subs';

  /// 单次最多下载几个字幕（防止目录里字幕很多时卡住）。
  static const int _maxDownload = 5;

  /// 单条字幕大小上限（字幕都是几十 KB，超过基本不是字幕）。
  static const int _maxBytes = 2 * 1024 * 1024;

  /// 查找并下载 [videoName] 在网盘 [dirId] 下的同名字幕。
  ///
  /// - [accountId] 云盘账号 id
  /// - [dirId] 视频所在目录 id（各云盘含义不同，见 listDirectory 注释）
  /// - [videoName] 视频文件名（用于匹配同名字幕）
  ///
  /// 返回下载到本地的字幕列表；找不到或失败返回空列表（不抛异常）。
  Future<List<SubtitleModel>> findAndDownload({
    required String accountId,
    required String dirId,
    required String videoName,
    String parentPath = '/',
  }) async {
    if (accountId.isEmpty || dirId.isEmpty) return const [];

    try {
      final files = await CloudDriveService.instance
          .listDirectory(accountId, dirId, parentPath: parentPath);
      if (files == null || files.isEmpty) return const [];

      final videoBase = _baseName(videoName);
      // 收集同名字幕候选（与本地 SubtitleService 的匹配规则保持一致：
      // 视频同名，或「视频名 + 语言后缀」如 movie.zh.srt / movie.eng.ass）
      final candidates = <dynamic>[];
      for (final f in files) {
        if (f.isDirectory) continue;
        final ext = _ext(f.name);
        if (!AppConstants.supportedSubtitleFormats.contains(ext)) continue;
        final base = _baseName(f.name);
        if (base == videoBase || base.startsWith(videoBase)) {
          candidates.add(f);
          if (candidates.length >= _maxDownload) break;
        }
      }
      if (candidates.isEmpty) {
        debugPrint('[CloudSub] $videoName 同目录无匹配字幕');
        return const [];
      }

      final dir = await _cacheDir();
      final out = <SubtitleModel>[];
      for (final f in candidates) {
        try {
          final local = await _download(accountId, f, dir);
          if (local == null) continue;
          out.add(SubtitleModel(
            path: local,
            language: _ext(f.name).toUpperCase(),
            title: f.name,
          ));
        } catch (e) {
          debugPrint('[CloudSub] 下载字幕失败 ${f.name}: $e');
        }
      }
      debugPrint('[CloudSub] $videoName 找到并下载 ${out.length} 个字幕');
      return out;
    } catch (e) {
      debugPrint('[CloudSub] 查找字幕失败: $e');
      return const [];
    }
  }

  /// 取直链并下载到缓存目录，返回本地路径。
  Future<String?> _download(String accountId, dynamic file, Directory dir) async {
    final url = await CloudDriveService.instance
        .getDownloadUrl(accountId, file.id as String);
    if (url == null || url.isEmpty) return null;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      // 网盘直链通常需要与取链一致的 UA
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        debugPrint('[CloudSub] 下载 HTTP ${resp.statusCode}: ${file.name}');
        return null;
      }
      final bytes = await resp.fold<List<int>>(
        <int>[],
        (prev, chunk) {
          if (prev.length + chunk.length > _maxBytes) return prev;
          return prev..addAll(chunk);
        },
      );
      if (bytes.isEmpty) return null;

      // 用「视频名_字幕名」做本地文件名，避免不同视频的同名字幕互相覆盖
      final safe = (file.name as String).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final path = p.join(dir.path, safe);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('[CloudSub] 下载异常 ${file.name}: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Directory> _cacheDir() async {
    Directory base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, _cacheDirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 清空字幕缓存（退出播放时调用，避免长期占空间）。
  Future<void> clearCache() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        try {
          if (e is File) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static String _baseName(String name) {
    final i = name.lastIndexOf('.');
    return (i > 0 ? name.substring(0, i) : name).toLowerCase();
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return '';
    return name.substring(i + 1).toLowerCase();
  }
}
