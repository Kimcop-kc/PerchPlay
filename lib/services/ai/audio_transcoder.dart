// Stub: 音频转码需要 ffmpeg_kit_flutter_audio（SDK ≥3.7.0 + AGP 兼容）。
// Flutter 3.22 / AGP 8.1 不兼容 ffmpeg_kit_flutter_audio 的 compileSdk。
// 升级 Flutter 后添加依赖并取消下面注释即可启用。
//
// ```dart
// import 'dart:io';
// import 'package:ffmpeg_kit_flutter_audio/ffmpeg_kit.dart';
// import 'package:ffmpeg_kit_flutter_audio/return_code.dart';
// import 'package:flutter/foundation.dart' show debugPrint;
// import 'package:path_provider/path_provider.dart';
//
// class AudioTranscoder {
//   static Future<String?> transcodeToWav(String inputPath) async {
//     if (!File(inputPath).existsSync()) return null;
//     final tmpDir = await getTemporaryDirectory();
//     final output = File('${tmpDir.path}${Platform.pathSeparator}transcode_'
//         '${DateTime.now().millisecondsSinceEpoch}.wav');
//     final command = '-i "$inputPath" -ar 16000 -ac 1 -sample_fmt s16 "$output"';
//     final session = await FFmpegKit.execute(command);
//     final code = await session.getReturnCode();
//     if (!ReturnCode.isSuccess(code)) {
//       try { if (await output.exists()) await output.delete(); } catch (_) {}
//       return null;
//     }
//     if (!await output.exists() || await output.length() == 0) return null;
//     return output.path;
//   }
// }
// ```

import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// 占位转码服务——暂不支持转码（需要升级 Flutter SDK 后启用）。
class AudioTranscoder {
  /// 当前直接返回 null（转码功能未启用）。
  /// 仅支持 WAV 文件直接转写。
  static Future<String?> transcodeToWav(String inputPath) async {
    if (!File(inputPath).existsSync()) {
      debugPrint('[AudioTranscoder] 输入文件不存在: $inputPath');
      return null;
    }
    debugPrint('[AudioTranscoder] 转码功能未启用，仅支持 WAV 格式');
    return null;
  }
}