import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/online_subtitle.dart';
import 'package:perchplay/services/subtitle/subtitle_aggregator.dart';
import 'package:perchplay/services/subtitle/subtitle_source.dart';

/// 测试用假字幕源。
class _FakeSource implements SubtitleSource {
  final String _id;
  final List<OnlineSubtitle> _results;
  final Object? _error;
  final Duration _delay;

  _FakeSource(
    this._id,
    this._results, {
    Object? error,
    Duration delay = Duration.zero,
  })  : _error = error,
        _delay = delay;

  @override
  String get sourceId => _id;

  @override
  String get displayName => _id;

  @override
  bool get isAvailable => true;

  @override
  Future<List<OnlineSubtitle>> search(SubtitleQuery query) async {
    if (_delay > Duration.zero) {
      await Future.delayed(_delay);
    }
    if (_error != null) throw _error;
    return _results;
  }

  @override
  Future<String> resolveDownloadUrl(OnlineSubtitle result) async {
    return result.downloadUrl;
  }

  @override
  void dispose() {}
}

OnlineSubtitle _sub(String id, String source, {double? score}) {
  return OnlineSubtitle(
    id: id,
    name: 'sub-$id',
    source: source,
    languageCode: 'zh',
    languageName: '中文',
    format: 'srt',
    downloadUrl: 'url-$id',
    matchScore: score,
  );
}

void main() {
  group('聚合搜索', () {
    test('多服务结果合并', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource('a', [_sub('1', 'a')]));
      agg.addSource(_FakeSource('b', [_sub('2', 'b')]));

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results.length, 2);
      expect(result.totalSources, 2);
      expect(result.successfulSources, 2);
      expect(result.failures, isEmpty);
    });

    test('按 id+source 去重（不同服务同 id 不合并，同服务同 id 合并）', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource('a', [
        _sub('1', 'a'),
        _sub('1', 'a'), // 重复
        _sub('1', 'b'), // 不同服务同 id，保留
      ]));

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results.length, 2);
    });

    test('按匹配评分降序排序，无评分排后', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource('a', [
        _sub('low', 'a', score: 0.3),
        _sub('none', 'a'),
        _sub('high', 'a', score: 0.9),
      ]));

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results[0].id, 'high');
      expect(result.results[1].id, 'low');
      expect(result.results[2].id, 'none');
    });

    test('单服务失败不影响其它服务', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource(
        'bad',
        [],
        error: const SubtitleServiceException(
          SubtitleErrorType.quotaExceeded,
          'quota',
        ),
      ));
      agg.addSource(_FakeSource('good', [_sub('1', 'good')]));

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results.length, 1);
      expect(result.successfulSources, 1);
      expect(result.hasFailure, true);
      expect(result.failures['bad']?.type, SubtitleErrorType.quotaExceeded);
    });

    test('全部失败', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource(
        'bad',
        [],
        error: const SubtitleServiceException(
          SubtitleErrorType.network,
          'network',
        ),
      ));

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results, isEmpty);
      expect(result.allFailed, true);
    });

    test('单服务超时被标记失败，其它继续', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource(
        'slow',
        [_sub('slow', 'slow')],
        delay: const Duration(seconds: 5),
      ));
      agg.addSource(_FakeSource('fast', [_sub('fast', 'fast')]));

      final result = await agg.search(
        const SubtitleQuery(title: 'x'),
        timeoutPerSource: const Duration(milliseconds: 100),
      );
      expect(result.results.length, 1);
      expect(result.results.first.id, 'fast');
      expect(result.failures['slow']?.type, SubtitleErrorType.timeout);
    });

    test('无可用源返回空结果', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();

      final result = await agg.search(const SubtitleQuery(title: 'x'));
      expect(result.results, isEmpty);
      expect(result.totalSources, 0);
    });
  });

  group('取消', () {
    test('取消后旧搜索结果不覆盖新结果', () async {
      final agg = SubtitleAggregator.instance;
      agg.clearSources();
      agg.addSource(_FakeSource(
        'slow',
        [_sub('old', 'slow')],
        delay: const Duration(milliseconds: 200),
      ));

      // 启动第一次搜索（慢）
      final first = agg.search(const SubtitleQuery(title: 'old'));

      // 立即取消，清空旧源，换快源做第二次搜索
      agg.cancel();
      agg.clearSources();
      agg.addSource(_FakeSource('fast', [_sub('new', 'fast')]));
      final second = await agg.search(const SubtitleQuery(title: 'new'));

      // 第一次搜索应被取消（token 不匹配），返回空
      final firstResult = await first;
      expect(firstResult.results, isEmpty);
      // 第二次正常返回
      expect(second.results.length, 1);
      expect(second.results.first.id, 'new');
    });
  });
}
