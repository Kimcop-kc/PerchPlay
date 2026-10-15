import 'package:path/path.dart' as p;

/// 从文件名识别剧集 / 电影
class MediaNamer {
  MediaNamer._();

  /// 常见需要剔除的发布组/画质标签
  static final _noise = RegExp(
    r'(2160p|1080p|720p|480p|4k|8k|uhd|hdr|dolby|dv|web-?dl|webrip|bluray|blu-ray|bdrip|'
    r'hdtv|remux|x264|x265|h\.?264|h\.?265|hevc|avc|10bit|8bit|aac|ac3|dts(-hd)?|truehd|'
    r'atmos|flac|mp3|hq|hd|sd|repack|proper|internal|multi|dual|chs|cht|gb|big5|'
    r'国语|中字|双语|字幕组|高清|蓝光|完整版|未删减)',
    caseSensitive: false,
  );

  /// 季集模式：S01E02 / s1e2 / 1x02 / EP02 / E02 / 第02集 / 第2季第3集 / [02]
  static final _seasonEpisode = RegExp(
    r'[Ss](\d{1,2})[\s._-]*[Ee][Pp]?(\d{1,3})',
  );
  static final _xFormat = RegExp(r'(?<!\d)(\d{1,2})[xX](\d{1,3})(?!\d)');
  static final _cnSeasonEpisode = RegExp(r'第\s*(\d{1,2})\s*季.*?第\s*(\d{1,3})\s*[集话話]');
  static final _cnEpisode = RegExp(r'第\s*(\d{1,3})\s*[集话話]');
  static final _epPrefix = RegExp(r'(?:^|[\s._\-\[\(])[Ee][Pp]?[\s._-]?(\d{1,3})(?!\d)');
  static final _bracketNum = RegExp(r'[\[\(]\s*(\d{1,3})\s*[\]\)]');
  static final _cnSeasonOnly = RegExp(r'第\s*(\d{1,2})\s*季');
  static final _year = RegExp(r'(?:19|20)\d{2}');

  /// 解析结果
  static MediaInfo parse(String filePath) {
    final fileName = p.basenameWithoutExtension(filePath);
    var work = fileName;

    int? season;
    int? episode;

    // 1) S01E02
    final se = _seasonEpisode.firstMatch(work);
    if (se != null) {
      season = int.tryParse(se.group(1)!);
      episode = int.tryParse(se.group(2)!);
    } else {
      // 2) 1x02
      final x = _xFormat.firstMatch(work);
      if (x != null) {
        season = int.tryParse(x.group(1)!);
        episode = int.tryParse(x.group(2)!);
      } else {
        // 3) 第1季第2集
        final cn = _cnSeasonEpisode.firstMatch(work);
        if (cn != null) {
          season = int.tryParse(cn.group(1)!);
          episode = int.tryParse(cn.group(2)!);
        } else {
          // 4) 第02集 / 第2话
          final ep = _cnEpisode.firstMatch(work) ??
              _epPrefix.firstMatch(work) ??
              _bracketNum.firstMatch(work);
          if (ep != null) episode = int.tryParse(ep.group(1)!);
          final s = _cnSeasonOnly.firstMatch(work);
          if (s != null) season = int.tryParse(s.group(1)!);
        }
      }
    }

    // 标题：去掉集数标记与噪声标签
    final title = _cleanTitle(
      work
          .replaceAll(_seasonEpisode, ' ')
          .replaceAll(_xFormat, ' ')
          .replaceAll(_cnSeasonEpisode, ' ')
          .replaceAll(_cnEpisode, ' ')
          .replaceAll(_epPrefix, ' ')
          .replaceAll(_bracketNum, ' ')
          .replaceAll(_cnSeasonOnly, ' '),
    );

    final isEpisode = episode != null;
    return MediaInfo(
      isEpisode: isEpisode,
      seriesTitle: title.isEmpty ? fileName : title,
      season: season,
      episode: episode,
      year: int.tryParse(_year.firstMatch(fileName)?.group(0) ?? ''),
    );
  }

  /// 清洗标题：去噪标签、括号内容、分隔符
  static String _cleanTitle(String raw) {
    var s = raw;
    // 去掉 [xxx] / (xxx) 包裹的内容（发布组、字幕组等）
    s = s.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
    s = s.replaceAll(_noise, ' ');
    s = s.replaceAll(RegExp(r'[._]+'), ' ');
    s = s.replaceAll(RegExp(r'\s*-\s*$'), ' ');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    // 去掉首尾的横杠/点
    s = s.replaceAll(RegExp(r'^[\s\-–—]+|[\s\-–—]+$'), '');
    if (s.isEmpty) s = raw.trim();
    return s;
  }

  /// 电影发行名（用于显示/搜索）
  static String movieTitle(String filePath) => parse(filePath).seriesTitle;
}

/// 识别结果
class MediaInfo {
  final bool isEpisode;
  final String seriesTitle;
  final int? season;
  final int? episode;
  final int? year;

  const MediaInfo({
    required this.isEpisode,
    required this.seriesTitle,
    this.season,
    this.episode,
    this.year,
  });

  /// 剧集排序键：先季再集
  int get orderKey => (season ?? 0) * 10000 + (episode ?? 0);

  String get displayName {
    if (!isEpisode) return seriesTitle;
    final s = season != null ? 'S${season.toString().padLeft(2, '0')}' : '';
    final e = 'E${(episode ?? 0).toString().padLeft(2, '0')}';
    return '$seriesTitle $s$e';
  }
}
