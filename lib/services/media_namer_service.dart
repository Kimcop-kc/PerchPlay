import 'package:path/path.dart' as p;

/// 从文件名 / 所在文件夹识别「剧集」与「电影」
///
/// 识别分三档，越往后越弱：
///  1. **明确标记**：S01E02 / 1x02 / 第2集 / EP02 / [02] —— 可信
///  2. **末尾序号**：`Show - 02`、`Show.02.1080p`、`02.mkv` —— 需要配合
///     文件夹或同类聚集才能确认（见 [MediaGrouping]），单文件时按电影处理
///  3. 无 —— 电影
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

  /// 季集：S01E02 / s1e2 / S01.E02 / S01 E02 / S01-E02
  static final _seasonEpisode = RegExp(
    r'[Ss](\d{1,2})[\s._-]*[Ee][Pp]?[\s._-]?(\d{1,3})',
  );
  /// 1x02
  static final _xFormat = RegExp(r'(?<!\d)(\d{1,2})[xX](\d{1,3})(?!\d)');
  /// 第1季第2集 / 第1季 第2话
  static final _cnSeasonEpisode =
      RegExp(r'第\s*(\d{1,2})\s*季.*?第\s*(\d{1,3})\s*[集话話期]');
  /// 第02集 / 第2话 / 第3期
  static final _cnEpisode = RegExp(r'第\s*(\d{1,3})\s*[集话話期]');
  /// EP02 / E02 / Ep.02（要求前后是分隔符或边界）
  static final _epPrefix =
      RegExp(r'(?:^|[\s._\-\[\(])[Ee][Pp]?[\s._-]?(\d{1,3})(?!\d)');
  /// [02] / (02) / [02v2]
  static final _bracketNum = RegExp(r'[\[\(]\s*(\d{1,3})(?:v\d+)?\s*[\]\)]');
  /// 第1季（只有季）
  static final _cnSeasonOnly = RegExp(r'第\s*(\d{1,2})\s*季');
  /// 单独的 S01 段（`Show.S01.01` 这种季集分开写的写法）
  static final _seasonToken = RegExp(r'(?:^|[\s._\-])[Ss](\d{1,2})(?![\dEePp])');
  /// 年份
  static final _year = RegExp(r'(?:19|20)\d{2}');

  /// 文件名解析结果
  ///
  /// 用于「末尾序号」这类弱识别：清洗后最后一个 token 是 1~3 位数字
  /// （可带 v2 之类的版本后缀），例如：
  ///   `Show - 02 [1080p]` → 2
  ///   `Show.02.1080p.WEB-DL` → 2
  ///   `02.mkv` → 2
  /// 4 位数字（年份）不算，`Se7en` 这种嵌在单词里的也不算。
  static MediaInfo parse(String filePath) {
    final fileName = p.basenameWithoutExtension(filePath);
    var work = fileName;

    int? season;
    int? episode;
    var weak = false;

    // ── 1) 明确标记 ──
    final se = _seasonEpisode.firstMatch(work);
    if (se != null) {
      season = int.tryParse(se.group(1)!);
      episode = int.tryParse(se.group(2)!);
    } else {
      final x = _xFormat.firstMatch(work);
      if (x != null) {
        season = int.tryParse(x.group(1)!);
        episode = int.tryParse(x.group(2)!);
      } else {
        final cn = _cnSeasonEpisode.firstMatch(work);
        if (cn != null) {
          season = int.tryParse(cn.group(1)!);
          episode = int.tryParse(cn.group(2)!);
        } else {
          final ep = _cnEpisode.firstMatch(work) ??
              _epPrefix.firstMatch(work) ??
              _bracketNum.firstMatch(work);
          if (ep != null) episode = int.tryParse(ep.group(1)!);
          final s = _cnSeasonOnly.firstMatch(work) ??
              _seasonToken.firstMatch(work);
          if (s != null) season = int.tryParse(s.group(1)!);
        }
      }
    }

    // 标题：去掉标记与噪声标签
    var title = _cleanTitle(
      work
          .replaceAll(_seasonEpisode, ' ')
          .replaceAll(_xFormat, ' ')
          .replaceAll(_cnSeasonEpisode, ' ')
          .replaceAll(_cnEpisode, ' ')
          .replaceAll(_epPrefix, ' ')
          .replaceAll(_bracketNum, ' ')
          .replaceAll(_cnSeasonOnly, ' ')
          .replaceAll(_seasonToken, ' '),
    );

    // ── 2) 末尾序号（弱识别）──
    if (episode == null) {
      final weakHit = _weakEpisode(work);
      if (weakHit != null) {
        episode = weakHit.$1;
        weak = true;
        final cleaned = _cleanTitle(weakHit.$2);
        if (cleaned.isNotEmpty) title = cleaned;
      }
    }

    return MediaInfo(
      isEpisode: episode != null,
      seriesTitle: title.isEmpty ? fileName : title,
      season: season,
      episode: episode,
      year: int.tryParse(_year.firstMatch(fileName)?.group(0) ?? ''),
      weakEpisode: weak,
    );
  }

  /// 清洗标题：去噪标签、年份、发布组、括号内容、分隔符
  static String _cleanTitle(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
    s = s.replaceAll(_noise, ' ');
    // 单独的季标记段（`Show.S01.01` → 去掉 S01），否则会残留在列表名里
    s = s.replaceAll(_seasonToken, ' ');
    // 年份：只去掉作为独立词出现的 4 位年份（1990-2099）
    s = s.replaceAll(
        RegExp(r'(?:^|[\s._\-\[\(])(?:19|20)\d{2}(?=$|[\s._\-\]\)])'), ' ');
    // 结尾发布组：场景惯例是 -全大写
    s = s.replaceAll(RegExp(r'[-_][A-Z0-9]{2,12}$'), ' ');
    s = s.replaceAll(RegExp(r'[._]+'), ' ');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    s = s.replaceAll(RegExp(r'^[\s\-–—]+|[\s\-–—]+$'), '').trim();
    if (s.isEmpty) {
      s = raw.replaceAll(RegExp(r'[._]+'), ' ').trim();
    }
    return s;
  }

  /// 弱识别：清洗后的**最后一个有意义 token** 是 1~3 位数字时，
  /// 认为它是集数，返回 (集数, 它前面的标题部分)；否则 null。
  ///
  /// 只认最后一个 token，是为了避开
  /// `Liuliang.Earth.2.2023.2160p.HDR` 这种片名里夹着数字、
  /// 后面还跟着年份/画质标签的情况（那里最后一个有意义 token 是 2023，
  /// 4 位 → 不是集数，判定为电影）。
  static (int, String)? _weakEpisode(String raw) {
    // 括号里的内容（[1080p]、(v2)…）先清掉，它们不参与判断
    final noBrackets =
        raw.replaceAll(RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]'), ' ');
    final tokens = noBrackets
        .split(RegExp(r'[\s._\-–—]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;

    // 从后往前跳过纯噪声 token（1080p / WEB-DL / x265…）
    var i = tokens.length - 1;
    while (i >= 0 &&
        tokens[i].replaceAll(_noise, '').trim().isEmpty) {
      i--;
    }
    if (i < 0) return null;

    final m = RegExp(r'^(\d{1,3})(?:v\d+)?$').firstMatch(tokens[i]);
    if (m == null) return null;
    final ep = int.tryParse(m.group(1)!);
    if (ep == null || ep <= 0) return null;

    return (ep, tokens.sublist(0, i).join(' '));
  }
}

/// 识别结果
class MediaInfo {
  final bool isEpisode;
  final String seriesTitle;
  final int? season;
  final int? episode;
  final int? year;

  /// 集数是否来自「末尾序号」这类弱识别（未确认前不应单独成列表）
  final bool weakEpisode;

  const MediaInfo({
    required this.isEpisode,
    required this.seriesTitle,
    this.season,
    this.episode,
    this.year,
    this.weakEpisode = false,
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
