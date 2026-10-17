import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 端侧 TTS（文字转语音）薄封装。
///
/// 支持 VITS 架构（中文/英文/粤语），给定文字 → 返回 16kHz WAV 样本。
///
/// 典型用法：
/// ```dart
/// final tts = TtsService();
/// tts.loadModel('/path/to/vits-zh');
/// final wav = tts.synthesize('你好世界', speed: 1.0);
/// // wav: {samples: Float32List, sampleRate: int}
/// ```
class TtsService {
  sherpa.OfflineTts? _tts;
  String? _loadedDir;

  void dispose() {
    _tts?.free();
    _tts = null;
    _loadedDir = null;
  }

  bool get isLoaded => _tts != null;

  /// 返回模型支持的说话人数量（部分模型有多个音色）。
  int get numSpeakers => _tts?.numSpeakers ?? 0;

  /// 返回模型输出采样率（通常 22050）。
  int get sampleRate => _tts?.sampleRate ?? 0;

  /// 加载 VITS 模型。
  ///
  /// [modelDir] 应包含 `<model>.onnx` 和 `tokens.txt`。
  void loadModel(String modelDir) {
    if (_loadedDir == modelDir && _tts != null) return;
    dispose();

    final d = Directory(modelDir);
    if (!d.existsSync()) {
      debugPrint('[TtsService] 模型目录不存在: $modelDir');
      return;
    }

    final files = d.listSync().whereType<File>().toList();
    final modelFile = files.firstWhere(
      (f) => f.path.toLowerCase().endsWith('.onnx'),
      orElse: () => File(''),
    );
    final tokenFile = files.firstWhere(
      (f) {
        final name = f.path.split(Platform.pathSeparator).last;
        return name == 'tokens.txt';
      },
      orElse: () => File(''),
    );
    if (modelFile.path.isEmpty || tokenFile.path.isEmpty) {
      debugPrint('[TtsService] 缺少模型文件: ${d.path}');
      return;
    }

    final modelConfig = sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: modelFile.path,
        tokens: tokenFile.path,
      ),
      numThreads: 1,
      provider: 'cpu',
      debug: false,
    );

    _tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(model: modelConfig));
    _loadedDir = modelDir;
    debugPrint(
        '[TtsService] TTS 模型已加载: $modelDir, ${_tts!.numSpeakers} 说话人');
  }

  /// 合成语音。
  ///
  /// [text] 待朗读文字。
  /// [sid] 说话人 ID（0-based），仅多说话人模型有效。
  /// [speed] 语速倍率，1.0 为默认。
  ///
  /// 返回 {samples, sampleRate}，失败返回 null。
  ({Float32List samples, int sampleRate})? synthesize(
    String text, {
    int sid = 0,
    double speed = 1.0,
  }) {
    final tts = _tts;
    if (tts == null || text.isEmpty) return null;

    try {
      final audio = tts.generate(text: text, sid: sid, speed: speed);
      if (audio.samples.isEmpty) return null;
      return (samples: audio.samples, sampleRate: audio.sampleRate);
    } catch (e) {
      debugPrint('[TtsService] 合成失败: $e');
      return null;
    }
  }
}