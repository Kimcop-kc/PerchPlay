import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/playlist_model.dart';
import '../models/video_model.dart';
import '../services/database_service.dart';
import '../services/app_settings_service.dart';
import '../services/media_grouping_service.dart';
import '../services/video_source_service.dart';
import 'package:uuid/uuid.dart';

final playlistListProvider =
    AsyncNotifierProvider<PlaylistListNotifier, List<Playlist>>(
  PlaylistListNotifier.new,
);

class PlaylistListNotifier extends AsyncNotifier<List<Playlist>> {
  final _db = DatabaseService.instance;
  final _uuid = const Uuid();

  @override
  Future<List<Playlist>> build() async {
    return _db.getAllPlaylists();
  }

  Future<void> createPlaylist(String name) async {
    final playlist = Playlist(
      id: _uuid.v4(),
      name: name,
      videoIds: [],
      createdAt: DateTime.now(),
    );
    await _db.savePlaylist(playlist);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> addVideoToPlaylist(String playlistId, String videoId) async {
    final playlists = state.value ?? [];
    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;

    final playlist = playlists[index];
    if (playlist.videoIds.contains(videoId)) return;

    // 自动列表：记住"这是用户手动加进来的"，下次扫描重建时不会被清掉
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.markAutoAdded(playlistId, videoId);
    }

    final updated = playlist.copyWith(
      videoIds: [...playlist.videoIds, videoId],
    );
    await _db.savePlaylist(updated);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> removeVideoFromPlaylist(
      String playlistId, String videoId) async {
    final playlists = state.value ?? [];
    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;

    final playlist = playlists[index];

    // 自动列表：记住"这是用户手动移出去的"，下次扫描不会又长回来
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.markAutoRemoved(playlistId, videoId);
    }

    final updated = playlist.copyWith(
      videoIds: playlist.videoIds.where((id) => id != videoId).toList(),
    );
    await _db.savePlaylist(updated);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> deletePlaylist(String playlistId) async {
    // 自动列表是扫描后重建的，只删记录会"删了又长回来"，
    // 所以额外记住用户的删除意图
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.hideAutoPlaylist(playlistId);
    }
    await _db.deletePlaylist(playlistId);
    state = AsyncData(await _db.getAllPlaylists());
  }

  /// 恢复被删掉的自动列表并立即重建
  Future<void> restoreAutoPlaylists(List<VideoModel> videos) async {
    await AppSettingsService.instance.restoreAutoPlaylists();
    await syncAutoPlaylists(videos);
  }

  /// 扫描后重建「自动列表」：
  ///   - 个人视频（相机/剪辑/短视频/录屏/社交）→ 按来源+前缀分组，不走 TMDB
  ///   - 影视（other/download）→ 按文件名识别剧名+季集，可走 TMDB 刮削
  ///   - 未被剧集分组的影视路径 → 前缀兜底（≥2 个相同前缀才成组）
  ///   - 用户手动删掉的列表不再生成
  ///   - 用户手动加进来 / 移出去的视频会保留
  /// 手动创建的列表不受影响。
  Future<void> syncAutoPlaylists(List<VideoModel> videos) async {
    try {
      await AppSettingsService.instance.ensureLoaded();
      await _db.deleteAutoPlaylists();

      final paths = videos.map((v) => v.path).toList();
      final existingVidIds = videos.map((v) => v.id).toSet();

      final allGroups = VideoSourceService.groupAll(paths);

      final auto = <Playlist>[];
      var order = -1000;

      for (final g in allGroups) {
        final kind = g.isSeries
            ? 'series'
            : g.isMovie
                ? 'movie'
                : g.isFallback
                    ? 'fallback'
                    : 'personal';
        final id = 'auto:$kind:${MediaGrouping.normalize(g.name)}';
        if (AppSettingsService.instance.isAutoPlaylistHidden(id)) continue;

        final removed = AppSettingsService.instance.autoRemovedFor(id);
        final added = AppSettingsService.instance.autoAddedFor(id);

        final ids = <String>{
          for (final i in g.indices)
            if (!removed.contains(videos[i].id)) videos[i].id,
          for (final vid in added)
            if (existingVidIds.contains(vid) && !removed.contains(vid)) vid,
        }.toList();

        if (ids.isEmpty) continue;

        auto.add(Playlist(
          id: id,
          name: g.name,
          videoIds: ids,
          createdAt: DateTime.now(),
          sortOrder: order++,
          isAuto: true,
        ));
      }

      for (final pl in auto) {
        await _db.savePlaylist(pl);
      }
      state = AsyncData(await _db.getAllPlaylists());
    } catch (e) {
      // 自动分组失败不应影响影库
      state = AsyncData(await _db.getAllPlaylists());
    }
  }

  /// 按 id 取列表（播放队列用）
  Playlist? byId(String id) {
    for (final p in state.value ?? const <Playlist>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 按名称取列表（新建后立即取回）
  Playlist? byName(String name) {
    for (final p in state.value ?? const <Playlist>[]) {
      if (p.name == name) return p;
    }
    return null;
  }
}

// 向后兼容别名
final playlistProvider = playlistListProvider;