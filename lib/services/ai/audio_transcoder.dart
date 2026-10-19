import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../native_bridge_service.dart';

/// 音频转码服务：把任意音频/视频文件转成 16kHz 单声道 WAV。
///
/// ## 实现方式（无需 ffmpeg_kit）
/// 复用 [NativeBridgeService.extractAudioSegment] —— 它在 Android 走
/// MediaExtractor + MediaCodec、iOS 走 AVAssetReader，对**纯音频文件**
/// （mp3/m4a/aac/ogg/flac）和**视频文件**一视同仁地抽音轨并重采样成
/// 16kHz 单声道 PCM。这样「语音转写」页面的 mp3/m4a 支持不再依赖
/// 需要升级 AGP 的 ffmpeg_kit。
///
/// 原 stub 里注释的 ffmpeg_kit 方案保留为「后续上 B（升级 AGP）后再切」
/// 的备选，见接入说明文档。
class AudioTranscoder {
  /// 转码 [inputPath]（音频或视频）为 16kHz 单声道 WAV，返回 WAV 路径。
  ///
  /// 返回 null 表示失败（文件不存在 / 无音轨 / 平台不支持）。
  static Future<String?> transcodeToWav(String inputPath) async {
    if (!File(inputPath).existsSync()) {
      debugPrint('[AudioTranscoder] 输入文件不存在: $inputPath');
      return null;
    }

    // 抽整段音频：时长传一个足够大的值（2 小时），原生侧会抽到文件末尾。
    // MediaExtractor 读到 sampleTime < 0 即 EOF，自动结束，不会真抽 2 小时。
    final wavPath = await NativeBridgeService.instance.extractAudioSegment(
      videoPath: inputPath,
      startMs: 0,
      durationMs: 2 * 60 * 60 * 1000, // 2 小时上限
    );

    if (wavPath == null) {
      debugPrint('[AudioTranscoder] 抽取音频失败: $inputPath');
      return null;
    }
    return wavPath;
  }
}
