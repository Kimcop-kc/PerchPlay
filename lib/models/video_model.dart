/// 视频文件模型
class VideoModel {
  final String id;
  final String path;
  final String name;
  final String folderPath;
  final int size;
  final int durationMs;
  final DateTime dateAdded;
  final DateTime dateModified;
  final String thumbnailPath;
  final double lastPosition;
  final int playCount;
  final bool isFavorite;
  final DateTime? lastPlayed;

  const VideoModel({
    required this.id,
    required this.path,
    required this.name,
    required this.folderPath,
    required this.size,
    required this.durationMs,
    required this.dateAdded,
    required this.dateModified,
    this.thumbnailPath = '',
    this.lastPosition = 0.0,
    this.playCount = 0,
    this.isFavorite = false,
    this.lastPlayed,
  });

  VideoModel copyWith({
    String? id,
    String? path,
    String? name,
    String? folderPath,
    int? size,
    int? durationMs,
    DateTime? dateAdded,
    DateTime? dateModified,
    String? thumbnailPath,
    double? lastPosition,
    int? playCount,
    bool? isFavorite,
    DateTime? lastPlayed,
  }) {
    return VideoModel(
      id: id ?? this.id,
      path: path ?? this.path,
      name: name ?? this.name,
      folderPath: folderPath ?? this.folderPath,
      size: size ?? this.size,
      durationMs: durationMs ?? this.durationMs,
      dateAdded: dateAdded ?? this.dateAdded,
      dateModified: dateModified ?? this.dateModified,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      lastPosition: lastPosition ?? this.lastPosition,
      playCount: playCount ?? this.playCount,
      isFavorite: isFavorite ?? this.isFavorite,
      lastPlayed: lastPlayed ?? this.lastPlayed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'name': name,
      'folderPath': folderPath,
      'size': size,
      'durationMs': durationMs,
      'dateAdded': dateAdded.toIso8601String(),
      'dateModified': dateModified.toIso8601String(),
      'thumbnailPath': thumbnailPath,
      'lastPosition': lastPosition,
      'playCount': playCount,
      'isFavorite': isFavorite ? 1 : 0,
      'lastPlayed': lastPlayed?.toIso8601String(),
    };
  }

  factory VideoModel.fromJson(Map<String, dynamic> json) {
    return VideoModel(
      id: json['id'] as String,
      path: json['path'] as String,
      name: json['name'] as String,
      folderPath: json['folderPath'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      durationMs: json['durationMs'] as int? ?? 0,
      dateAdded: json['dateAdded'] != null
          ? DateTime.parse(json['dateAdded'] as String)
          : DateTime.now(),
      dateModified: json['dateModified'] != null
          ? DateTime.parse(json['dateModified'] as String)
          : DateTime.now(),
      thumbnailPath: json['thumbnailPath'] as String? ?? '',
      lastPosition: (json['lastPosition'] as num?)?.toDouble() ?? 0.0,
      playCount: json['playCount'] as int? ?? 0,
      isFavorite: (json['isFavorite'] as int? ?? 0) == 1,
      lastPlayed: json['lastPlayed'] != null
          ? DateTime.parse(json['lastPlayed'] as String)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoModel && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}