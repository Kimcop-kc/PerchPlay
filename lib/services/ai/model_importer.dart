import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'model_downloader.dart';

/// 用户自行导入模型的处理器。
///
/// 支持：.zip / .tar / .tar.gz / .tar.bz2 / .tar.xz，自动解压后扫描
/// .onnx + .txt 文件，复制到 `ai_models/{modelId}/`。
class ModelImporter {
  ModelImporter();

  /// 从本地压缩包或文件夹导入模型。
  ///
  /// 流程：1. 系统文件选择器 → 2. 解压（若需要）→ 3. 扫描 .onnx
  /// → 4. 复制到目标目录 → 5. 返回导入的文件列表。
  ///
  /// [modelId] 用户指定的模型 id（用作目录名）
  /// 返回导入后的文件数量，失败抛异常。
  Future<int> import({
    required String modelId,
  }) async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'zip', 'tar', 'gz', 'bz2', 'xz',
        'onnx', 'txt', 'bin', 'safetensors',
      ],
    );
    if (result == null) return 0;

    final picked = result;
    if (picked.path == null) {
      throw Exception('文件路径不可用，可能是内容 URI（Android SAF）');
    }

    final sourceFile = File(picked.path!);
    final ext = p.extension(sourceFile.path).toLowerCase();

    // 获取目标目录
    final modelsRoot = await ModelDownloader.modelsDir();
    final destDir = Directory(p.join(modelsRoot.path, modelId));
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await destDir.create(recursive: true);

    int copied = 0;
    if (_isArchive(ext)) {
      copied = await _extractAndCopy(sourceFile, ext, destDir);
    } else {
      // 单文件复制（如单独的 .onnx / .txt），扫描同目录下的其他模型文件
      copied = await _copyDirContents(
        Directory(p.dirname(sourceFile.path)),
        destDir,
        recursive: false,
        pattern: _isModelFile,
      );
    }

    if (copied == 0) {
      // 什么都没识别到 → 清理空目录
      await destDir.delete(recursive: true);
      throw Exception(
        '未找到模型文件（.onnx）。请确认压缩包/目录中包含 ONNX 模型。',
      );
    }

    // ── 关键：确保模型文件落在「AI 功能能扫描到的位置」──
    //
    // AI 侧（LiveSubtitleProvider._resolveAsrModelDir / speech_worker）只扫描
    // `ai_models/{id}/` 的**顶层**（非递归）找 .onnx + tokens.txt。
    // 有些压缩包会把文件放在一层子目录里（如 `model/xxx.onnx`），
    // 解压后若不提升到顶层，就会出现「导入成功但 AI 用不了」。
    await _flattenIntoRoot(destDir);

    // 可用性体检：缺 tokens 直接报错，别让用户以为导入成功了
    await _assertUsable(destDir);

    // 写入本地校验清单，后续每次刷新都会复验 SHA-256
    await ModelDownloader.recomputeManifest(destDir);

    debugPrint('[ModelImporter] 成功导入 $copied 个文件到 $modelId');
    return copied;
  }

  /// 把嵌套子目录里的模型文件提升到 [root] 顶层，并清掉空子目录。
  ///
  /// 递归深度限制 3 层，避免异常压缩包导致深层遍历。
  Future<void> _flattenIntoRoot(Directory root, {int depth = 0}) async {
    if (depth > 3) return;
    if (!await root.exists()) return;

    final subDirs = <Directory>[];
    var rootHasOnnx = false;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory) subDirs.add(entry);
      if (entry is File && entry.path.toLowerCase().endsWith('.onnx')) {
        rootHasOnnx = true;
      }
    }
    if (subDirs.isEmpty) return;

    // 顶层已有 .onnx 说明位置正确，不再搬（子目录可能是分组资源）
    if (!rootHasOnnx) {
      for (final dir in subDirs) {
        await for (final entry
            in dir.list(recursive: true, followLinks: false)) {
          if (entry is! File) continue;
          if (!_isModelFile(p.basename(entry.path))) continue;
          final target = File(p.join(root.path, p.basename(entry.path)));
          if (await target.exists()) continue; // 已存在不覆盖
          try {
            await entry.copy(target.path);
            debugPrint(
                '[ModelImporter] 提升到顶层: ${entry.path} → ${target.path}');
          } catch (e) {
            debugPrint('[ModelImporter] 提升失败: $e');
          }
        }
      }
    }

    // 清掉空子目录（非空的保留，避免误删）
    for (final dir in subDirs) {
      try {
        if (await dir.list().isEmpty) await dir.delete();
      } catch (_) {}
    }
  }

  /// 导入后的可用性体检：必须有 .onnx + tokens/vocab，否则抛异常。
  ///
  /// 为什么要在导入时就校验：AI 侧加载模型要求「onnx + tokens.txt」同时
  /// 存在，缺一个就加载失败。提前报错比用户去开实时字幕发现没反应好。
  Future<void> _assertUsable(Directory destDir) async {
    var hasOnnx = false;
    var hasTokens = false;
    await for (final e in destDir.list(recursive: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path).toLowerCase();
      if (name.endsWith('.onnx')) hasOnnx = true;
      if (name == 'tokens.txt' || name == 'vocab.txt') hasTokens = true;
    }
    if (!hasOnnx) {
      throw Exception('导入的模型里没有 .onnx 文件，AI 无法调用');
    }
    if (!hasTokens) {
      throw Exception(
        '缺少 tokens.txt（词表文件）。sherpa-onnx 模型必须同时有 .onnx 和 '
        'tokens.txt 才能被 AI 加载，请把 tokens.txt 一起放进压缩包。',
      );
    }
  }

  // ── 归档检测 ──

  bool _isArchive(String ext) {
    return const {
      '.zip', '.tar', '.gz', '.bz2', '.xz',
    }.contains(ext);
  }

  // ── 解压 + 复制模型文件 ──

  Future<int> _extractAndCopy(
    File archiveFile,
    String ext,
    Directory destDir,
  ) async {
    final bytes = await archiveFile.readAsBytes();

    // archive 4.x:
    //   .zip / .tar        → decodeBytes → Archive 直接
    //   .gz / .bz2 / .xz   → decodeBytes → List<int>（已解压的原始字节）
    //   .tar.gz / .tar.bz2 / .tar.xz → 两级：外层解压 → Tar 解压
    archive.Archive archiveObj;
    switch (ext) {
      case '.zip':
        archiveObj = archive.ZipDecoder().decodeBytes(bytes);
        break;
      case '.tar':
        archiveObj = archive.TarDecoder().decodeBytes(bytes);
        break;
      case '.gz':
        final decomp = archive.GZipDecoder().decodeBytes(bytes);
        archiveObj = archive.TarDecoder().decodeBytes(decomp);
        break;
      case '.bz2':
        final decomp = archive.BZip2Decoder().decodeBytes(bytes);
        archiveObj = archive.TarDecoder().decodeBytes(decomp);
        break;
      case '.xz':
        final decomp = archive.XZDecoder().decodeBytes(bytes);
        archiveObj = archive.TarDecoder().decodeBytes(decomp);
        break;
      default:
        throw Exception('不支持的压缩格式: $ext');
    }

    int count = 0;
    for (final file in archiveObj) {
      if (file.isFile && _isModelFile(file.name)) {
        final target = File(p.join(destDir.path, p.basename(file.name)));
        await target.writeAsBytes(file.content as List<int>);
        count++;
        debugPrint('[ModelImporter] 提取: ${file.name} → $destDir');
      }
    }
    return count;
  }

  // ── 模型文件识别 ──

  bool _isModelFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.onnx') ||
        lower.endsWith('.txt') && _isTokenFile(name);
  }

  /// tokens.txt / vocab.txt 等 tokenizer 配置文件
  bool _isTokenFile(String name) {
    final base = p.basename(name).toLowerCase();
    // tokens.txt 是 sherpa-onnx 用的；vocab.txt 是 BGE/BERT 用的
    return base == 'tokens.txt' ||
        base == 'vocab.txt' ||
        base == 'merges.txt' ||
        base == 'ppocrv5_dict.txt' ||
        base.endsWith('_dict.txt') ||
        base.endsWith('_tokens.txt');
  }

  // ── 目录复制（用于非压缩直接选文件夹的情况） ──

  Future<int> _copyDirContents(
    Directory dir,
    Directory destDir, {
    bool recursive = true,
    bool Function(String name)? pattern,
  }) async {
    if (!await dir.exists()) return 0;

    int count = 0;
    await for (final entry in dir.list(recursive: recursive)) {
      if (entry is File) {
        final name = p.basename(entry.path);
        if (pattern != null && !pattern(name)) continue;
        if (_isModelFile(name)) {
          await entry.copy(p.join(destDir.path, name));
          count++;
        }
      }
    }
    return count;
  }
}