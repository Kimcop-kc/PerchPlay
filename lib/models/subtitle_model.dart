import 'package:freezed_annotation/freezed_annotation.dart';

part 'subtitle_model.freezed.dart';
part 'subtitle_model.g.dart';

@freezed
class SubtitleModel with _$SubtitleModel {
  const factory SubtitleModel({
    required String path,
    required String language,
    required String title,
    @Default(0) int trackIndex,
    @Default(false) bool isEmbedded,
  }) = _SubtitleModel;

  factory SubtitleModel.fromJson(Map<String, dynamic> json) =>
      _$SubtitleModelFromJson(json);
}

@freezed
class SubtitleEntry with _$SubtitleEntry {
  const factory SubtitleEntry({
    required int index,
    required Duration start,
    required Duration end,
    required String text,
  }) = _SubtitleEntry;
}