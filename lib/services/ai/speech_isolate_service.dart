import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint;

import 'speech_worker.dart';

/// 后台语音识别服务（长驻 worker isolate）。
///
/// 把 sherpa-onnx 的同步 `decode()` 挪到独立 isolate，**彻底消除播放卡顿**：
/// - 主 isolate 只发「WAV 路径」字符串、收「文本」字符串，推理期间零阻塞；
/// - worker 里模型只加载一次，复用同一个 `OfflineRecognizer`。
///
/// ## 用法
/// ```dart
/// final s = SpeechIsolateService();
/// final ok = await s.loadModel(modelDir);        // 后台加载模型（一次）
/// final text = await s.transcribeFile(wavPath);  // 后台推理
/// s.dispose();
/// ```
///
/// 这是 `SpeechService` 的「非阻塞」替代版，供实时字幕使用；
/// 离线单文件转写（transcribe_page）仍用原 `SpeechService` 即可。
class SpeechIsolateService {
  Isolate? _isolate;
  SendPort? _commandPort;
  bool _disposed = false;

  /// worker isolate 退出时触发（崩溃或正常退出都算）。
  /// 监听它能在「字幕某天突然不出字」时自愈，而不是静默失效。
  void Function()? onWorkerDied;

  /// 待回复的请求表：id → Completer（当前串行调用，仍保留 id 以防将来并发）
  int _reqSeq = 0;
  final Map<int, _Outgoing> _pending = {};

  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// 上次加载的模型目录（worker 崩溃重启后用它自动 reload）
  String? _modelDir;

  /// 专门的 exit 监听端口：不能复用握手用的 ReceivePort（它在握手后就
  /// close 了），否则 onExit 事件永远收不到。
  ReceivePort? _exitPort;

  /// 启动 worker isolate 并完成握手拿到 commandPort。
  Future<void> _ensureIsolate() async {
    if (!_disposed && _isolate != null && _commandPort != null) return;

    final rp = ReceivePort();
    _isolate = await Isolate.spawn(speechWorkerEntry, rp.sendPort);
    // 握手：worker 会把它的 SendPort 作为第一条消息发回来
    _commandPort = await rp.first as SendPort;
    rp.close();

    // 监听 worker 死亡：崩溃/被杀时清理引用，并通知上层。
    // 新 Dart API：addOnExitListener 只收一个 SendPort，退出事件由该 port 的
    // listen 收到（消息为 null）触发。
    final exitPort = ReceivePort();
    _exitPort = exitPort;
    _isolate!.addOnExitListener(exitPort.sendPort);
    exitPort.listen((_) {
      debugPrint('[SpeechIsolate] worker isolate 退出');
      _isolate = null;
      _commandPort = null;
      _loaded = false;
      // 在途请求全部失败
      for (final o in _pending.values) {
        o.completer.complete(null);
        o.replyPort.close();
      }
      _pending.clear();
      exitPort.close();
      _exitPort = null;
      onWorkerDied?.call();
    });
  }

  /// 给 worker 发命令并等回复（带超时兜底）。
  ///
  /// 若 worker 已死（前一次 crash），则自动重启并（若有已加载目录）重新加载。
  Future<dynamic> _send(
    List<dynamic> command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureIsolate();
    var port = _commandPort;
    if (port == null) return null;

    final id = ++_reqSeq;
    final replyPort = ReceivePort();
    final completer = Completer<dynamic>();

    _pending[id] = _Outgoing(replyPort: replyPort, completer: completer);

    replyPort.listen((reply) {
      if (_disposed) return;
      completer.complete(reply);
      _pending.remove(id);
      replyPort.close();
    });

    // 协议：[cmd, replySendPort, ...args]
    final cmd = command[0];
    final args = command.sublist(1);
    port.send([cmd, replyPort.sendPort, ...args]);

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        replyPort.close();
        return null;
      },
    );
  }

  /// 后台加载模型。返回是否成功。
  ///
  /// [numThreads] 是 onnxruntime 算子内并行度：全片离线生成传 4，实时字幕传 1~2。
  Future<bool> loadModel(String modelDir, {int numThreads = 1}) async {
    await _ensureIsolate();
    _modelDir = modelDir;
    final ok = await _send(['load', modelDir, numThreads]);
    _loaded = ok == true;
    if (_loaded) {
      debugPrint('[SpeechIsolate] 模型已加载: $modelDir (threads=$numThreads)');
    } else {
      debugPrint('[SpeechIsolate] 模型加载失败: $modelDir');
    }
    return _loaded;
  }

  /// 释放模型但**保留 worker isolate**（下次转写会自动重新加载）。
  ///
  /// 用于实时字幕关闭后回收 ~234MB 内存，而不是一直驻留。
  Future<void> releaseModel() async {
    if (!_loaded) return;
    try {
      await _send(['unload'], timeout: const Duration(seconds: 10));
    } catch (_) {}
    _loaded = false;
    _modelDir = null;
  }

  /// 后台转写 WAV，返回文本。
  ///
  /// 返回 '' 表示静音跳过；返回 null 表示模型未加载 / 文件读取失败。
  Future<String?> transcribeFile(
    String wavPath, {
    double silenceThreshold = 0.01,
  }) async {
    if (!_loaded) return null;
    final r = await _send([
      'transcribe',
      wavPath,
      silenceThreshold,
    ], timeout: const Duration(seconds: 60));
    return r as String?;
  }

  /// 释放 worker isolate 与模型。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    try {
      // dispose 不需要等回复：给个 dummy replyPort 以符合协议 [cmd, replyPort]
      final dummy = ReceivePort();
      _commandPort?.send(['dispose', dummy.sendPort]);
      dummy.close();
    } catch (_) {}
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _isolate = null;
    _commandPort = null;
    _loaded = false;
    _modelDir = null;
    try {
      _exitPort?.close();
    } catch (_) {}
    _exitPort = null;

    // 所有在途请求强制完成（返回 null），避免调用方永久 await
    for (final o in _pending.values) {
      o.completer.complete(null);
      o.replyPort.close();
    }
    _pending.clear();
  }
}

class _Outgoing {
  final ReceivePort replyPort;
  final Completer<dynamic> completer;
  _Outgoing({required this.replyPort, required this.completer});
}
