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
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const [
        'zip', 'tar', 'gz', 'bz2', 'xz',
        'onnx', 'txt', 'bin', 'safetensors',
      ],
    );
    if (result == null || result.files.isEmpty) return 0;

    final picked = result.files.single;
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

    debugPrint('[ModelImporter] 成功导入 $copied 个文件到 $modelId');
    return copied;
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