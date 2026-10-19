import 'dart:io';
import 'dart:isolate';
import 'dart:math' show sqrt;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'speech_model_factory.dart';

/// 后台语音识别 worker isolate 的入口。
///
/// ## 通信协议（与 [SpeechIsolateService] 约定）
///
/// 握手：
///   - 主侧 `Isolate.spawn(speechWorkerEntry, mainReceivePort.sendPort)`
///   - worker 收到 `mainReceivePort.sendPort` 后，回发自己的 `workerSendPort`
///     （用 `mainSendPort.send(rp.sendPort)`），主侧 `await rp.first` 拿到。
///
/// 此后每条命令的格式统一为：`[cmd, replySendPort, ...args]`
///   - `['ping',  replyPort]`                       → 回复 `'pong'`（存活探针）
///   - `['load', replyPort, modelDir]`              → 回复 `true/false`
///   - `['transcribe', replyPort, wavPath, thr]`    → 回复 `String?`（''=静音，null=失败）
///   - `['dispose', replyPort]`                     → 回复 `'disposed'` 并退出
///
/// ## 为什么用长驻 isolate 而不是 compute()
///
/// `OfflineRecognizer` 是 dart:ffi 指针包装，**不能跨 isolate 传递**。每段
/// 都用 `compute()` 重新加载几百 MB 模型会慢到不可用。所以 spawn 一次长驻
/// worker，模型只在 worker 里加载一次。
///
/// ## sherpa 官方约束
///
/// FFI 绑定状态是 **isolate 本地**的：主 isolate 已 `initBindingsAsync()`，
/// worker 里**仍必须再 `initBindings()` 一次**，否则访问 native 会崩。
void speechWorkerEntry(SendPort mainSendPort) {
  final rp = ReceivePort();
  // 握手：把 worker 侧 SendPort 回发给主 isolate
  mainSendPort.send(rp.sendPort);

  sherpa.OfflineRecognizer? recognizer;

  rp.listen((message) async {
    if (message is! List || message.length < 2) return;
    final cmd = message[0] as String;
    final replyTo = message[1] as SendPort?;

    switch (cmd) {
      case 'ping':
        replyTo?.send('pong');
        break;

      case 'load':
        final dir = message[2] as String;
        final threads = (message[3] as num?)?.toInt() ?? 1;
        // 回传格式：成功为 true；失败为 String 错误原因（便于主线程打印诊断）
        Object reply;
        try {
          sherpa.initBindings(); // 每个 isolate 都要初始化一次
          final rec = buildOfflineRecognizer(dir, numThreads: threads);
          if (rec != null) {
            recognizer = rec;
            reply = true;
          } else {
            reply = 'buildOfflineRecognizer 返回 null'
                '（目录缺 .onnx 或 tokens.txt，或架构未识别）';
          }
        } catch (e, st) {
          reply = '加载异常: $e';
          debugPrint('[SpeechWorker] load 失败: $e\n$st');
        }
        replyTo?.send(reply);
        break;

      case 'unload':
        try {
          recognizer?.free();
        } catch (_) {}
        recognizer = null;
        replyTo?.send('unloaded');
        break;

      case 'transcribe':
        final wavPath = message[2] as String;
        final thr = (message[3] as num?)?.toDouble() ?? 0.01;
        final r = recognizer;
        String? result;
        if (r == null) {
          result = null;
        } else {
          result = _transcribePath(r, wavPath, silenceThreshold: thr);
        }
        replyTo?.send(result);
        break;

      case 'dispose':
        try {
          recognizer?.free();
        } catch (_) {}
        recognizer = null;
        replyTo?.send('disposed');
        rp.close();
        break;

      default:
        replyTo?.send(null);
    }
  });
}

/// 在 worker isolate 里转写 WAV，先做 RMS 静音跳过。
String? _transcribePath(
  sherpa.OfflineRecognizer recognizer,
  String wavPath, {
  required double silenceThreshold,
}) {
  if (!File(wavPath).existsSync()) return null;
  try {
    final wave = sherpa.readWave(wavPath);
    final samples = wave.samples;

    // RMS 静音检测（抽样），静音直接返回 ''（跳过），不发推理
    if (samples.isNotEmpty) {
      var sumSq = 0.0;
      final stride = (samples.length ~/ 8000).clamp(1, 1 << 31);
      for (var i = 0; i < samples.length; i += stride) {
        final v = samples[i];
        sumSq += v * v;
      }
      final count = (samples.length / stride).ceil();
      final rms = count > 0 ? sqrt(sumSq / count) : 0.0;
      if (rms < silenceThreshold) return '';
    }

    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    final raw = result.text;
    stream.free();
    return _cleanAsrText(raw);
  } catch (_) {
    return null;
  }
}

/// 清洗 ASR 原始输出。
///
/// SenseVoice 会输出 `<|zh|><|NEUTRAL|><|Speech|><|woitn|>` 这类标签前缀，
/// Whisper 偶尔也会带标记。不清理的话字幕里会出现一堆尖括号标签，
/// 表现为「AI 识别出来了但显示的内容是乱的」。
///
/// 处理：
///  1. 去掉 `<|...|>` 形式的标签 token；
///  2. 合并连续重复的标点（SenseVoice 常见 `。。`）；
///  3. 去掉首尾空白与开头多余的标点。
String? _cleanAsrText(String raw) {
  var s = raw.replaceAll(RegExp(r'<\|[^|]*\|>'), '');
  // 压缩重复标点：。。 → 。，、、 → 、
  s = s.replaceAll(RegExp(r'([。，、！？：；,.!?:;])\1+'), r'$1');
  // 去掉开头连续的标点/空白（识别片段起始常有孤立标点）
  s = s.replaceAll(RegExp(r'^[\s。，、！？：；,.!?:;\-—]+'), '');
  s = s.trim();
  return s;
}
