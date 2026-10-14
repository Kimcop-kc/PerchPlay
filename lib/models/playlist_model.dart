import 'package:freezed_annotation/freezed_annotation.dart';

part 'playlist_model.freezed.dart';
part 'playlist_model.g.dart';

@freezed
class Playlist with _$Playlist {
  const factory Playlist({
    required String id,
    required String name,
    required List<String> videoIds,
    required DateTime createdAt,
    @Default(0) int sortOrder,
  }) = _Playlist;

  factory Playlist.fromJson(Map<String, dynamic> json) =>
      _$PlaylistFromJson(json);
}