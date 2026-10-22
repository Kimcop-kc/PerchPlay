/// 在线字幕搜索结果模型。
///
/// 与本地 [SubtitleModel]（见 subtitle_model.dart）职责不同：
/// - 本模型表达「在线字幕服务返回的一条搜索结果」，
///   含来源、下载地址、匹配评分等在线语义字段。
/// - 下载成功、落盘并验证后，由下载服务转换成 [SubtitleModel]
///   交给现有播放器加载链路，避免在本地模型里塞无关字段。
///
/// 所有可选字段缺失时用 null，不伪造。
class OnlineSubtitle {
  /// 服务内唯一 ID（去重依据）。
  final String id;

  /// 字幕名称（服务返回的原始名，可能含版本/发布组）。
  final String name;

  /// 字幕来源（如 `opensubtitles`、`subdl`），统一为小写标识。
  final String source;

  /// 语言代码（ISO 639-1，统一小写，如 `zh`、`en`）。
  final String languageCode;

  /// 语言显示名（如 `中文`、`English`）。
  final String languageName;

  /// 字幕格式（`srt`/`ass`/`ssa`/`vtt`，统一小写）。
  final String format;

  /// 文件大小（字节），服务未提供时为 null。
  final int? fileSizeBytes;

  /// 下载地址或服务提供的下载标识（下载流程用）。
  final String downloadUrl;

  /// 对应影片名称（服务返回的，可能为空）。
  final String? movieName;

  /// 对应影片年份（服务返回的，可能为空）。
  final int? year;

  /// 电视剧季数（服务返回的，可能为空）。
  final int? season;

  /// 电视剧集数（服务返回的，可能为空）。
  final int? episode;

  /// 发布组 / 版本信息（如 `WEB-DL`、`BluRay`）。
  final String? releaseGroup;

  /// 是否为听障字幕（SDH/HI）。
  final bool isHearingImpaired;

  /// 是否为强制字幕（Forced）。
  final bool isForced;

  /// 是否已下载到本地。
  final bool isDownloaded;

  /// 下载状态及错误信息（未下载/下载中/失败原因）。
  final String? downloadError;

  /// 匹配评分（0~1），由匹配算法计算，null 表示未评分。
  final double? matchScore;

  /// 匹配评分说明（可选，用于 UI 展示匹配原因）。
  final String? matchReason;

  const OnlineSubtitle({
    required this.id,
    required this.name,
    required this.source,
    required this.languageCode,
    required this.languageName,
    required this.format,
    required this.downloadUrl,
    this.fileSizeBytes,
    this.movieName,
    this.year,
    this.season,
    this.episode,
    this.releaseGroup,
    this.isHearingImpaired = false,
    this.isForced = false,
    this.isDownloaded = false,
    this.downloadError,
    this.matchScore,
    this.matchReason,
  });

  OnlineSubtitle copyWith({
    bool? isDownloaded,
    String? downloadError,
    double? matchScore,
    String? matchReason,
  }) {
    return OnlineSubtitle(
      id: id,
      name: name,
      source: source,
      languageCode: languageCode,
      languageName: languageName,
      format: format,
      downloadUrl: downloadUrl,
      fileSizeBytes: fileSizeBytes,
      movieName: movieName,
      year: year,
      season: season,
      episode: episode,
      releaseGroup: releaseGroup,
      isHearingImpaired: isHearingImpaired,
      isForced: isForced,
      isDownloaded: isDownloaded ?? this.isDownloaded,
      downloadError: downloadError ?? this.downloadError,
      matchScore: matchScore ?? this.matchScore,
      matchReason: matchReason ?? this.matchReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'source': source,
      'languageCode': languageCode,
      'languageName': languageName,
      'format': format,
      'downloadUrl': downloadUrl,
      'fileSizeBytes': fileSizeBytes,
      'movieName': movieName,
      'year': year,
      'season': season,
      'episode': episode,
      'releaseGroup': releaseGroup,
      'isHearingImpaired': isHearingImpaired,
      'isForced': isForced,
      'isDownloaded': isDownloaded,
      'downloadError': downloadError,
      'matchScore': matchScore,
      'matchReason': matchReason,
    };
  }

  factory OnlineSubtitle.fromJson(Map<String, dynamic> json) {
    return OnlineSubtitle(
      id: json['id'] as String,
      name: json['name'] as String,
      source: json['source'] as String,
      languageCode: json['languageCode'] as String,
      languageName: json['languageName'] as String,
      format: json['format'] as String,
      downloadUrl: json['downloadUrl'] as String,
      fileSizeBytes: json['fileSizeBytes'] as int?,
      movieName: json['movieName'] as String?,
      year: json['year'] as int?,
      season: json['season'] as int?,
      episode: json['episode'] as int?,
      releaseGroup: json['releaseGroup'] as String?,
      isHearingImpaired: json['isHearingImpaired'] as bool? ?? false,
      isForced: json['isForced'] as bool? ?? false,
      isDownloaded: json['isDownloaded'] as bool? ?? false,
      downloadError: json['downloadError'] as String?,
      matchScore: (json['matchScore'] as num?)?.toDouble(),
      matchReason: json['matchReason'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnlineSubtitle &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  @override
  int get hashCode => Object.hash(id, source);
}
