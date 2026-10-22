import '../../models/online_subtitle.dart';

/// 字幕搜索查询条件。
///
/// 所有字段可选：至少提供其中一个（文件名/名称），其余用于提高匹配精度。
class SubtitleQuery {
  /// 当前影片完整文件名（如 `Movie.2023.1080p.WEB-DL.mkv`）。
  final String? fileName;

  /// 清理后的影片名称（去掉年份/分辨率/发布组）。
  final String? title;

  /// 影片年份。
  final int? year;

  /// IMDb ID（如 `tt1234567`）。
  final String? imdbId;

  /// 电视剧季数。
  final int? season;

  /// 电视剧集数。
  final int? episode;

  /// 目标语言代码（ISO 639-1），null 表示不限。
  final String? languageCode;

  /// 字幕格式，null 表示不限。
  final String? format;

  /// 文件哈希（仅当服务支持且能正确计算时）。
  final String? fileHash;

  const SubtitleQuery({
    this.fileName,
    this.title,
    this.year,
    this.imdbId,
    this.season,
    this.episode,
    this.languageCode,
    this.format,
    this.fileHash,
  });
}

/// 字幕服务查询/下载的通用错误。
class SubtitleServiceException implements Exception {
  /// 错误类型。
  final SubtitleErrorType type;

  /// 错误描述。
  final String message;

  /// HTTP 状态码（网络错误时）。
  final int? statusCode;

  const SubtitleServiceException(
    this.type,
    this.message, {
    this.statusCode,
  });

  @override
  String toString() => 'SubtitleServiceException($type): $message';
}

/// 字幕服务错误分类。
enum SubtitleErrorType {
  /// 网络不可达 / 连接失败。
  network,

  /// 请求超时。
  timeout,

  /// 认证失败（无 API Key / Key 无效）。
  unauthorized,

  /// 配额超限（429 或服务返回的配额限制）。
  quotaExceeded,

  /// 服务不可用（5xx）。
  serviceUnavailable,

  /// 请求被取消。
  cancelled,

  /// 响应解析失败（无效 JSON / 结构不符）。
  parseError,

  /// 其他未知错误。
  unknown,
}

/// 字幕源适配器接口。
///
/// 每个在线字幕服务（OpenSubtitles、SubDL 等）实现此接口，
/// 聚合层通过接口统一调用、并发查询、合并去重。
abstract class SubtitleSource {
  /// 服务唯一标识（如 `opensubtitles`）。
  String get sourceId;

  /// 服务显示名（如 `OpenSubtitles`）。
  String get displayName;

  /// 服务当前是否可用（已配置凭证且未因认证失败被禁用）。
  bool get isAvailable;

  /// 查询字幕。返回匹配的搜索结果列表（可能为空）。
  ///
  /// 抛 [SubtitleServiceException] 表示查询失败。
  Future<List<OnlineSubtitle>> search(SubtitleQuery query);

  /// 获取某条结果的真实下载地址。
  ///
  /// 某些服务查询返回的是下载标识而非直链，需二次请求换取直链。
  /// 若 [result.downloadUrl] 已是直链，可直接返回它。
  Future<String> resolveDownloadUrl(OnlineSubtitle result);

  /// 释放资源（关闭 HTTP 客户端等）。
  void dispose();
}
