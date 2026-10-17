import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 端侧标点恢复薄封装。
///
/// ASR 输出的无标点文本 → 加回句号、逗号、问号等。
///
/// 典型用法：
/// ```dart
/// final punct = PunctService();
/// punct.loadModel('/path/to/punct-ct-transformer');
/// final text = punct.restore('你好我是机器人今天天气不错');
/// // → '你好，我是机器人，今天天气不错。'
/// ```
class PunctService {
  sherpa.OfflinePunctuation? _punct;
  String? _loadedDir;

  void dispose() {
    _punct?.free();
    _punct = null;
    _loadedDir = null;
  }

  bool get isLoaded => _punct != null;

  /// 加载标点模型。
  ///
  /// [modelDir] 应包含 `model.onnx`。
  void loadModel(String modelDir) {
    if (_loadedDir == modelDir && _punct != null) return;
    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[PunctService] 模型目录不存在: $modelDir');
      return;
    }

    final files = d.listSync().whereType<File>();
    final modelFile = files.firstWhere(
      (f) => f.path.toLowerCase().endsWith('.onnx'),
      orElse: () => File(''),
    );
    if (modelFile.path.isEmpty) {
      debugPrint('[PunctService] 目录中无 .onnx 文件: $modelDir');
      return;
    }

    final config = sherpa.OfflinePunctuationConfig(
      model: sherpa.OfflinePunctuationModelConfig(
        ctTransformer: modelFile.path,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      ),
    );

    _punct = sherpa.OfflinePunctuation(config: config);
    _loadedDir = modelDir;
    debugPrint('[PunctService] 标点模型已加载: $modelDir');
  }

  /// 给无标点文本加回标点。
  ///
  /// [text] 原始文本（可含换行）。
  /// 返回加标点后的文本，失败返回原文本。
  String restore(String text) {
    final p = _punct;
    if (p == null || text.isEmpty) return text;

    try {
      return p.addPunct(text);
    } catch (e) {
      debugPrint('[PunctService] 标点恢复失败: $e');
      return text;
    }
  }
}