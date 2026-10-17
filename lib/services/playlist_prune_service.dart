import '../models/playlist_model.dart';

/// 「视频被删 / 被移出影库后，播放列表里的 id 怎么办」的纯规则
///
/// 播放列表只存 videoIds（sqflite 里是一段 JSON），视频从影库移除后这些 id
/// 就永远播不了：手动列表不会像自动列表那样重建，残留下来就是一条点不开的
/// 黑条目。规则固定为「剔 id、保留列表」——列表本身是用户的组织结果，
/// 哪怕剔空也要留着（用户可以再往里加视频）。
class PlaylistPruneService {
  PlaylistPruneService._();

  /// 从一组 id 里剔除失效的，其余保持原顺序
  static List<String> keepExisting(
    List<String> videoIds,
    Set<String> removedIds,
  ) {
    if (removedIds.isEmpty) return videoIds;
    return [
      for (final id in videoIds)
        if (!removedIds.contains(id)) id,
    ];
  }

  /// 剔除后在必要时返回新列表；**没有任何变化时返回 null**
  ///
  /// 返回 null 是为了让调用方（数据库层）跳过写库：播放列表多的时候，
  /// 每次删一个视频就把所有列表重写一遍既慢又没必要。
  static Playlist? strip(Playlist playlist, Set<String> removedIds) {
    final kept = keepExisting(playlist.videoIds, removedIds);
    if (kept.length == playlist.videoIds.length) return null;
    return playlist.copyWith(videoIds: kept);
  }
}
