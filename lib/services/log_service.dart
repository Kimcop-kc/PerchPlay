import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用内日志收集器。
///
/// ## 为什么需要它
///
/// 排查问题时我一直让用户「抓 logcat」，但手机上这基本不可行 ——
/// 要么连电脑、要么装专门的工具。用户能做的只有「把屏幕上的错误描述打字发出来」，
/// 而这个描述往往丢失了最关键的上下文（哪个接口、什么状态码、什么异常）。
///
/// 这个服务把 App 内所有 `debugPrint` 输出接住，存进一个**环形缓冲区**，
/// 用户可以在「设置 → 诊断日志」里一键复制、分享。
///
/// ## 实现方式：劫持 debugPrint
///
/// 全项目有 100+ 处 `debugPrint(...)` 调用，逐个改造成 `LogService.log(...)`
/// 既容易漏、也会制造大量无意义 diff。这里利用 Flutter 的机制：
/// `debugPrint` 是一个**可赋值的顶层变量**，在启动最早期把它替换成自己的实现，
/// 就能零侵入地捕获所有日志 —— 包括第三方库里的。
///
/// ## 环形缓冲区
///
/// 只保留最近 [maxEntries] 条。播放器每秒可能产生数条日志，不设上限会
/// 吃光内存；而排查问题只需要「出问题前后那一段」，早期日志没有价值。
///
/// ## 落盘持久化（闪退日志）
///
/// 光有内存缓冲区解决不了**闪退** —— 进程被系统杀掉（libmpv 段错误、
/// OOM、ANR 强杀）时，内存里的日志一起消失，用户重开 App 看到的是
/// 一片空白，等于什么都没记录。
///
/// 所以这里再维护一份磁盘日志：攒一小批就追加写一次，进程被杀也不会丢
/// （数据已经进了内核页缓存，进程终止不影响其落盘）。
///
/// 文件滚动策略（目录 `<Documents>/perchplay_logs/`）：
///
/// ```
/// current.log   当前这次运行
/// last.log      上一次运行（闪退后就是它）
/// prev.log      上上次运行
/// ```
///
/// 每次启动时整体后移一位。所以「闪退 → 重开 App → 看诊断日志」一定能
/// 拿到崩溃前的那段。
///
/// 单文件上限 [maxLogFileBytes]，超了会在会话内就地滚动，避免一个
/// 长会话把存储吃到几十 MB（播放器每秒刷屏很凶）。
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  /// 最多保留多少条（约覆盖最近几分钟的操作）。
  static const int maxEntries = 800;

  /// 单个日志文件的体积上限。超过就滚动，防止长会话无限增长。
  ///
  /// 512 KB 约等于 5000~8000 行，足够覆盖一次闪退前的完整上下文。
  static const int maxLogFileBytes = 512 * 1024;

  /// 落盘目录名（应用私有 Documents 下）。
  static const String _logDirName = 'perchplay_logs';

  /// 攒多久写一次盘。太短会频繁触发 IO，太长则崩溃时丢的上下文多。
  ///
  /// 400ms 是个折中：正常播放时约每秒 1~3 次写入，开销可忽略；
  /// 崩溃最多丢最后 0.4 秒的日志。
  static const Duration _flushInterval = Duration(milliseconds: 400);

  /// 正常退出标记。启动时检查上一次运行的日志里有没有这行来判断是否闪退。
  static const String _cleanExitMarker = '[退出] 正常关闭';

  final List<_LogEntry> _entries = [];

  /// 未被消费的日志流（设置页的实时日志视图用）。
  final StreamController<String> _ctrl = StreamController<String>.broadcast();

  /// 实时日志流（每条是已格式化的文本行）。
  Stream<String> get stream => _ctrl.stream;

  /// 是否已安装拦截（防止重复安装导致日志翻倍）。
  bool _installed = false;

  /// 当前缓冲区快照（时间正序）。
  List<String> get lines => _entries.map((e) => e.format()).toList(growable: false);

  int get count => _entries.length;

  // ══════════════ 落盘状态 ══════════════

  Directory? _logDir;
  File? _currentFile;
  int _currentBytes = 0;
  bool _persistReady = false;

  /// 待写盘的行（攒批，避免每条 debugPrint 都触发一次 IO）。
  final List<String> _pending = [];
  Timer? _flushTimer;

  /// 落盘初始化前就产生的日志条数（缓冲上限，防止极端情况下爆内存）。
  int _preInitDropped = 0;

  /// 上一次运行是否**没有**留下正常退出标记。
  ///
  /// 注意语义：unclean ≠ 一定是闪退。Android 上进程被系统回收（后台驻留
  /// 被 LMK 干掉）同样不会走到正常退出，只是这种情况用户通常感知不到。
  /// UI 文案要按「可能是闪退，也可能是被系统回收」来说，不能断言。
  ///
  /// 所以这个标记**只进报告正文**，不拿来做 UI 报警 —— 报警一律看
  /// [hasCrashEvidence]（有原生崩溃堆栈才是真的崩了）。
  bool _lastSessionUnclean = false;
  bool get lastSessionUnclean => _lastSessionUnclean;

  /// 本次启动是否真的找到了**崩溃证据**（原生崩溃堆栈 / 系统记录的异常退出）。
  ///
  /// 与 [lastSessionUnclean] 的区别：后者只是「没留退出标记」，正常划掉后台
  /// 也会这样；这个是实打实拿到了堆栈，才能确认是崩溃。
  bool _hasCrashEvidence = false;
  bool get hasCrashEvidence => _hasCrashEvidence;

  /// 崩溃证据的摘要（给 UI 显示一行，不用把整段堆栈摊在设置页上）。
  String _crashSummary = '';
  String get crashSummary => _crashSummary;

  /// 崩溃证据的全文（原生堆栈 / 系统记录的异常退出）。
  ///
  /// 单独存一份而不是从 `_entries` 里翻：日志环形缓冲区只有 800 条，
  /// 崩溃记录在启动最早期写入，播放一段时间后很可能已被挤掉——
  /// 那时候用户才想起来去反馈，就什么都看不到了。
  String _crashDetail = '';
  String get crashDetail => _crashDetail;

  /// 由 main() 在取到原生崩溃记录后调用。
  void markCrashEvidence(String detail) {
    if (detail.trim().isEmpty) return;
    _hasCrashEvidence = true;
    _crashSummary = detail.trim().split('\n').first;
    _crashDetail = detail.trim();
  }

  /// 上一次运行的日志尾部（已落盘、已读进内存的那一份）。
  String? _lastSessionLog;
  String? get lastSessionLog => _lastSessionLog;
  bool get hasLastSessionLog => (_lastSessionLog?.isNotEmpty) ?? false;

  /// 落盘是否已就绪（未就绪时诊断面板应提示「本次日志未写盘」）。
  bool get persistReady => _persistReady;

  /// 当前日志文件路径（调试/展示用）。
  String? get currentLogPath => _currentFile?.path;

  /// 安装 debugPrint 拦截。
  ///
  /// **必须在 runApp 之前调用**，且越早越好 —— 否则启动早期的
  /// MediaKit / 设备信息初始化日志会漏掉（那恰恰是最容易出问题的地方）。
  ///
  /// 注意：这里**不**做 `runZonedGuarded`。zone 必须包住 `runApp` 才能
  /// 捕获其中未处理的异步异常；在 `install()` 里起一个只含空回调的 zone
  /// 是无效的（它的生命周期只有那一行）。异常的收集在 main() 里
  /// 用 `runZonedGuarded` 包住 runApp 完成。
  void install() {
    if (_installed) return;
    _installed = true;

    // 保存原始实现，仍然输出到控制台（开发时仍然能在 IDE 里看到）
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth);
      if (message != null && message.isNotEmpty) {
        _add(message);
      }
    };
  }

  // ══════════════ 落盘 ══════════════

  /// 初始化磁盘日志：滚动旧文件、读上次会话尾日志、开新文件。
  ///
  /// 必须在 `install()` 之后、`runApp` 之前调用（`getApplicationDocumentsDirectory`
  /// 是异步的，早调早好）。失败不影响 App 运行，只是本次日志不落盘。
  Future<void> initPersistence() async {
    if (_persistReady) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$_logDirName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logDir = dir;

      final current = File('${dir.path}/current.log');
      final last = File('${dir.path}/last.log');
      final prev = File('${dir.path}/prev.log');

      // 整体后移一位：prev ← last ← current
      _tryDelete(prev);
      if (last.existsSync()) _tryRename(last, prev);
      if (current.existsSync()) {
        // 读旧会话尾部：既用于「上次运行日志」展示，也用于判断是否闪退
        _lastSessionLog = _readTail(current);
        _lastSessionUnclean =
            !(_lastSessionLog ?? '').contains(_cleanExitMarker);
        _tryRename(current, last);
      }

      _currentFile = File('${dir.path}/current.log');
      _currentBytes = 0;
      _persistReady = true;

      // 新会话分隔符：诊断时一眼能看出是两次启动
      _appendNow('===== 新会话 ${DateTime.now().toIso8601String()} =====');

      // 把 initPersistence 之前攒下的日志补写进去
      if (_pending.isNotEmpty) {
        final batch = _pending.join('\n');
        _pending.clear();
        _appendNow(batch);
      }
      if (_preInitDropped > 0) {
        _appendNow('...（启动初期有 $_preInitDropped 条日志未及时落盘）');
        _preInitDropped = 0;
      }

      _add('[日志] 落盘已启用：${_currentFile!.path}');
      if (_lastSessionUnclean && hasLastSessionLog) {
        _add('[日志] 检测到上次运行未正常退出，已保留其日志（${_lastSessionLog!.length} 字符）');
      }
    } catch (e) {
      // 落盘失败不能让 App 起不来
      debugPrint('[Log] 日志落盘初始化失败: $e');
    }
  }

  /// 记录一个未捕获的异步异常（由 main() 的 runZonedGuarded 调用）。
  void recordUncaught(Object error, StackTrace stack) {
    _add('[未捕获异常] $error\n${_trimStack(stack)}');
    // 异步异常往往就是崩溃前的最后一条，立刻落盘别等攒批
    flushNow();
  }

  /// 手动记一条（用于记录非 debugPrint 的关键事件，如用户操作）。
  void log(String message) {
    _add(message);
  }

  /// 记一条带异常与堆栈的日志。
  ///
  /// 与 [log] 分开是为了统一格式：堆栈只留顶部若干帧，
  /// 太长会把环形缓冲区迅速占满，也让人难以在手机上看清重点。
  void error(String context, Object error, [StackTrace? stack]) {
    final buf = StringBuffer('[错误] $context: $error');
    if (stack != null) {
      buf.write('\n${_trimStack(stack)}');
    }
    _add(buf.toString());
  }

  void _add(String message) {
    final e = _LogEntry(DateTime.now(), message);
    _entries.add(e);
    // 环形：超出上限就从头部丢弃
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    if (!_ctrl.isClosed) _ctrl.add(e.format());
    _queuePersist(e.format());
  }

  /// 把一行排进待写队列，并确保有个攒批定时器在跑。
  void _queuePersist(String line) {
    if (!_persistReady) {
      // 落盘还没就绪（initPersistence 尚未完成或失败）：先堆在内存里，
      // 就绪后一次性补写。设上限防止极端情况爆内存。
      if (_pending.length < maxEntries) {
        _pending.add(line);
      } else {
        _preInitDropped++;
      }
      return;
    }
    _pending.add(line);
    _flushTimer ??= Timer(_flushInterval, _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (!_persistReady || _pending.isEmpty) return;
    final batch = _pending.join('\n');
    _pending.clear();
    _appendNow(batch);
  }

  /// 立刻把待写日志刷到磁盘（不等攒批）。
  ///
  /// 会在 App 切到后台、记录未捕获异常时调用 —— 这两个时刻之后进程随时可能
  /// 被系统干掉，不能赌定时器。
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_persistReady || _pending.isEmpty) return;
    final batch = _pending.join('\n');
    _pending.clear();
    try {
      // 这里用 flush: true 强制 fsync：调用它的场景就是「马上可能崩溃」，
      // 值得多花一次磁盘同步的代价。
      await _currentFile?.writeAsString('$batch\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 追加写入当前文件（同步、不 fsync）。
  ///
  /// 不 fsync 是有意的：进程被杀时数据已经在页缓存里，照样能读到；
  /// 只有断电/内核崩溃才需要 fsync，而那不属于我们要解的问题，
  /// 却要付出每 400ms 一次磁盘同步的代价。
  void _appendNow(String text) {
    final f = _currentFile;
    if (f == null) return;
    try {
      final data = utf8.encode('$text\n');
      f.writeAsBytesSync(data, mode: FileMode.append, flush: false);
      _currentBytes += data.length;
      if (_currentBytes > maxLogFileBytes) _rotateInSession();
    } catch (_) {}
  }

  /// 会话内滚动：current → last，last → prev，然后开新的 current。
  ///
  /// 只有超长会话（几小时连续播放刷屏）才会触发，正常使用一次会话
  /// 到不了 512 KB。
  void _rotateInSession() {
    final dir = _logDir;
    final cur = _currentFile;
    if (dir == null || cur == null) return;
    try {
      final prev = File('${dir.path}/prev.log');
      final last = File('${dir.path}/last.log');
      _tryDelete(prev);
      if (last.existsSync()) _tryRename(last, prev);
      _tryRename(cur, last);
      _currentFile = File('${dir.path}/current.log');
      _currentBytes = 0;
      _appendNow('...（单个日志超过 ${maxLogFileBytes ~/ 1024} KB，已滚动到新文件）');
    } catch (_) {
      // 滚动失败就继续往原文件写，总比不写强
    }
  }

  /// 标记本次运行正常退出（在 `detached` 生命周期里调用）。
  ///
  /// 不写这行的下次启动就会显示「上次未正常退出」。Android 上被系统回收
  /// 也会走到这里失败，所以 UI 文案是「可能是闪退」而非「一定闪退」。
  Future<void> markCleanExit() async {
    if (!_persistReady) return;
    _add(_cleanExitMarker);
    await flushNow();
  }

  /// 清空日志（内存 + 磁盘），给用户一个干净的复现起点。
  void clear() {
    _entries.clear();
    _pending.clear();
    _preInitDropped = 0;
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      _currentFile?.writeAsStringSync('===== 日志已清空 ${DateTime.now().toIso8601String()} =====\n');
      _currentBytes = 0;
    } catch (_) {}
  }

  /// 读上一次运行日志的尾部（最多 [maxBytes] 字节）。
  static String _readTail(File f, {int maxBytes = 96 * 1024}) {
    RandomAccessFile? raf;
    try {
      final len = f.lengthSync();
      final start = len > maxBytes ? len - maxBytes : 0;
      raf = f.openSync();
      raf.setPositionSync(start);
      final bytes = raf.readSync(len - start);
      // allowMalformed：从中间截断时首字符可能是半个多字节序列
      var text = utf8.decode(bytes, allowMalformed: true);
      if (start > 0) {
        final i = text.indexOf('\n');
        if (i >= 0) {
          text = '...（前面的 ${(start / 1024).round()} KB 已省略）\n'
              '${text.substring(i + 1)}';
        }
      }
      return text.trimRight();
    } catch (_) {
      return '';
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  static void _tryDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static void _tryRename(File from, File to) {
    try {
      from.renameSync(to.path);
    } catch (_) {
      // 跨分区/被占用时退化为拷贝后删除
      try {
        to.writeAsBytesSync(from.readAsBytesSync(), flush: false);
        from.deleteSync();
      } catch (_) {}
    }
  }

  /// 堆栈只保留前 12 帧。
  static String _trimStack(StackTrace stack) {
    final all = stack.toString().split('\n');
    const keep = 12;
    if (all.length <= keep) return stack.toString();
    return '${all.take(keep).join('\n')}\n  ... (省略 ${all.length - keep} 帧)';
  }

  /// 生成可复制的诊断报告。
  ///
  /// 设备信息由调用方传入（DeviceInfoService 只暴露 brand / capabilities，
  /// 没有 model/systemName 的公开 getter），这里不直接依赖它。
  ///
  /// 报告会把**上一次运行**的日志也接上：闪退后重开 App，内存里是空的，
  /// 但磁盘上留着崩之前那段 —— 这才是排查闪退真正需要的材料。
  Future<String> buildReport({
    required String appVersion,
    String deviceModel = '',
    String systemName = '',
    String extraInfo = '',
  }) async {
    // 先把还没写盘的补齐，保证复制出来的内容是最新的
    _flush();

    final buf = StringBuffer();
    buf.writeln('===== PerchPlay 诊断日志 =====');
    buf.writeln('时间: ${DateTime.now().toIso8601String()}');
    buf.writeln('版本: $appVersion');
    if (deviceModel.isNotEmpty) buf.writeln('设备: $deviceModel');
    if (systemName.isNotEmpty) buf.writeln('系统: $systemName');
    if (extraInfo.isNotEmpty) buf.writeln(extraInfo);
    buf.writeln('日志条数: ${_entries.length}（本次运行）');
    buf.writeln('落盘: ${_persistReady ? (currentLogPath ?? '已启用') : '未启用'}');
    if (_hasCrashEvidence) {
      buf.writeln('异常退出: 有 —— $_crashSummary');
    } else if (_lastSessionUnclean) {
      buf.writeln('上次退出: 未留正常退出标记（可能闪退，也可能被系统回收）');
    } else if (hasLastSessionLog) {
      buf.writeln('上次退出: 正常');
    }
    buf.writeln('==============================');
    buf.writeln();
    buf.writeln('---------- 本次运行 ----------');
    for (final l in lines) {
      buf.writeln(l);
    }

    // ── 上次运行 ──
    if (hasLastSessionLog) {
      buf.writeln();
      buf.writeln('---------- 上次运行 ----------');
      if (_lastSessionUnclean) {
        buf.writeln('⚠ 上次运行没有留下正常退出标记');
        buf.writeln('  （可能是闪退，也可能只是被系统回收后台进程）');
      } else {
        buf.writeln('上次运行正常退出了，以下日志仅供参考');
      }
      buf.writeln(_tailLines(_lastSessionLog!, 300));
    }

    return buf.toString();
  }

  /// 取文本最后 [n] 行（闪退的关键上下文总在末尾）。
  static String _tailLines(String text, int n) {
    final all = text.split('\n');
    if (all.length <= n) return text;
    return '...（前面 ${all.length - n} 行已省略）\n${all.sublist(all.length - n).join('\n')}';
  }

  /// 把报告写入应用私有目录，返回文件路径（用于「分享文件」）。
  ///
  /// 放 `getTemporaryDirectory` 而不是 Documents：这是可再生的临时数据，
  /// 不该占用户可见空间，系统也会自行清理。
  Future<String?> writeReportToFile(String content) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/perchplay_log_${DateTime.now().millisecondsSinceEpoch}.txt');
      await f.writeAsString(content, flush: true);
      return f.path;
    } catch (e) {
      debugPrint('[Log] 写入日志文件失败: $e');
      return null;
    }
  }
}

class _LogEntry {
  _LogEntry(this.time, this.message);
  final DateTime time;
  final String message;

  String format() {
    final t = time;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms  $message';
  }
}
