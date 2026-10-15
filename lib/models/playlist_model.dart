/// 播放列表
class Playlist {
  final String id;
  final String name;
  final List<String> videoIds;
  final DateTime createdAt;
  final int sortOrder;

  /// 是否由扫描自动生成（按文件名分组的剧集/电影），每次扫描会重建
  final bool isAuto;

  const Playlist({
    required this.id,
    required this.name,
    required this.videoIds,
    required this.createdAt,
    this.sortOrder = 0,
    this.isAuto = false,
  });

  Playlist copyWith({
    String? id,
    String? name,
    List<String>? videoIds,
    DateTime? createdAt,
    int? sortOrder,
    bool? isAuto,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      videoIds: videoIds ?? this.videoIds,
      createdAt: createdAt ?? this.createdAt,
      sortOrder: sortOrder ?? this.sortOrder,
      isAuto: isAuto ?? this.isAuto,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'videoIds': videoIds,
      'createdAt': createdAt.toIso8601String(),
      'sortOrder': sortOrder,
      'isAuto': isAuto ? 1 : 0,
    };
  }

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      videoIds: List<String>.from(json['videoIds'] as List? ?? []),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      sortOrder: json['sortOrder'] as int? ?? 0,
      isAuto: (json['isAuto'] as int? ?? 0) == 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Playlist && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}