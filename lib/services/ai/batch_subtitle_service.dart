import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;
import 'package:path_provider/path_provider.dart';

import '../../models/subtitle_model.dart';
import '../native_bridge_service.dart';
import 'speech_isolate_service.dart';
import 'translate_service.dart';

/// 全片离线字幕生成引擎。
///
/// 与「实时字幕」的区别：实时是边播边转写，逐段追着进度出；全片是**一次性把
/// 整部视频跑完**，产出完整 `.srt` 文件，缓存后下次直接加载，还能导出。
///
/// ## 与实时的互斥
/// 两者共用 [SpeechIsolateService]（同一个 worker isolate 同一时刻只能跑一种
/// 任务）。引擎只要保证「同时最多一个在跑」即可：实时开启时拒绝全片生成，
/// 全片生成中拒绝实时开启。[LiveSubtitleNotifier] 会在 start/stop 时调用
/// [acquireLive]/[releaseLive]。
class BatchSubtitleService {
  BatchSubtitleService._() {
    // 从持久化设置加载翻译后端语言配置
    _translator.loadFromSettings();
  }
  static final BatchSubtitleService instance = BatchSubtitleService._();

  final SpeechIsolateService _speech = SpeechIsolateService();
  final TranslateService _translator = TranslateService();

  /// 互斥锁：当前占用方。null = 空闲，'live' = 实时字幕，'batch' = 全片生成。
  String? _lockOwner;

  /// 生成中的取消标志。
  bool _cancelled = false;

  /// 全片生成的进度（0.0~1.0），供 UI 观察。
  final ValueNotifier<double> progress = ValueNotifier<double>(-1);

  /// 最近一次全片生成的字幕条数（-1 表示还没生成过），供 UI 完成后提示。
  int lastGeneratedCount = -1;

  /// 是否正在全片生成。
  bool get isRunning => _lockOwner == 'batch';

  /// 实时字幕想开始前调用：被全片生成占用则返回 false。
  bool acquireLive() {
    if (_lockOwner == 'batch') return false;
    _lockOwner = 'live';
    return true;
  }

  /// 实时字幕释放占用。
  void releaseLive() {
    if (_lockOwner == 'live') _lockOwner = null;
  }

  /// 全片生成想开始前调用：被实时字幕占用则返回 false。
  bool acquireBatch() {
    if (_lockOwner == 'live') return false;
    _lockOwner = 'batch';
    return true;
  }

  /// 全片生成释放占用。
  void _releaseBatch() {
    if (_lockOwner == 'batch') _lockOwner = null;
  }

  // ═══════════════ 全片生成 ═══════════════

  /// 为 [videoPath] 全片生成字幕，返回缓存 `.srt` 路径。
  ///
  /// - [durationMs]：视频总时长（由播放页传入，避免重复探测）
  /// - [asrModelDir]：ASR 模型目录
  /// - [segmentMs]：每段时长（全片离线默认 30s，大窗口上下文更完整、吞吐更高）
  /// - [onProgress]：进度回调（0.0~1.0）
  /// - [translate]：是否翻译成外文（生成双语 SRT）
  /// - [translateLang]：目标语言（ISO 639-1）
  ///
  /// 返回 null 表示失败或是被占用（错误信息通过 [onProgress] 之外的 out
  /// 参数 [onError] 回传）。
  Future<String?> generateFull(
    String videoPath, {
    required int durationMs,
    required String asrModelDir,
    int segmentMs = 30000,
    void Function(double)? onProgress,
    void Function(String)? onError,
    bool translate = false,
    String translateLang = 'en',
  }) async {
    if (!acquireBatch()) {
      onError?.call('实时字幕正在运行，请先关闭再生成全片字幕');
      return null;
    }

    _cancelled = false;
    progress.value = 0;
    try {
      // 1. 加载模型（全片离线：4 线程，用户等结果，越快越好）
      if (!_speech.isLoaded) {
        final ok = await _speech.loadModel(asrModelDir, numThreads: 4);
        if (!ok) {
          onError?.call('ASR 模型加载失败');
          return null;
        }
      }
      _notify(0.02);

      // 2. 配置翻译（尊重用户在设置里选的 backend，仅覆盖目标语言）
      if (translate) {
        _translator.targetLang = translateLang;
        // 不再强制 backend=google：构造函数已 loadFromSettings() 读取用户
        // 选择的 google/llm/local。若 llm 未配 Key，translate() 内部会回退 google。
      }

      // 3. 逐段转写
      final entries = <SubtitleEntry>[];
      int cursor = 0;
      int index = 0;

      while (cursor < durationMs && !_cancelled) {
        final end = (cursor + segmentMs).clamp(0, durationMs);
        final wavPath = await NativeBridgeService.instance
            .extractAudioSegment(
              videoPath: videoPath,
              startMs: cursor,
              // 严格按段边界抽取（不额外多抽 500ms）。
              //
              // 之前是 `(end - cursor) + 500`，多抽的 0.5s 会被识别成文字、
              // 但字幕时间轴只到 `end`，下一段又从 `end` 开始 → 同 0.5s
              // 音频被识别两次，SRT 里出现重复字幕。
              durationMs: end - cursor,
            )
            .timeout(const Duration(seconds: 20), onTimeout: () => null);

        if (wavPath == null) {
          // 抽音失败：跳过这段，不中断整片
          cursor = end;
          continue;
        }

        final text = await _speech.transcribeFile(wavPath);
        // 清理临时 wav
        try {
          final f = File(wavPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}

        if (text != null && text.trim().isNotEmpty) {
          var line = text.trim();
          if (translate) {
            final translated = await _translator.translate(line);
            if (translated != null && translated.isNotEmpty) {
              line = '$line\n$translated';
            }
          }
          entries.add(
            SubtitleEntry(
              index: index++,
              start: Duration(milliseconds: cursor),
              end: Duration(milliseconds: end),
              text: line,
            ),
          );
        }

        cursor = end;
        _notify(0.05 + 0.9 * (cursor / durationMs));
      }

      if (_cancelled) {
        onError?.call('已取消');
        return null;
      }

      // 4. 写成 SRT 到缓存目录
      final srtPath = await _writeSrt(videoPath, entries);
      lastGeneratedCount = entries.length;
      _notify(1.0);
      return srtPath;
    } catch (e) {
      debugPrint('[BatchSubtitle] 生成异常: $e');
      onError?.call('生成失败: $e');
      return null;
    } finally {
      progress.value = -1;
      _releaseBatch();
    }
  }

  /// 取消当前全片生成。
  void cancel() {
    _cancelled = true;
  }

  void _notify(double v) {
    progress.value = v;
  }

  /// 写 SRT 到缓存目录，返回缓存路径。
  Future<String> _writeSrt(
    String videoPath,
    List<SubtitleEntry> entries,
  ) async {
    final docs = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${docs.path}/ai_subtitles');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

    // 缓存文件名 = 视频基础名 + 路径短哈希。
    //
    // 只用基础名会让「不同目录下的同名视频」互相覆盖缓存
    // （例如两部都叫 Movie.mp4 的片子，第二部生成会覆盖第一部）。
    // 这里加路径的短哈希，既保持可读又保证唯一。
    final videoName = videoPath.split(Platform.pathSeparator).last;
    final base = videoName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final pathHash = videoPath.hashCode.toRadixString(16).replaceAll('-', '');
    final srtFile = File('${cacheDir.path}/$base.$pathHash.ai.srt');

    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln(e.index + 1);
      buf.writeln('${_fmt(e.start)} --> ${_fmt(e.end)}');
      buf.writeln(e.text);
      buf.writeln();
    }
    await srtFile.writeAsString(buf.toString());
    return srtFile.path;
  }

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    final h = two(d.inHours);
    final m = two(d.inMinutes % 60);
    final s = two(d.inSeconds % 60);
    final ms = three(d.inMilliseconds % 1000);
    return '$h:$m:$s,$ms';
  }

  /// 缓存 SRT 的文件名（与 [_writeSrt] 保持一致的命名规则）。
  ///
  /// 必须和写入时用同一套规则，否则「生成成功但找不到缓存」。
  static String _cacheFileName(String videoPath) {
    final videoName = videoPath.split(Platform.pathSeparator).last;
    final base = videoName.replaceAll(RegExp(r'\.[^.]+$'), '');
    final pathHash = videoPath.hashCode.toRadixString(16).replaceAll('-', '');
    return '$base.$pathHash.ai.srt';
  }

  /// 取缓存 SRT 路径（不存在返回 null）。
  Future<String?> cachedSrtPath(String videoPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/ai_subtitles/${_cacheFileName(videoPath)}');
    if (await f.exists()) return f.path;

    // 兼容旧命名（升级前生成的 `<base>.ai.srt`）：找到就顺便迁移过来，
    // 避免老用户升级后「之前生成的字幕全没了」。
    final legacy = File(
      '${docs.path}/ai_subtitles/'
      '${videoPath.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.[^.]+$'), '')}.ai.srt',
    );
    try {
      if (await legacy.exists()) {
        await legacy.rename(f.path);
        return f.path;
      }
    } catch (_) {}
    return null;
  }

  /// 删除缓存。
  Future<void> deleteCache(String videoPath) async {
    final path = await cachedSrtPath(videoPath);
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 导出 SRT（返回缓存路径，由调用方用 file_picker 另存到用户目录）。
  Future<String?> exportSrt(String videoPath) => cachedSrtPath(videoPath);
}
