import 'dart:io';
import 'dart:typed_data' show Float32List;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 端侧语音识别服务（非流式）。
///
/// 封装 sherpa-onnx 的 SenseVoice 模型：给定 WAV 音频 → 返回转写文本。
/// 模型由用户自行下载到本机（APK 不打包权重），[modelDir] 指向包含
/// `model.int8.onnx` 和 `tokens.txt` 的目录。
///
/// 提供 [transcribeFile]（从文件）、[transcribe]（从内存波形），
/// 不区分语种（SenseVoice 自动检测 zh/en/ja/ko/yue）。
class SpeechService {
  sherpa.OfflineRecognizer? _recognizer;
  String? _loadedDir;

  /// 释放当前加载的模型，允许后续调用 [loadModel] 切换。
  void dispose() {
    _recognizer?.free();
    _recognizer = null;
    _loadedDir = null;
  }

  /// 是否已加载模型。
  bool get isLoaded => _recognizer != null;

  /// 加载 SenseVoice 模型。
  ///
  /// [modelDir] 目录下需要存在 `.onnx` 文件与 `tokens.txt`（自动扫描）。
  /// 重复加载同一个目录不会重建（已是该目录则跳过）。
  /// 切换到不同目录时自动释放旧模型再加载新模型。
  void loadModel(String modelDir) {
    if (_loadedDir == modelDir && _recognizer != null) return;

    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[SpeechService] 模型目录不存在: $modelDir');
      return;
    }

    // 扫描目录找第一个 .onnx 文件
    final onnxFile = d
        .listSync()
        .whereType<File>()
        .firstWhere(
          (f) => f.path.toLowerCase().endsWith('.onnx'),
          orElse: () => File(''),
        );
    if (onnxFile.path.isEmpty) {
      debugPrint('[SpeechService] 目录中无 .onnx 文件: $modelDir');
      return;
    }

    // tokens.txt 或 vocab.txt
    final tokenFile = d
        .listSync()
        .whereType<File>()
        .firstWhere(
          (f) {
            final name = f.path.split(Platform.pathSeparator).last;
            return name == 'tokens.txt' || name == 'vocab.txt';
          },
          orElse: () => File(''),
        );
    if (tokenFile.path.isEmpty) {
      debugPrint('[SpeechService] 目录中无 tokens.txt: $modelDir');
      return;
    }

    final modelPath = onnxFile.path;
    final tokensPath = tokenFile.path;

    try {
      final senseVoice = sherpa.OfflineSenseVoiceModelConfig(
        model: modelPath,
        language: '', // auto-detect
        useInverseTextNormalization: false,
      );
      final modelConfig = sherpa.OfflineModelConfig(
        senseVoice: senseVoice,
        tokens: tokensPath,
        debug: false,
        numThreads: 1,
      );
      final config = sherpa.OfflineRecognizerConfig(model: modelConfig);
      _recognizer = sherpa.OfflineRecognizer(config);
      _loadedDir = modelDir;
      debugPrint('[SpeechService] 模型加载成功: $modelDir');
    } catch (e) {
      debugPrint('[SpeechService] 模型加载失败: $e');
      _recognizer = null;
      _loadedDir = null;
    }
  }

  /// 转写一个 WAV 文件，返回识别文本。
  ///
  /// 模型未加载时返回 null（调用方应提示"请先下载语音识别模型"）。
  Future<String?> transcribeFile(String wavPath) async {
    final r = _recognizer;
    if (r == null) return null;
    if (!File(wavPath).existsSync()) return null;

    try {
      // 用 sherpa 内置的 readWave（返回 samples + sampleRate）
      // 注意：sherpa_onnx 的 readWave 在初始化绑定时已通过 initBindingsAsync()
      // 完成 native 库加载；这里不需要再调用一次。
      final wave = sherpa.readWave(wavPath);
      final stream = r.createStream();
      stream.acceptWaveform(
          samples: wave.samples, sampleRate: wave.sampleRate);
      r.decode(stream);
      final result = r.getResult(stream);
      final text = result.text;
      stream.free();
      return text;
    } catch (e) {
      debugPrint('[SpeechService] 转写失败: $e');
      return null;
    }
  }

  /// 转写内存中的波形数据。
  ///
  /// [samples] 为 float 线性 PCM，[sampleRate] 通常是 16000。
  Future<String?> transcribe({
    required Float32List samples,
    required int sampleRate,
  }) async {
    final r = _recognizer;
    if (r == null) return null;

    try {
      final stream = r.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      r.decode(stream);
      final result = r.getResult(stream);
      final text = result.text;
      stream.free();
      return text;
    } catch (e) {
      debugPrint('[SpeechService] 转写失败: $e');
      return null;
    }
  }
}