import 'dart:async';

import '../../models/online_subtitle.dart';
import 'subtitle_source.dart';

/// 字幕聚合搜索结果。
class SubtitleAggregateResult {
  /// 合并后的字幕列表（已去重排序）。
  final List<OnlineSubtitle> results;

  /// 参与查询的服务数。
  final int totalSources;

  /// 成功返回结果的服务数。
  final int successfulSources;

  /// 各服务的失败信息（服务 id → 错误），供 UI 提示部分失败。
  final Map<String, SubtitleServiceException> failures;

  /// 是否有服务失败（部分成功或全部失败）。
  bool get hasFailure => failures.isNotEmpty;

  /// 全部失败（没有成功返回的服务）。
  bool get allFailed => successfulSources == 0 && failures.isNotEmpty;

  const SubtitleAggregateResult({
    required this.results,
    required this.totalSources,
    required this.successfulSources,
    required this.failures,
  });
}

/// 字幕聚合服务：并发查询多个字幕源，合并去重排序。
///
/// 特性：
/// - 多服务并发搜索，单个服务超时不影响其它服务
/// - 结果按 id+source 去重
/// - 按匹配评分降序排序（无评分的排后）
/// - 统一取消（页面退出后不再发请求）
/// - 防止旧搜索结果覆盖新结果（token 机制）
class SubtitleAggregator {
  SubtitleAggregator._();

  static final SubtitleAggregator instance = SubtitleAggregator._();

  /// 已注册的字幕源。
  final List<SubtitleSource> _sources = [];

  /// 当前搜索的 token（递增，防止旧结果覆盖新结果）。
  int _searchToken = 0;

  /// 注册一个字幕源。
  void addSource(SubtitleSource source) {
    if (!_sources.contains(source)) _sources.add(source);
  }

  /// 清空所有字幕源（测试/重建用）。
  void clearSources() {
    _sources.clear();
  }

  /// 当前可用（已配置且未禁用）的源。
  List<SubtitleSource> get availableSources =>
      _sources.where((s) => s.isAvailable).toList();

  /// 取消当前正在进行的搜索。
  void cancel() {
    _searchToken++;
  }

  /// 并发搜索所有可用源。
  ///
  /// [timeoutPerSource] 单个服务超时，超过后该服务标记失败、其它继续。
  /// 返回合并去重排序后的结果。
  Future<SubtitleAggregateResult> search(
    SubtitleQuery query, {
    Duration timeoutPerSource = const Duration(seconds: 12),
  }) async {
    final token = ++_searchToken;
    final sources = availableSources;

    if (sources.isEmpty) {
      return SubtitleAggregateResult(
        results: const [],
        totalSources: 0,
        successfulSources: 0,
        failures: const {},
      );
    }

    final results = <OnlineSubtitle>[];
    final failures = <String, SubtitleServiceException>{};
    var successful = 0;

    // 并发查询所有源，单个失败不影响其它
    await Future.wait(sources.map((source) async {
      try {
        final list = await source
            .search(query)
            .timeout(timeoutPerSource)
            .catchError((Object e) {
          throw _toServiceException(e);
        });
        // 旧搜索已被取消，丢弃结果
        if (token != _searchToken) return;
        results.addAll(list);
        successful++;
      } catch (e) {
        if (token != _searchToken) return;
        failures[source.sourceId] = _toServiceException(e);
      }
    }));

    // 已取消，返回空
    if (token != _searchToken) {
      return const SubtitleAggregateResult(
        results: [],
        totalSources: 0,
        successfulSources: 0,
        failures: {},
      );
    }

    // 去重 + 排序
    final deduped = _dedupe(results);
    final sorted = _sort(deduped);

    return SubtitleAggregateResult(
      results: sorted,
      totalSources: sources.length,
      successfulSources: successful,
      failures: failures,
    );
  }

  /// 去重：按 id+source 唯一，保留先出现的（服务优先级顺序）。
  List<OnlineSubtitle> _dedupe(List<OnlineSubtitle> list) {
    final seen = <String>{};
    final out = <OnlineSubtitle>[];
    for (final s in list) {
      final key = '${s.source}:${s.id}';
      if (seen.add(key)) out.add(s);
    }
    return out;
  }

  /// 排序：匹配评分降序，无评分的排最后，同分按来源名稳定排序。
  List<OnlineSubtitle> _sort(List<OnlineSubtitle> list) {
    final sorted = [...list];
    sorted.sort((a, b) {
      final sa = a.matchScore ?? -1.0;
      final sb = b.matchScore ?? -1.0;
      if (sa != sb) return sb.compareTo(sa);
      return a.source.compareTo(b.source);
    });
    return sorted;
  }

  /// 把任意异常转成 [SubtitleServiceException]。
  SubtitleServiceException _toServiceException(Object e) {
    if (e is SubtitleServiceException) return e;
    if (e is TimeoutException) {
      return const SubtitleServiceException(
        SubtitleErrorType.timeout,
        '查询超时',
      );
    }
    return SubtitleServiceException(
      SubtitleErrorType.unknown,
      e.toString(),
    );
  }

  /// 释放所有源。
  void dispose() {
    cancel();
    for (final s in _sources) {
      s.dispose();
    }
    _sources.clear();
  }
}
