import 'dart:async';
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
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  /// 最多保留多少条（约覆盖最近几分钟的操作）。
  static const int maxEntries = 800;

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

  /// 安装 debugPrint 拦截。
  ///
  /// **必须在 runApp 之前调用**，且越早越好 —— 否则启动早期的
  /// MediaKit / 设备信息初始化日志会漏掉（那恰恰是最容易出问题的地方）。
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

    // 未捕获的异步异常也要收进来 —— 很多崩溃就发生在这里
    // （例如原生通道 Future 没 await 抛出的错误）
    runZonedGuarded(
      () {},
      (error, stack) {
        _add('[未捕获异常] $error\n${_trimStack(stack)}');
      },
    );
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
  }

  /// 堆栈只保留前 12 帧。
  static String _trimStack(StackTrace stack) {
    final all = stack.toString().split('\n');
    const keep = 12;
    if (all.length <= keep) return stack.toString();
    return '${all.take(keep).join('\n')}\n  ... (省略 ${all.length - keep} 帧)';
  }

  void clear() {
    _entries.clear();
  }

  /// 生成可复制的诊断报告。
  ///
  /// 设备信息由调用方传入（DeviceInfoService 只暴露 brand / capabilities，
  /// 没有 model/systemName 的公开 getter），这里不直接依赖它。
  Future<String> buildReport({
    required String appVersion,
    String deviceModel = '',
    String systemName = '',
    String extraInfo = '',
  }) async {
    final buf = StringBuffer();
    buf.writeln('===== PerchPlay 诊断日志 =====');
    buf.writeln('时间: ${DateTime.now().toIso8601String()}');
    buf.writeln('版本: $appVersion');
    if (deviceModel.isNotEmpty) buf.writeln('设备: $deviceModel');
    if (systemName.isNotEmpty) buf.writeln('系统: $systemName');
    if (extraInfo.isNotEmpty) buf.writeln(extraInfo);
    buf.writeln('日志条数: ${_entries.length}');
    buf.writeln('==============================');
    buf.writeln();
    for (final l in lines) {
      buf.writeln(l);
    }
    return buf.toString();
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
