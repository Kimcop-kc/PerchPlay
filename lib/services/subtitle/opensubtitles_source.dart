import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/online_subtitle.dart';
import 'language_code.dart';
import 'subtitle_source.dart';

/// OpenSubtitles.com 官方 API 适配器。
///
/// 端点：https://api.opensubtitles.com/api/v1
/// 认证：`Api-Key` header（免费注册获取）。
///
/// 关键流程：
/// 1. 搜索：`GET /subtitles?query=&imdb_id=&languages=&...`
///    返回 `data[].attributes`，含 file_id（下载用）
/// 2. 下载：`POST /download` body `{"file_id": ...}` → 返回临时直链 `link`
///    再 GET `link` 拿到字幕文件内容
///
/// 语言用 ISO 639-1（`en`、`zh`），服务端接受。
/// 配额：免费 20 下载/天，通过响应头 `X-RateLimit-*` 提示。
class OpenSubtitlesSource implements SubtitleSource {
  final String apiKey;

  /// 可注入的 HTTP client（测试用 MockClient）。
  final http.Client _client;

  /// 请求超时。
  final Duration _timeout;

  /// 服务是否已配置可用（有 API Key）。
  bool _available = true;

  OpenSubtitlesSource({
    required this.apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _timeout = timeout;

  static const String _base = 'https://api.opensubtitles.com/api/v1';

  @override
  String get sourceId => 'opensubtitles';

  @override
  String get displayName => 'OpenSubtitles';

  @override
  bool get isAvailable => _available && apiKey.isNotEmpty;

  @override
  Future<List<OnlineSubtitle>> search(SubtitleQuery query) async {
    if (apiKey.isEmpty) {
      _available = false;
      throw const SubtitleServiceException(
        SubtitleErrorType.unauthorized,
        '未配置 OpenSubtitles API Key',
      );
    }

    final params = <String, String>{
      // 查询词：优先 IMDb ID，其次文件名/标题
      if (query.imdbId != null && query.imdbId!.isNotEmpty)
        'imdb_id': query.imdbId!
      else if (query.fileName != null && query.fileName!.isNotEmpty)
        'query': query.fileName!
      else if (query.title != null && query.title!.isNotEmpty)
        'query': query.title!,
      // 语言：OpenSubtitles 用 ISO 639-1
      if (query.languageCode != null && query.languageCode!.isNotEmpty)
        'languages': query.languageCode!,
      // 类型：电影/剧集
      if (query.season != null && query.episode != null) 'type': 'episode',
      if (query.year != null) 'year': query.year.toString(),
    };

    // 至少要有查询词
    if (!params.containsKey('imdb_id') && !params.containsKey('query')) {
      return const [];
    }

    final uri = Uri.parse('$_base/subtitles').replace(queryParameters: params);

    final resp = await _client.get(uri, headers: _headers()).timeout(_timeout);

    _checkRateLimit(resp);

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      _available = false;
      throw SubtitleServiceException(
        SubtitleErrorType.unauthorized,
        'OpenSubtitles API Key 无效',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode == 429) {
      throw SubtitleServiceException(
        SubtitleErrorType.quotaExceeded,
        'OpenSubtitles 配额超限',
        statusCode: 429,
      );
    }
    if (resp.statusCode >= 500) {
      throw SubtitleServiceException(
        SubtitleErrorType.serviceUnavailable,
        'OpenSubtitles 服务不可用',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw SubtitleServiceException(
        SubtitleErrorType.unknown,
        'OpenSubtitles 返回 ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }

    try {
      final body =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = (body['data'] as List<dynamic>?) ?? const [];
      return data
          .map((e) => _parseItem(e as Map<String, dynamic>))
          .where((s) => s != null)
          .cast<OnlineSubtitle>()
          .toList();
    } catch (_) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        'OpenSubtitles 响应解析失败',
      );
    }
  }

  @override
  Future<String> resolveDownloadUrl(OnlineSubtitle result) async {
    // OpenSubtitles 的 downloadUrl 存的是 file_id（搜索阶段拿不到直链），
    // 需 POST /download 换直链。
    final resp = await _client
        .post(
          Uri.parse('$_base/download'),
          headers: _headers(),
          body: jsonEncode({'file_id': int.tryParse(result.downloadUrl) ?? 0}),
        )
        .timeout(_timeout);

    _checkRateLimit(resp);

    if (resp.statusCode != 200) {
      throw SubtitleServiceException(
        SubtitleErrorType.unknown,
        '获取下载链接失败 (${resp.statusCode})',
        statusCode: resp.statusCode,
      );
    }

    final body =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final link = body['link'] as String?;
    if (link == null || link.isEmpty) {
      throw const SubtitleServiceException(
        SubtitleErrorType.parseError,
        '下载链接缺失',
      );
    }
    return link;
  }

  /// 解析单条搜索结果。
  OnlineSubtitle? _parseItem(Map<String, dynamic> item) {
    final id = item['id']?.toString();
    final attrs = item['attributes'] as Map<String, dynamic>?;
    if (id == null || attrs == null) return null;

    // 文件列表里第一个是主文件，含 file_id 和文件名
    final files = (attrs['files'] as List<dynamic>?) ?? const [];
    if (files.isEmpty) return null;
    final firstFile = files.first as Map<String, dynamic>;
    final fileId = firstFile['file_id']?.toString();
    final fileName = firstFile['file_name'] as String? ?? '';

    if (fileId == null) return null;

    // 语言：OpenSubtitles 用 ISO 639-1（如 en、zh）
    final lang = attrs['language'] as String? ?? '';
    final langCode = LanguageCode.normalize(lang);

    // 格式：从文件名扩展名推断
    final format = _formatFromName(fileName);

    // 影片信息
    final featureDetails = attrs['feature_details'] as Map<String, dynamic>?;
    final movieName = featureDetails?['title'] as String?;
    final year = featureDetails?['year'] as int?;
    final season = featureDetails?['season_number'] as int?;
    final episode = featureDetails?['episode_number'] as int?;

    // 发布组：从文件名提取（通常含 release group）
    final releaseGroup = _extractReleaseGroup(fileName);

    // 听障/强制字幕标记
    final hearingImpaired = attrs['hearing_impaired'] == true;
    final forced = attrs['forced'] == true;

    // 下载量（匹配评分可参考）
    final downloadCount = attrs['download_count'] as int?;

    return OnlineSubtitle(
      id: id,
      name: fileName.isEmpty ? '字幕 $id' : fileName,
      source: sourceId,
      languageCode: langCode,
      languageName: LanguageCode.displayName(langCode),
      format: format,
      // 注意：这里 downloadUrl 存的是 file_id（下载时再换直链）
      downloadUrl: fileId,
      movieName: movieName,
      year: year,
      season: season,
      episode: episode,
      releaseGroup: releaseGroup,
      isHearingImpaired: hearingImpaired,
      isForced: forced,
      // download_count 仅作参考，不直接当匹配分
      matchScore:
          downloadCount != null ? (downloadCount > 1000 ? 0.7 : 0.4) : null,
      matchReason: downloadCount != null ? '下载量 $downloadCount' : null,
    );
  }

  Map<String, String> _headers() => {
        'Api-Key': apiKey,
        'User-Agent': 'PerchPlay v1.0',
        'Accept': 'application/json',
      };

  void _checkRateLimit(http.Response resp) {
    // 记录配额余量（响应头），供 UI 提示；不抛异常
    final remaining = resp.headers['x-ratelimit-remaining'];
    if (remaining != null) {
      // 留空：配额信息后续阶段在 UI 展示
    }
  }

  /// 从文件名扩展名提取格式（统一小写）。
  static String _formatFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.srt')) return 'srt';
    if (lower.endsWith('.ass')) return 'ass';
    if (lower.endsWith('.ssa')) return 'ssa';
    if (lower.endsWith('.vtt')) return 'vtt';
    return 'srt'; // 默认
  }

  /// 从文件名提取发布组（如 `Movie.2023.1080p.WEB-DL` → `WEB-DL`）。
  static String? _extractReleaseGroup(String name) {
    final known = [
      'web-dl',
      'webrip',
      'bluray',
      'blu-ray',
      'hdtv',
      'hdr',
      'remux'
    ];
    final lower = name.toLowerCase();
    for (final k in known) {
      if (lower.contains(k)) return k.toUpperCase();
    }
    return null;
  }

  @override
  void dispose() {
    _client.close();
  }
}
