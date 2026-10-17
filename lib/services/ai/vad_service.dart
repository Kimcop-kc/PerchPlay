import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 语音活动检测薄封装。
///
/// 用 Silero VAD（2MB）先过滤无声片段，再把有声音的段交给 ASR，
/// 大幅减少无效推理。
///
/// 典型用法（离线 WAV 文件）：
/// ```dart
/// final vad = VadService();
/// vad.loadModel('/path/to/silero-vad');
/// final segments = await vad.detectFromFile('/path/to/audio.wav');
/// // segments 是 [{samples, start}] 列表，每个都是 Float32 波形
/// ```
class VadService {
  sherpa.VoiceActivityDetector? _vad;
  String? _loadedDir;

  void dispose() {
    _vad?.free();
    _vad = null;
    _loadedDir = null;
  }

  bool get isLoaded => _vad != null;

  /// 加载 Silero VAD 模型。
  ///
  /// [modelDir] 应包含 `silero_vad.onnx`（tar.bz2 解压后自动生成）。
  void loadModel(String modelDir) {
    if (_loadedDir == modelDir && _vad != null) return;
    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[VadService] 模型目录不存在: $modelDir');
      return;
    }

    final files = d.listSync().whereType<File>();
    final modelFile = files.firstWhere(
      (f) => f.path.toLowerCase().endsWith('.onnx'),
      orElse: () => File(''),
    );
    if (modelFile.path.isEmpty) {
      debugPrint('[VadService] 目录中无 .onnx 文件: $modelDir');
      return;
    }

    final config = sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: modelFile.path,
        threshold: 0.5,
        minSilenceDuration: 0.5,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 30.0,
      ),
      sampleRate: 16000,
      numThreads: 1,
      provider: 'cpu',
      debug: false,
    );

    _vad = sherpa.VoiceActivityDetector(
      config: config,
      bufferSizeInSeconds: 60.0,
    );
    _loadedDir = modelDir;
    debugPrint('[VadService] VAD 模型已加载: $modelDir');
  }

  /// 从 WAV 文件检测语音片段。
  ///
  /// 返回 [SpeechSegment] 列表，每个 segment 包含原始波形样本和起始时间。
  /// 如果没检测到任何语音，返回空列表。
  List<_SpeechSegment> detectFromFile(String wavPath) {
    final vad = _vad;
    if (vad == null) return [];

    final wave = sherpa.readWave(wavPath);
    if (wave.samples.isEmpty) {
      debugPrint('[VadService] 无法读取 WAV: $wavPath');
      return [];
    }
    final sampleRate = wave.sampleRate;

    final segments = <_SpeechSegment>[];
    int offset = 0;
    const chunkSize = 4000; // 每次喂 4000 个采样点

    while (offset < wave.samples.length) {
      final end =
          (offset + chunkSize).clamp(0, wave.samples.length);
      final chunk = Float32List.fromList(wave.samples.sublist(offset, end));
      vad.acceptWaveform(chunk);

      while (!vad.isEmpty()) {
        final seg = vad.front();
        if (seg.samples.isNotEmpty) {
          segments.add(_SpeechSegment(
            samples: seg.samples,
            startMs: (seg.start / sampleRate * 1000).round(),
            endMs:
                ((seg.start + seg.samples.length) / sampleRate * 1000).round(),
          ));
        }
        vad.pop();
      }

      offset = end;
    }

    // flush 剩余缓冲区
    vad.flush();
    while (!vad.isEmpty()) {
      final seg = vad.front();
      if (seg.samples.isNotEmpty) {
        segments.add(_SpeechSegment(
          samples: seg.samples,
          startMs: (seg.start / sampleRate * 1000).round(),
          endMs:
              ((seg.start + seg.samples.length) / sampleRate * 1000).round(),
        ));
      }
      vad.pop();
    }

    vad.reset();
    debugPrint('[VadService] 检测到 ${segments.length} 个语音片段');
    return segments;
  }

  /// 流式接受波形数据（用于实时录音场景，每收到一段就推入）。
  void acceptWaveform(Float32List samples) {
    _vad?.acceptWaveform(samples);
  }

  /// 是否有已检测到的语音片段。
  bool hasDetected() => _vad?.isDetected() ?? false;

  /// 取出下一个语音片段。
  _SpeechSegment? popDetected() {
    final vad = _vad;
    if (vad == null || vad.isEmpty()) return null;
    final seg = vad.front();
    if (seg.samples.isEmpty) {
      vad.pop();
      return null;
    }
    final result = _SpeechSegment(
      samples: seg.samples,
      startMs: seg.start,
    );
    vad.pop();
    return result;
  }
}

/// 单个语音片段的包装，避免暴露 sherpa 原生类型。
class _SpeechSegment {
  const _SpeechSegment({
    required this.samples,
    this.startMs = 0,
    this.endMs = 0,
  });

  /// 16kHz float 线性 PCM 波形
  final Float32List samples;

  /// 片段起始时间（毫秒）
  final int startMs;

  /// 片段结束时间（毫秒），流式模式下可能为 0
  final int endMs;

  /// 片段时长（毫秒）
  int get durationMs => endMs > startMs ? endMs - startMs : 0;

  /// 片段时长（秒）
  double get durationSec =>
      samples.length / 16000; // VAD 固定 16kHz
}