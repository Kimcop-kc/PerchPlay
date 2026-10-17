// 「视频被删 / 移出影库后，播放列表里的失效 id 要剔掉」的回归测试
//
// 背景：播放列表只存 videoIds。视频从影库移除后这些 id 永远播不了，
// 手动列表又不会像自动列表那样重建，残留下来的就是一条点不开的黑条目。
// 规则必须同时满足：
//   1. 失效 id 剔掉（自动列表 + 手动列表一视同仁）；
//   2. 列表本身保留 —— 剔空就变空列表，绝不能顺手把列表删了。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/playlist_model.dart';
import 'package:perchplay/services/playlist_prune_service.dart';

Playlist _playlist(String id, List<String> videoIds, {bool isAuto = false}) =>
    Playlist(
      id: id,
      name: id,
      videoIds: videoIds,
      createdAt: DateTime(2025, 1, 1),
      isAuto: isAuto,
    );

void main() {
  test('手动列表：剔掉失效 id，其余顺序不变', () {
    final playlist = _playlist('manual-1', ['a', 'b', 'c', 'd']);
    final updated = PlaylistPruneService.strip(playlist, {'b', 'd'});

    expect(updated, isNotNull);
    expect(updated!.videoIds, ['a', 'c']);
    // 列表身份/名字不能被顺手改掉
    expect(updated.id, 'manual-1');
    expect(updated.name, 'manual-1');
  });

  test('自动列表同样要清（扫描重建之前它同样点不开）', () {
    final playlist = _playlist('auto:series:foo', ['a', 'b'], isAuto: true);
    final updated = PlaylistPruneService.strip(playlist, {'a'});
    expect(updated!.videoIds, ['b']);
    expect(updated.isAuto, isTrue);
  });

  test('剔空后列表还在（变空列表，不删列表）', () {
    final playlist = _playlist('manual-2', ['a']);
    final updated = PlaylistPruneService.strip(playlist, {'a'});

    expect(updated, isNotNull);
    expect(updated!.videoIds, isEmpty);
    expect(updated.id, 'manual-2');
  });

  test('没有失效 id 时返回 null（调用方据此跳过写库）', () {
    final playlist = _playlist('manual-3', ['a', 'b']);
    expect(PlaylistPruneService.strip(playlist, {'x'}), isNull);
    expect(PlaylistPruneService.strip(playlist, <String>{}), isNull);
  });

  test('多个视频同时被移除时一次剔干净', () {
    final playlist = _playlist('manual-4', ['a', 'b', 'c', 'd', 'e']);
    final updated = PlaylistPruneService.strip(playlist, {'a', 'c', 'e'});
    expect(updated!.videoIds, ['b', 'd']);
  });

  test('keepExisting：空集合时原样返回，不产生新列表内容', () {
    final ids = ['a', 'b'];
    expect(PlaylistPruneService.keepExisting(ids, <String>{}), ['a', 'b']);
    expect(PlaylistPruneService.keepExisting(ids, {'a'}), ['b']);
    expect(PlaylistPruneService.keepExisting(const [], {'a'}), isEmpty);
  });

  test('重复 id 也被正确剔除（历史数据里可能出现）', () {
    final playlist = _playlist('manual-5', ['a', 'a', 'b']);
    final updated = PlaylistPruneService.strip(playlist, {'a'});
    expect(updated!.videoIds, ['b']);
  });
}
