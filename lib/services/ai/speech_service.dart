import 'dart:io';
import 'dart:typed_data' show Float32List;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 端侧语音识别服务（非流式）。
///
/// 封装 sherpa-onnx 的多种 ASR 架构：给定 WAV 音频 → 返回转写文本。
/// 模型由用户自行下载到本机（APK 不打包权重），[modelDir] 指向包含
/// `.onnx` 文件与 `tokens.txt` 的目录。
///
/// 自动检测模型架构（SenseVoice / Paraformer / Zipformer / Whisper / Transducer），
/// 不再硬编码单一模型类型。
///
/// 提供 [transcribeFile]（从文件）、[transcribe]（从内存波形）。
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

  /// 加载模型，自动检测架构。
  ///
  /// 扫描 [modelDir] 下所有 .onnx 文件，按文件名规则判断：
  /// * encoder + decoder + joiner → Transducer
  /// * encoder + decoder (no joiner) → Whisper
  /// * 单 onnx，名含"sensevoice"/"int8" → SenseVoice
  /// * 单 onnx，名含"paraformer" → Paraformer
  /// * 单 onnx，名含"zipformer" → ZipformerCtc
  /// * 其他 → 回退到 SenseVoice
  void loadModel(String modelDir) {
    if (_loadedDir == modelDir && _recognizer != null) return;

    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[SpeechService] 模型目录不存在: $modelDir');
      return;
    }

    // 扫描目录，按小写文件名去重映射
    final files = d.listSync().whereType<File>().toList();
    final onnx = <String, File>{};
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
      if (name.endsWith('.onnx')) onnx[name] = f;
    }

    if (onnx.isEmpty) {
      debugPrint('[SpeechService] 目录中无 .onnx 文件: $modelDir');
      return;
    }

    // tokens.txt 或 vocab.txt
    final tokenFile = files.firstWhere(
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
    final tokensPath = tokenFile.path;

    // ── 架构检测 ──
    sherpa.OfflineModelConfig modelConfig;

    final hasEncoder = onnx.containsKey('encoder.onnx') ||
        onnx.keys.any((k) => k.contains('encoder') && k.endsWith('.onnx'));
    final hasDecoder = onnx.containsKey('decoder.onnx') ||
        onnx.keys.any((k) => k.contains('decoder') && k.endsWith('.onnx'));
    final hasJoiner = onnx.containsKey('joiner.onnx') ||
        onnx.keys.any((k) => k.contains('joiner') && k.endsWith('.onnx'));

    // helper: find a key by substring match
    String? _findPath(bool Function(String k) pred) {
      for (final e in onnx.entries) {
        if (pred(e.key)) return e.value.path;
      }
      return null;
    }

    if (hasEncoder && hasDecoder && hasJoiner) {
      // Transducer
      final enc = _findPath((k) => k.contains('encoder'))!;
      final dec = _findPath((k) => k.contains('decoder'))!;
      final jnr = _findPath((k) => k.contains('joiner'))!;
      debugPrint('[SpeechService] 检测到 Transducer 架构');
      final cfg = sherpa.OfflineTransducerModelConfig(
        encoder: enc,
        decoder: dec,
        joiner: jnr,
      );
      modelConfig = sherpa.OfflineModelConfig(
        transducer: cfg,
        tokens: tokensPath,
        debug: false,
        numThreads: 1,
      );
    } else if (hasEncoder && hasDecoder) {
      // Whisper
      final enc = _findPath((k) => k.contains('encoder'))!;
      final dec = _findPath((k) => k.contains('decoder'))!;
      debugPrint('[SpeechService] 检测到 Whisper 架构');
      final cfg = sherpa.OfflineWhisperModelConfig(
        encoder: enc,
        decoder: dec,
        language: '',
        task: '',
      );
      modelConfig = sherpa.OfflineModelConfig(
        whisper: cfg,
        tokens: tokensPath,
        debug: false,
        numThreads: 1,
      );
    } else if (onnx.length == 1) {
      final key = onnx.keys.first;
      final path = onnx.values.first.path;
      if (key.contains('paraformer')) {
        debugPrint('[SpeechService] 检测到 Paraformer 架构');
        final cfg = sherpa.OfflineParaformerModelConfig(model: path);
        modelConfig = sherpa.OfflineModelConfig(
          paraformer: cfg,
          tokens: tokensPath,
          debug: false,
          numThreads: 1,
        );
      } else if (key.contains('zipformer')) {
        debugPrint('[SpeechService] 检测到 ZipformerCTC 架构');
        final cfg = sherpa.OfflineZipformerCtcModelConfig(model: path);
        modelConfig = sherpa.OfflineModelConfig(
          zipformerCtc: cfg,
          tokens: tokensPath,
          debug: false,
          numThreads: 1,
        );
      } else {
        // fallback → SenseVoice (also covers "int8")
        debugPrint('[SpeechService] 检测到 SenseVoice 架构 (fallback)');
        final cfg = sherpa.OfflineSenseVoiceModelConfig(
          model: path,
          language: '',
          useInverseTextNormalization: false,
        );
        modelConfig = sherpa.OfflineModelConfig(
          senseVoice: cfg,
          tokens: tokensPath,
          debug: false,
          numThreads: 1,
        );
      }
    } else {
      // 多个 .onnx 但不符合已知多文件模式 → 回退到 SenseVoice，用第一个 .onnx
      final path = onnx.values.first.path;
      debugPrint('[SpeechService] 无法判定架构，回退 SenseVoice: $modelDir');
      final cfg = sherpa.OfflineSenseVoiceModelConfig(
        model: path,
        language: '',
        useInverseTextNormalization: false,
      );
      modelConfig = sherpa.OfflineModelConfig(
        senseVoice: cfg,
        tokens: tokensPath,
        debug: false,
        numThreads: 1,
      );
    }

    try {
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