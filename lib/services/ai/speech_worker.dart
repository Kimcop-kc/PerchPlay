import 'dart:io';
import 'dart:isolate';
import 'dart:math' show sqrt;

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
        bool ok = false;
        try {
          sherpa.initBindings(); // 每个 isolate 都要初始化一次
          final rec = buildOfflineRecognizer(dir, numThreads: threads);
          if (rec != null) {
            recognizer = rec;
            ok = true;
          }
        } catch (_) {
          ok = false;
        }
        replyTo?.send(ok);
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
    final text = result.text;
    stream.free();
    return text;
  } catch (_) {
    return null;
  }
}
