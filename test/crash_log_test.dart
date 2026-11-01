import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/log_service.dart';

/// 崩溃日志判定的单元测试。
///
/// 重点不是「能不能写文件」（那要真机），而是**判定逻辑**：
///
///  - 什么情况算「有崩溃证据」（要报警给用户看）
///  - 什么情况只是「没留退出标记」（不该报警）
///
/// 这个区分很重要：用户从任务管理器划掉 App 也不会留退出标记，
/// 如果按「unclean = 闪退」来报警，每次正常关 App 都会看到「上次闪退了」，
/// 属于纯噪音，用户很快就不信这个功能了。
void main() {
  group('崩溃证据标记', () {
    test('初始状态：没有证据', () {
      // 单例，前面测试可能改过；这里只验证「没有证据时」的行为
      final svc = LogService.instance;
      // 注意：不能断言 hasCrashEvidence == false，因为这是单例、
      // 其他测试可能已经打过标。只验证「没有证据时摘要为空」这个不变量。
      if (!svc.hasCrashEvidence) {
        expect(svc.crashSummary, isEmpty);
        expect(svc.crashDetail, isEmpty);
      }
    });

    test('打标后立刻有证据 + 摘要取第一行', () {
      final svc = LogService.instance;
      svc.markCrashEvidence(
        '===== 系统记录的异常退出 =====\n'
        '原因: 原生崩溃（REASON_CRASH_NATIVE，如 libmpv 段错误）\n'
        '时间: 2026-11-01 01:00:00\n',
      );

      expect(svc.hasCrashEvidence, isTrue);
      // 摘要只取第一行，不把整段堆栈摊到设置页上
      expect(svc.crashSummary, '===== 系统记录的异常退出 =====');
      // 全文要完整保留，供「上次闪退日志」面板复制
      expect(svc.crashDetail, contains('REASON_CRASH_NATIVE'));
    });

    test('空内容不覆盖已有证据', () {
      final svc = LogService.instance;
      // 先放一个真实证据
      svc.markCrashEvidence('signal = 11\n===== 原生崩溃 =====');
      final before = svc.crashSummary;

      // 再来空内容（原生侧没崩时会返回 null / 空串）
      svc.markCrashEvidence('');
      svc.markCrashEvidence('   \n  \t ');

      // 不变量：空输入不能把已有证据冲掉，也不能改摘要
      expect(svc.hasCrashEvidence, isTrue);
      expect(svc.crashSummary, before);
    });

    test('多行堆栈：摘要不含换行', () {
      final svc = LogService.instance;
      svc.markCrashEvidence('signal = 11\n===== 原生崩溃 =====\n堆栈若干');
      expect(svc.crashSummary, 'signal = 11');
      expect(svc.crashSummary.contains('\n'), isFalse);
    });
  });

  group('报告拼装', () {
    test('报告含本次运行段', () async {
      final svc = LogService.instance;
      svc.log('[测试] 一条普通日志');
      final report = await svc.buildReport(appVersion: 'v0.0.0-test');
      expect(report, contains('PerchPlay 诊断日志'));
      expect(report, contains('版本: v0.0.0-test'));
      expect(report, contains('---------- 本次运行 ----------'));
      expect(report, contains('[测试] 一条普通日志'));
    });

    test('报告里崩溃证据会影响头部摘要', () async {
      final svc = LogService.instance;
      svc.markCrashEvidence('===== 未捕获异常 =====\njava.lang.NullPointerException');
      final report = await svc.buildReport(appVersion: 'v0.0.0-test');
      expect(report, contains('崩溃证据: 有'));
      expect(report, contains('未捕获异常'));
    });
  });

  group('缓冲区上限', () {
    test('超过 maxEntries 后丢最旧的', () {
      final svc = LogService.instance;
      // 塞超过上限的条数
      for (var i = 0; i < LogService.maxEntries + 50; i++) {
        svc.log('[压测] 第 $i 条');
      }
      // 环形缓冲区不该无限增长
      expect(svc.count, lessThanOrEqualTo(LogService.maxEntries));
      // 最后一条一定在（丢的是头部）
      expect(svc.lines.last, contains('第 ${LogService.maxEntries + 49} 条'));
    });
  });

  group('堆栈裁剪', () {
    test('短堆栈原样保留', () {
      final svc = LogService.instance;
      svc.error('测试上下文', 'boom', StackTrace.fromString('line1\nline2'));
      final last = svc.lines.last;
      expect(last, contains('boom'));
      expect(last, contains('line1'));
      // 裁掉了不该有的省略提示
      expect(last.contains('省略'), isFalse);
    });

    test('长堆栈只留 12 帧', () {
      final svc = LogService.instance;
      final stack = List.generate(40, (i) => '#$i frame').join('\n');
      svc.error('长堆栈', 'err', StackTrace.fromString(stack));
      final last = svc.lines.last;
      // 12 帧 + 末尾一行省略说明
      expect(last, contains('#11 frame'));
      expect(last.contains('#12 frame'), isFalse);
      expect(last, contains('省略 28 帧'));
    });
  });
}
