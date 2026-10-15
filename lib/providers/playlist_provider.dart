import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/playlist_model.dart';
import '../models/video_model.dart';
import '../services/database_service.dart';
import '../services/media_namer_service.dart';
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
    final updated = playlist.copyWith(
      videoIds: playlist.videoIds.where((id) => id != videoId).toList(),
    );
    await _db.savePlaylist(updated);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _db.deletePlaylist(playlistId);
    state = AsyncData(await _db.getAllPlaylists());
  }

  /// 扫描后重建「自动列表」：
  /// - 同一剧集（文件名里的 S01E02 / 第02集 / EP02…）合成一个列表，按季集排序
  /// - 非剧集文件（电影）归入「电影」列表
  /// 手动创建的列表不受影响。
  Future<void> syncAutoPlaylists(List<VideoModel> videos) async {
    try {
      await _db.deleteAutoPlaylists();

      final series = <String, List<MapEntry<int, VideoModel>>>{};
      final movies = <VideoModel>[];
      for (final v in videos) {
        final info = MediaNamer.parse(v.path);
        if (info.isEpisode) {
          series
              .putIfAbsent(info.seriesTitle, () => [])
              .add(MapEntry(info.orderKey, v));
        } else {
          movies.add(v);
        }
      }

      final auto = <Playlist>[];
      var order = -1000; // 自动列表排前面
      series.forEach((title, list) {
        if (list.length < 2) return; // 单集不建列表
        list.sort((a, b) => a.key.compareTo(b.key));
        auto.add(Playlist(
          id: 'auto:series:$title',
          name: title,
          videoIds: list.map((e) => e.value.id).toList(),
          createdAt: DateTime.now(),
          sortOrder: order++,
          isAuto: true,
        ));
      });
      if (movies.length >= 2) {
        auto.add(Playlist(
          id: 'auto:movies',
          name: '电影',
          videoIds: movies.map((v) => v.id).toList(),
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