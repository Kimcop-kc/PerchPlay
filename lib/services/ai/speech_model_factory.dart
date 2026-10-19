import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 从模型目录构建 [sherpa.OfflineRecognizer]（纯工厂，无状态）。
///
/// 为什么单独抽成函数：
/// 这个「架构检测 + 建 recognizer」逻辑被 [SpeechService] 和
/// [speech_worker] 共用。之前两份各自复制一份，改一处漏另一处会行为漂移
/// （比如某天新增一个模型架构，只在离线转写生效、实时字幕却还原地踏步）。
/// 收拢到这里后，两边都只调 `buildOfflineRecognizer()`，不会再漂。
///
/// 架构检测规则（按文件名）：
///  - encoder + decoder + joiner → Transducer
///  - encoder + decoder（无 joiner）→ Whisper
///  - 单 onnx，名含 zipformer → ZipformerCtc
///  - 单 onnx（sensevoice / paraformer / 其他）→ SenseVoice（实时字幕首选）
///  - 多 onnx 但模式未知 → 回退 SenseVoice 用第一个
///
/// 返回 null 表示模型目录无效（缺 .onnx / 缺 tokens）或构建失败。
///
/// [numThreads] 是 onnxruntime 的算子内并行度：
///  - 全片离线生成传 4（用户等结果，越快越好）
///  - 实时字幕传 1~2（避免和正在解码视频的播放器抢 CPU）
sherpa.OfflineRecognizer? buildOfflineRecognizer(
  String modelDir, {
  int numThreads = 1,
}) {
  final d = Directory(modelDir);
  if (!d.existsSync()) {
    debugPrint('[SpeechFactory] 模型目录不存在: $modelDir');
    return null;
  }

  final files = d.listSync().whereType<File>().toList();
  final onnx = <String, File>{};
  for (final f in files) {
    final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
    if (name.endsWith('.onnx')) onnx[name] = f;
  }
  if (onnx.isEmpty) {
    debugPrint('[SpeechFactory] 目录中无 .onnx 文件: $modelDir');
    return null;
  }

  final tokenFile = files.firstWhere((f) {
    final name = f.path.split(Platform.pathSeparator).last;
    return name == 'tokens.txt' || name == 'vocab.txt';
  }, orElse: () => File(''));
  if (tokenFile.path.isEmpty) {
    debugPrint('[SpeechFactory] 目录中无 tokens.txt: $modelDir');
    return null;
  }
  final tokensPath = tokenFile.path;

  String? _findPath(bool Function(String k) pred) {
    for (final e in onnx.entries) {
      if (pred(e.key)) return e.value.path;
    }
    return null;
  }

  final hasEncoder = onnx.keys.any(
    (k) => k.contains('encoder') && k.endsWith('.onnx'),
  );
  final hasDecoder = onnx.keys.any(
    (k) => k.contains('decoder') && k.endsWith('.onnx'),
  );
  final hasJoiner = onnx.keys.any(
    (k) => k.contains('joiner') && k.endsWith('.onnx'),
  );
  final isParaformer =
      onnx.keys.any((k) => k.contains('paraformer')) ||
      modelDir.toLowerCase().contains('paraformer');

  sherpa.OfflineModelConfig modelConfig;

  if (hasEncoder && hasDecoder && hasJoiner) {
    final cfg = sherpa.OfflineTransducerModelConfig(
      encoder: _findPath((k) => k.contains('encoder'))!,
      decoder: _findPath((k) => k.contains('decoder'))!,
      joiner: _findPath((k) => k.contains('joiner'))!,
    );
    modelConfig = sherpa.OfflineModelConfig(
      transducer: cfg,
      tokens: tokensPath,
      debug: false,
      numThreads: numThreads,
    );
  } else if (hasEncoder && hasDecoder && isParaformer) {
    final cfg = sherpa.OfflineTransducerModelConfig(
      encoder: _findPath((k) => k.contains('encoder'))!,
      decoder: _findPath((k) => k.contains('decoder'))!,
      joiner: '',
    );
    modelConfig = sherpa.OfflineModelConfig(
      transducer: cfg,
      tokens: tokensPath,
      debug: false,
      numThreads: numThreads,
    );
  } else if (hasEncoder && hasDecoder) {
    final cfg = sherpa.OfflineWhisperModelConfig(
      encoder: _findPath((k) => k.contains('encoder'))!,
      decoder: _findPath((k) => k.contains('decoder'))!,
      language: '',
      task: '',
    );
    modelConfig = sherpa.OfflineModelConfig(
      whisper: cfg,
      tokens: tokensPath,
      debug: false,
      numThreads: numThreads,
    );
  } else if (onnx.length == 1) {
    final key = onnx.keys.first;
    final path = onnx.values.first.path;
    if (key.contains('paraformer')) {
      final cfg = sherpa.OfflineParaformerModelConfig(model: path);
      modelConfig = sherpa.OfflineModelConfig(
        paraformer: cfg,
        tokens: tokensPath,
        debug: false,
        numThreads: numThreads,
      );
    } else if (key.contains('zipformer')) {
      final zcfg = sherpa.OfflineZipformerCtcModelConfig(model: path);
      modelConfig = sherpa.OfflineModelConfig(
        zipformerCtc: zcfg,
        tokens: tokensPath,
        debug: false,
        numThreads: numThreads,
      );
    } else if (key.contains('omnilingual') ||
        modelDir.toLowerCase().contains('omnilingual')) {
      final ocfg = sherpa.OfflineOmnilingualAsrCtcModelConfig(model: path);
      modelConfig = sherpa.OfflineModelConfig(
        omnilingual: ocfg,
        tokens: tokensPath,
        debug: false,
        numThreads: numThreads,
      );
    } else {
      // SenseVoice 及其他单文件 → 统一 SenseVoice（实时字幕首选）
      final cfg = sherpa.OfflineSenseVoiceModelConfig(
        model: path,
        language: '',
        useInverseTextNormalization: false,
      );
      modelConfig = sherpa.OfflineModelConfig(
        senseVoice: cfg,
        tokens: tokensPath,
        debug: false,
        numThreads: numThreads,
      );
    }
  } else {
    // 多文件但模式未知 → 回退 SenseVoice 用第一个
    final cfg = sherpa.OfflineSenseVoiceModelConfig(
      model: onnx.values.first.path,
      language: '',
      useInverseTextNormalization: false,
    );
    modelConfig = sherpa.OfflineModelConfig(
      senseVoice: cfg,
      tokens: tokensPath,
      debug: false,
      numThreads: numThreads,
    );
  }

  try {
    return sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: modelConfig),
    );
  } catch (e) {
    debugPrint('[SpeechFactory] 构建 recognizer 失败: $e');
    return null;
  }
}
