import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/subtitle_model.dart';
import '../services/ai/batch_subtitle_service.dart';
import '../services/ai/model_downloader.dart';
import '../services/ai/speech_isolate_service.dart';
import '../services/ai/translate_service.dart';
import '../services/device_info_service.dart';
import '../services/library_prune_service.dart';
import '../services/native_bridge_service.dart';

/// 实时（准实时）AI 字幕引擎。
///
/// 工作方式（对齐 NovaPlayer 的「边播边转写」）：
/// 播放照常进行，这里后台**按固定时间窗**从视频文件里抽一段 16kHz 单声道
/// 音频，丢给本地 sherpa-onnx（SenseVoice）转成文字，再按时间戳累积成
/// 字幕条目。字幕会「一段一段追着播放进度出现」——开头几秒可能是空的，
/// 之后越来越完整。
///
/// ## 与播放器的对齐（本次优化核心）
///
/// 引擎不靠自己的游标「盲跑」，而是把播放器的三件事映射过来：
///  - `start(atMs)`：从当前播放位置开始转写，而不是永远从 0 开始；
///  - `pause()/resume()`：播放暂停时停止推进（不白烧 CPU），恢复时继续；
///  - `seekTo(ms)`：拖进度条/快进后，清空旧字幕、从新位置重新追。
///
/// 这样字幕时间戳始终与用户实际看的进度一致。
///
/// ## 为什么是「准实时」而不是逐字零延迟
/// - media_kit（libmpv）不暴露「抓取正播放音频」的 API，逐字实时要改 libmpv
///   原生层并重编译，工程量大且难维护；
/// - 独立用系统 API（Android MediaExtractor / iOS AVAssetReader）解码音频，
///   与播放内核零耦合，稳定且可缓存复用。
///
/// ## 并发策略
/// 抽音频（原生解码）与推理（sherpa-onnx CPU）各自异步，用 [Future] 串联成
/// 「上一段转写完才抽下一段」。[_generation] 是代际号：每次 start/seek/stop
/// 都 +1，旧任务醒来发现代际变了就作废，杜绝异步竞态。
class LiveSubtitleNotifier extends StateNotifier<LiveSubtitleState> {
  LiveSubtitleNotifier() : super(const LiveSubtitleState.initial()) {
    // 从持久化设置加载翻译后端语言配置（用户已在设置页配置好的）
    _translator.loadFromSettings();
    _bilingual = false;
    _targetLang = _translator.targetLang;
    // 把后端标签同步到 state，UI 好展示
    state = state.copyWith(
      targetLang: _targetLang,
      backendLabel: _translator.backendLabel,
    );

    // worker isolate 崩溃时：如果用户还在用实时字幕，自动重启恢复，
    // 而不是「开关开着却永远不出字」的静默失效。
    _speech.onWorkerDied = () {
      final dir = _loadedModelDir;
      if (dir != null && _running) {
        debugPrint('[LiveSubtitle] worker 崩溃，自动重启并 reload 模型');
        unawaited(_speech.loadModel(dir));
      }
    };
  }

  final SpeechIsolateService _speech = SpeechIsolateService();
  final TranslateService _translator = TranslateService();
  String? _loadedModelDir;

  /// 是否开启双语（中文 + 外文）。true 时每段 ASR 结果都翻译成外文拼在下面。
  bool _bilingual = false;
  bool get bilingual => _bilingual;

  /// 目标语言（ISO 639-1），默认英文。
  String _targetLang = 'en';
  String get targetLang => _targetLang;

  String? _videoPath;
  Timer? _tickTimer;

  /// 用户是否开启了实时字幕（= running）。与「是否正在处理一段」解耦。
  bool _running = false;

  /// 播放暂停导致的「暂停推进」。
  bool _paused = false;

  /// 当前是否正在处理一段（抽音 + 转写）。串行锁，防止重入。
  bool _busy = false;

  /// 已抽到视频的哪个时间点（字幕游标）。
  int _cursorMs = 0;

  /// 播放器当前实际位置（追赶判断用，由播放页低频同步）。
  int _playerPositionMs = -1;

  /// 代际号：start/seek/stop 时 +1，旧异步任务以此作废。
  int _generation = 0;

  @override
  void dispose() {
    _stopLoop();
    BatchSubtitleService.instance.releaseLive();
    _translator.dispose();
    // SpeechIsolateService.dispose 是异步的（要杀 isolate），这里 fire-and-forget
    unawaited(_speech.dispose());
    super.dispose();
  }

  // ═══════════════ 生命周期 ═══════════════

  /// 为一个新视频启动实时字幕，从 [atMs]（默认当前播放位置）开始追。
  ///
  /// 返回 false 表示无法启动（模型没找到 / 远程 NAS 路径 / 全片生成占用中）。
  Future<bool> start(String videoPath, {int atMs = 0}) async {
    await _stopLoop();

    // 与全片生成互斥：全片生成进行中时拒绝实时开启
    if (!BatchSubtitleService.instance.acquireLive()) {
      state = const LiveSubtitleState(
        running: false,
        status: LiveSubtitleStatus.unavailable,
        entries: [],
        message: '全片字幕生成中，请稍后再开实时字幕',
      );
      return false;
    }

    // 远程/NAS 路径（smb/ftp/webdav/http）无法用本地 MediaExtractor 抽音频，
    // 直接拒掉并给出原因，避免「打开开关却永远不出字幕」的静默失效。
    if (LibraryPruneService.isRemotePath(videoPath)) {
      BatchSubtitleService.instance.releaseLive();
      state = const LiveSubtitleState(
        running: false,
        status: LiveSubtitleStatus.unavailable,
        entries: [],
        message: '网络/NAS 视频暂不支持实时字幕（需先缓存到本地）',
      );
      return false;
    }

    final ok = await ensureModelLoaded();
    if (!ok) {
      BatchSubtitleService.instance.releaseLive();
      state = const LiveSubtitleState(
        running: false,
        status: LiveSubtitleStatus.unavailable,
        entries: [],
        message: '未找到 ASR 模型，请到设置 → AI 模型管理 下载 SenseVoice',
      );
      return false;
    }

    _videoPath = videoPath;
    _cursorMs = (atMs ~/ _segmentMs) * _segmentMs; // 对齐到整段边界
    _running = true;
    _paused = false;
    state = LiveSubtitleState(
      running: true,
      status: LiveSubtitleStatus.transcribing,
      entries: const [],
      bilingual: _bilingual,
      targetLang: _targetLang,
    );
    _scheduleNext();
    return true;
  }

  /// 播放暂停 → 停止推进，但保留已生成的字幕。
  void pause() {
    if (!_running) return;
    _paused = true;
    _tickTimer?.cancel();
    state = state.copyWith(status: LiveSubtitleStatus.paused);
  }

  /// 播放恢复 → 继续追。
  void resume() {
    if (!_running || !_paused) return;
    _paused = false;
    state = state.copyWith(status: LiveSubtitleStatus.transcribing);
    _scheduleNext();
  }

  /// 播放器 seek → 清空旧字幕（时间戳已失效），从 [ms] 重新追。
  Future<void> seekTo(int ms) async {
    if (!_running) return;
    _generation++;
    _tickTimer?.cancel();
    _busy = false;
    _cursorMs = (ms ~/ _segmentMs) * _segmentMs;
    _playerPositionMs = ms;
    state = state.copyWith(
      entries: const [],
      status: LiveSubtitleStatus.transcribing,
    );
    _scheduleNext();
  }

  /// 同步播放器当前实际位置（播放页低频调用，用于「追赶」判断）。
  ///
  /// 不做任何清屏/状态变更，只记录数值 —— 追赶逻辑在 [_processNextSegment]
  /// 推进游标时参考它。这样慢机上「转写追不上播放」时会自动跳段丢帧追平，
  /// 字幕不会越拖越远。
  void syncPosition(int ms) {
    if (!_running) return;
    _playerPositionMs = ms;
  }

  /// 停止实时字幕，保留已有字幕条目（用户可能只是想关掉生成）。
  Future<void> stop() async {
    await _stopLoop();
    BatchSubtitleService.instance.releaseLive();
    state = state.copyWith(running: false, status: LiveSubtitleStatus.stopped);
    // 关闭时释放模型（~234MB），否则全局 provider 常驻会一直占着内存
    await _speech.releaseModel();
  }

  /// 停止并清空字幕。
  Future<void> clear() async {
    await _stopLoop();
    BatchSubtitleService.instance.releaseLive();
    state = const LiveSubtitleState.initial();
  }

  /// 设置双语开关与目标语言（运行时生效）。
  void setBilingual(bool on, {String? lang, BilingualMode? mode}) {
    _bilingual = on;
    if (lang != null) {
      _targetLang = lang;
      _translator.targetLang = lang;
    }
    // 同步到 state，让 UI 能 watch 到双语状态（面板里的开关/语言下拉）
    state = state.copyWith(
      bilingual: on,
      targetLang: _targetLang,
      bilingualMode: mode ?? state.bilingualMode,
      backendLabel: _translator.backendLabel,
    );
  }

  /// 设置双语显示模式（both / zh / foreign）。
  void setBilingualMode(BilingualMode mode) {
    state = state.copyWith(bilingualMode: mode);
  }

  Future<void> _stopLoop() async {
    _generation++;
    _running = false;
    _paused = false;
    _tickTimer?.cancel();
    _tickTimer = null;
    _videoPath = null;
    _busy = false;
    _cursorMs = 0;
  }

  // ═══════════════ 模型加载 ═══════════════

  /// 公开的模型目录解析（供全片生成复用同一逻辑）。
  Future<String?> resolveAsrModelDir() => _resolveAsrModelDir();

  /// 实时字幕的 onnxruntime 线程数：按设备核心数自适应（启动时一次性决定）。
  ///
  /// 为什么「实时」和「全片」分开：
  ///  - 全片离线生成用 4 线程（用户等结果，越快越好，短时发热可接受）；
  ///  - 实时字幕边播边转写，线程过多会与正在解码视频的播放器抢 CPU，
  ///    反而导致播放卡顿，所以按核心数收敛到 1~2。
  ///
  /// 为什么是「启动时一次性决定」而不是「运行时动态调」：
  /// decode 耗时没有可靠的运行时反馈信号（音频长度和内容都不同），
  /// 动态调只会引入抖动；按设备核心数的静态策略最稳。
  static int _adaptiveThreads() {
    final cores = DeviceInfoService.instance.capabilities.cpuCores;
    if (cores >= 8) return 2; // 旗舰/高端：能边播边转还不卡
    return 1; // 中低端：让出 CPU 给播放器
  }

  /// 找到并加载一个可用的 ASR 模型（优先 SenseVoice）。
  ///
  /// 只需要加载一次；换片时模型常驻，避免反复 load 卡顿。
  /// 模型在 worker isolate 里加载，不阻塞主线程。
  Future<bool> ensureModelLoaded() async {
    if (_speech.isLoaded) return true;

    final modelDir = await _resolveAsrModelDir();
    if (modelDir == null) return false;

    if (_loadedModelDir == modelDir) return _speech.isLoaded;

    final ok = await _speech.loadModel(modelDir, numThreads: _adaptiveThreads());
    if (!ok) {
      debugPrint('[LiveSubtitle] 模型加载失败: $modelDir');
      // 模型损坏：清掉目录，让用户重新下载
      try {
        final d = Directory(modelDir);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
      return false;
    }

    _loadedModelDir = modelDir;
    return true;
  }

  /// 扫描已下载模型目录，挑一个能做 ASR 的（SenseVoice 优先，其次任意 onnx）。
  Future<String?> _resolveAsrModelDir() async {
    final base = await ModelDownloader.modelsDir();
    if (!await base.exists()) return null;

    final candidates = <String>[];
    await for (final entry in base.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final files = await entry.list().toList();
      final hasOnnx = files.any(
        (f) => f is File && f.path.toLowerCase().endsWith('.onnx'),
      );
      final hasTokens = files.any((f) {
        if (f is! File) return false;
        final name = f.path.split(Platform.pathSeparator).last;
        return name == 'tokens.txt' || name == 'vocab.txt';
      });
      if (hasOnnx && hasTokens) {
        candidates.add(entry.path);
      }
    }

    if (candidates.isEmpty) return null;

    // SenseVoice 优先（质量最好且有内置标点）
    for (final c in candidates) {
      final name = c.split(Platform.pathSeparator).last.toLowerCase();
      if (name.contains('sensevoice')) return c;
    }
    // 退而求其次，取第一个
    candidates.sort();
    return candidates.first;
  }

  // ═══════════════ 主循环 ═══════════════

  static const int _segmentMs = 5000; // 每次抽 5 秒
  static const int _overlapMs = 500; // 段间重叠 0.5 秒，减少边界切字

  void _scheduleNext() {
    if (!_running || _paused) return;
    _tickTimer?.cancel();
    // 给播放/解码留一点喘息：每 2 秒检查一次要不要抽下一段
    _tickTimer = Timer(const Duration(seconds: 2), _maybeProcessNext);
  }

  Future<void> _maybeProcessNext() async {
    if (!_running || _paused || _busy) {
      _scheduleNext();
      return;
    }
    await _processNextSegment();
    _scheduleNext();
  }

  Future<void> _processNextSegment() async {
    // 二次确认：可能在 Timer 触发到真正执行之间被 stop/seek 打断
    if (!_running || _paused || _busy) return;

    final videoPath = _videoPath;
    if (videoPath == null) return;

    _busy = true;
    final gen = _generation;
    final startMs = _cursorMs;
    final endMs = startMs + _segmentMs;
    String? wavPath;

    try {
      wavPath = await NativeBridgeService.instance.extractAudioSegment(
        videoPath: videoPath,
        startMs: startMs,
        durationMs: _segmentMs + _overlapMs,
      );

      // 代际变了（stop/seek）→ 结果作废
      if (gen != _generation || !_running) return;

      if (wavPath == null) {
        // 抽不到（文件读不到 / 已到片尾）→ 停止推进
        debugPrint('[LiveSubtitle] 抽取音频失败，停止: $videoPath @ $startMs');
        await stop();
        return;
      }

      final text = await _speech.transcribeFile(wavPath);

      if (gen != _generation || !_running) return;

      if (text != null && text.trim().isNotEmpty) {
        var line = text.trim();
        // 双语：翻译成外文拼在下面（失败/超时静默降级为单语，不拖慢字幕流）
        if (_bilingual) {
          final translated = await _translator
              .translate(line)
              .timeout(const Duration(seconds: 3), onTimeout: () => null);
          if (translated != null && translated.isNotEmpty) {
            line = '$line\n$translated';
          }
        }
        final entry = SubtitleEntry(
          index: state.entries.length,
          start: Duration(milliseconds: startMs),
          end: Duration(milliseconds: endMs),
          text: line,
        );
        state = state.copyWith(entries: [...state.entries, entry]);
      }
    } catch (e) {
      debugPrint('[LiveSubtitle] 转写异常: $e');
      // 单段失败不致命，跳过继续（游标仍推进）
    } finally {
      // 用完即删临时 wav（无论成功/失败/提前 return 都清理）
      if (wavPath != null) {
        try {
          final f = File(wavPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      // 只有当前代际的任务有权解锁；旧任务不能重置新循环的锁
      if (gen == _generation) _busy = false;
    }

    // 推进游标（正常路径 + 单段失败路径都推进，避免死循环）
    if (gen == _generation && _running) {
      _cursorMs = endMs;
      // 追赶逻辑：慢机上「转写速度 < 播放速度」会越拖越远。
      // 若游标已落后播放器超过 2 段（10s），直接跳到播放器当前段附近，
      // 牺牲中间几段字幕换「不再无限滞后」。宁可少字不可追不上。
      final playerPos = _playerPositionMs;
      if (playerPos > 0 && playerPos - _cursorMs > _segmentMs * 2) {
        debugPrint('[LiveSubtitle] 追赶：落后 ${playerPos - _cursorMs}ms，跳段追平');
        _cursorMs = (playerPos ~/ _segmentMs) * _segmentMs;
      }
    }
  }
}

/// 实时字幕状态。
class LiveSubtitleState {
  final bool running;
  final LiveSubtitleStatus status;
  final List<SubtitleEntry> entries;
  final String? message;

  /// 是否开启双语（中文 + 外文翻译）。
  final bool bilingual;

  /// 目标语言（ISO 639-1），如 en/ja/ko。
  final String targetLang;

  /// 双语显示模式：同时显示 / 只中文 / 只外文。
  final BilingualMode bilingualMode;

  /// 当前翻译后端的可读标签（如「Google 免费翻译」），用于 UI 提示。
  final String backendLabel;

  const LiveSubtitleState({
    required this.running,
    required this.status,
    required this.entries,
    this.message,
    this.bilingual = false,
    this.targetLang = 'en',
    this.bilingualMode = BilingualMode.both,
    this.backendLabel = 'Google 免费翻译',
  });

  const LiveSubtitleState.initial()
    : running = false,
      status = LiveSubtitleStatus.idle,
      entries = const [],
      message = null,
      bilingual = false,
      targetLang = 'en',
      bilingualMode = BilingualMode.both,
      backendLabel = 'Google 免费翻译';

  LiveSubtitleState copyWith({
    bool? running,
    LiveSubtitleStatus? status,
    List<SubtitleEntry>? entries,
    String? message,
    bool? bilingual,
    String? targetLang,
    BilingualMode? bilingualMode,
    String? backendLabel,
    bool clearMessage = false,
  }) {
    return LiveSubtitleState(
      running: running ?? this.running,
      status: status ?? this.status,
      entries: entries ?? this.entries,
      message: clearMessage ? null : (message ?? this.message),
      bilingual: bilingual ?? this.bilingual,
      targetLang: targetLang ?? this.targetLang,
      bilingualMode: bilingualMode ?? this.bilingualMode,
      backendLabel: backendLabel ?? this.backendLabel,
    );
  }
}

/// 双语字幕的显示模式。
enum BilingualMode {
  /// 同时显示中文 + 外文（两行）
  both,

  /// 只显示中文（识别原文）
  zh,

  /// 只显示外文（翻译结果）
  foreign,
}

enum LiveSubtitleStatus {
  /// 未启用
  idle,

  /// 正在生成（边播边转写）
  transcribing,

  /// 播放暂停，生成暂停（保留已生成字幕）
  paused,

  /// 用户手动停止（保留已生成字幕）
  stopped,

  /// 缺模型，无法使用
  unavailable,
}

/// 全局实时字幕引擎。
final liveSubtitleProvider =
    StateNotifierProvider<LiveSubtitleNotifier, LiveSubtitleState>(
      (ref) => LiveSubtitleNotifier(),
    );
