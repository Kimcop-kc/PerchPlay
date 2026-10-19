import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:typed_data' show Float32List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'speech_model_factory.dart';

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

    // 架构检测 + 建 recognizer 统一下沉到共享工厂，避免与 worker isolate
    // 各维护一份逻辑导致漂移（见 speech_model_factory.dart）
    final rec = buildOfflineRecognizer(modelDir);
    if (rec == null) {
      debugPrint('[SpeechService] 模型加载失败: $modelDir');
      _recognizer = null;
      _loadedDir = null;
      return;
    }

    _recognizer = rec;
    _loadedDir = modelDir;
    debugPrint('[SpeechService] 模型加载成功: $modelDir');
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
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
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

  /// 转写 WAV，但若音频近乎静音则直接返回空字符串，跳过 ASR 推理。
  ///
  /// 用于实时字幕：视频里大量无台词的空白段（纯音乐、过场、喘息）占很高
  /// 比例，静音检测在纯 Dart 侧 O(n) 算 RMS，远比跑一次 SenseVoice 便宜，
  /// 能显著降低边播边转写的 CPU 占用与发热。
  ///
  /// 返回 `null` 表示「模型未加载/读文件失败」（调用方判定为异常）；
  /// 返回空字符串表示「检测为静音，已跳过」；
  /// 返回非空字符串表示正常转写结果。
  Future<String?> transcribeFileSkipSilence(
    String wavPath, {
    double silenceThreshold = 0.01,
  }) async {
    final r = _recognizer;
    if (r == null) return null;
    if (!File(wavPath).existsSync()) return null;

    try {
      final wave = sherpa.readWave(wavPath);
      final samples = wave.samples;

      // RMS 静音检测：均方根 < 阈值 判为静音
      if (samples.isNotEmpty) {
        var sumSq = 0.0;
        // 抽样计算（每 8 个点取 1），大段音频也很快
        final stride = (samples.length ~/ 8000).clamp(1, 1 << 31);
        for (var i = 0; i < samples.length; i += stride) {
          final v = samples[i];
          sumSq += v * v;
        }
        final count = (samples.length / stride).ceil();
        final rms = count > 0 ? sqrt(sumSq / count) : 0.0;
        if (rms < silenceThreshold) {
          return ''; // 静音，跳过
        }
      }

      final stream = r.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: wave.sampleRate);
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
