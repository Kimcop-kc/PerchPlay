/// 字幕轨道
class SubtitleModel {
  final String path;
  final String language;
  final String title;
  final int trackIndex;
  final bool isEmbedded;

  const SubtitleModel({
    required this.path,
    required this.language,
    required this.title,
    this.trackIndex = 0,
    this.isEmbedded = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'language': language,
      'title': title,
      'trackIndex': trackIndex,
      'isEmbedded': isEmbedded,
    };
  }

  factory SubtitleModel.fromJson(Map<String, dynamic> json) {
    return SubtitleModel(
      path: json['path'] as String,
      language: json['language'] as String,
      title: json['title'] as String,
      trackIndex: json['trackIndex'] as int? ?? 0,
      isEmbedded: json['isEmbedded'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleModel &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}

/// 单条字幕
class SubtitleEntry {
  final int index;
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleEntry({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleEntry &&
          runtimeType == other.runtimeType &&
          index == other.index;

  @override
  int get hashCode => index.hashCode;
}