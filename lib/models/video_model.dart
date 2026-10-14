import 'package:freezed_annotation/freezed_annotation.dart';

part 'video_model.freezed.dart';
part 'video_model.g.dart';

@freezed
class VideoModel with _$VideoModel {
  const factory VideoModel({
    required String id,
    required String path,
    required String name,
    required String folderPath,
    required int size,
    required int durationMs,
    required DateTime dateAdded,
    required DateTime dateModified,
    @Default('') String thumbnailPath,
    @Default(0.0) double lastPosition,
    @Default(0) int playCount,
    @Default(false) bool isFavorite,
  }) = _VideoModel;

  factory VideoModel.fromJson(Map<String, dynamic> json) =>
      _$VideoModelFromJson(json);
}