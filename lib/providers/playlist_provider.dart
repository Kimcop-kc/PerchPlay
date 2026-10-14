import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/playlist_model.dart';
import '../services/database_service.dart';
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
}