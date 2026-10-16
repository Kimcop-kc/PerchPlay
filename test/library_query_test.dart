// 影库搜索 / 排序 / 筛选测试
//
// 这些逻辑是纯函数，最容易在重构时被改坏，所以把常见组合钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/library_query_service.dart';

VideoModel _v(
  String name, {
  String? folder,
  int size = 1000,
  int durationMs = 60000,
  double lastPosition = 0,
  bool favorite = false,
  int modifiedDay = 1,
  int addedDay = 1,
}) {
  return VideoModel(
    id: name,
    path: '${folder ?? '/sdcard/Movies'}/$name',
    name: name,
    folderPath: folder ?? '/sdcard/Movies',
    size: size,
    durationMs: durationMs,
    dateAdded: DateTime(2026, 1, addedDay),
    dateModified: DateTime(2026, 1, modifiedDay),
    lastPosition: lastPosition,
    isFavorite: favorite,
  );
}

void main() {
  group('搜索', () {
    final videos = [
      _v('Interstellar.2014.mkv'),
      _v('Heartstopper.Forever.mkv'),
      _v('holiday.mp4', folder: '/sdcard/DCIM/Camera'),
    ];

    test('按文件名匹配，大小写不敏感', () {
      expect(LibraryQuery.apply(videos, query: 'interstellar').length, 1);
      expect(LibraryQuery.apply(videos, query: 'INTERSTELLAR').length, 1);
      expect(LibraryQuery.apply(videos, query: 'heart').length, 1);
    });

    test('文件夹路径也参与匹配', () {
      final r = LibraryQuery.apply(videos, query: 'camera');
      expect(r.length, 1);
      expect(r.first.name, 'holiday.mp4');
    });

    test('空搜索词返回全部', () {
      expect(LibraryQuery.apply(videos, query: '   ').length, 3);
    });

    test('搜不到返回空', () {
      expect(LibraryQuery.apply(videos, query: 'zzz'), isEmpty);
    });
  });

  group('筛选', () {
    final videos = [
      _v('a.mkv', favorite: true),
      _v('b.mkv', durationMs: 100000, lastPosition: 10000), // 未看完
      _v('c.mkv', durationMs: 100000, lastPosition: 99000), // 99% → 已看完
      _v('d.mkv', durationMs: 0), // 时长未知，不算未看完
    ];

    test('只看收藏', () {
      final r = LibraryQuery.apply(videos, filter: LibraryFilter.favorite);
      expect(r.map((e) => e.name), ['a.mkv']);
    });

    test('未看完：进度 0 也算未看完，>=95% 不算', () {
      final r = LibraryQuery.apply(videos, filter: LibraryFilter.unwatched);
      final names = r.map((e) => e.name).toList();
      expect(names, contains('a.mkv')); // 进度 0
      expect(names, contains('b.mkv')); // 10%
      expect(names, isNot(contains('c.mkv'))); // 99% 已看完
      expect(names, isNot(contains('d.mkv'))); // 时长未知
    });
  });

  group('排序', () {
    test('名称：数字按数值比较（第2集在第10集之前）', () {
      final videos = [
        _v('Show.E10.mkv'),
        _v('Show.E2.mkv'),
        _v('Show.E1.mkv'),
      ];
      LibraryQuery.sortInPlace(videos, LibrarySort.name);
      expect(videos.map((e) => e.name), [
        'Show.E1.mkv',
        'Show.E2.mkv',
        'Show.E10.mkv',
      ]);
    });

    test('名称：大小写不影响顺序', () {
      final videos = [_v('banana.mkv'), _v('Apple.mkv')];
      LibraryQuery.sortInPlace(videos, LibrarySort.name);
      expect(videos.map((e) => e.name), ['Apple.mkv', 'banana.mkv']);
    });

    test('最近修改：新的在前', () {
      final videos = [
        _v('old.mkv', modifiedDay: 1),
        _v('new.mkv', modifiedDay: 20),
        _v('mid.mkv', modifiedDay: 10),
      ];
      LibraryQuery.sortInPlace(videos, LibrarySort.dateModified);
      expect(videos.map((e) => e.name), ['new.mkv', 'mid.mkv', 'old.mkv']);
    });

    test('时长 / 大小：大的在前', () {
      final byDur = [_v('short.mkv', durationMs: 10), _v('long.mkv', durationMs: 999)];
      LibraryQuery.sortInPlace(byDur, LibrarySort.duration);
      expect(byDur.first.name, 'long.mkv');

      final bySize = [_v('small.mkv', size: 1), _v('big.mkv', size: 9999)];
      LibraryQuery.sortInPlace(bySize, LibrarySort.size);
      expect(bySize.first.name, 'big.mkv');
    });

    test('加入时间：新的在前', () {
      final videos = [
        _v('first.mkv', addedDay: 1),
        _v('last.mkv', addedDay: 9),
      ];
      LibraryQuery.sortInPlace(videos, LibrarySort.dateAdded);
      expect(videos.first.name, 'last.mkv');
    });
  });

  group('组合与边界', () {
    test('搜索 + 筛选 + 排序 一起生效', () {
      final videos = [
        _v('Show.E10.mkv', favorite: true),
        _v('Show.E2.mkv', favorite: true),
        _v('Show.E1.mkv', favorite: false),
        _v('Other.E1.mkv', favorite: true),
      ];
      final r = LibraryQuery.apply(
        videos,
        query: 'show',
        filter: LibraryFilter.favorite,
        sort: LibrarySort.name,
      );
      expect(r.map((e) => e.name), ['Show.E2.mkv', 'Show.E10.mkv']);
    });

    test('apply 不改动入参顺序', () {
      final videos = [_v('b.mkv'), _v('a.mkv')];
      LibraryQuery.apply(videos, sort: LibrarySort.name);
      expect(videos.map((e) => e.name), ['b.mkv', 'a.mkv']);
    });

    test('枚举 id 往返：未知 id 回落到默认值', () {
      expect(LibrarySort.fromId('duration'), LibrarySort.duration);
      expect(LibrarySort.fromId('不存在'), LibrarySort.name);
      expect(LibraryFilter.fromId('favorite'), LibraryFilter.favorite);
      expect(LibraryFilter.fromId(null), LibraryFilter.all);
    });

    test('compareNatural 对纯文字与混合串都不崩', () {
      expect(LibraryQuery.compareNatural('a', 'a'), 0);
      expect(LibraryQuery.compareNatural('a1', 'a2'), lessThan(0));
      expect(LibraryQuery.compareNatural('中文1', '中文2'), lessThan(0));
      expect(LibraryQuery.compareNatural('x', 'x1'), lessThan(0));
    });
  });
}
