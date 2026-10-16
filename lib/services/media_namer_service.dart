import 'package:path/path.dart' as p;

/// 从**文件名前缀**识别剧名与集数
///
/// 思路（通用规则，不依赖某一种命名习惯）：
///  1. 找到文件名里第一个「编号或季集标记」出现的位置；
///  2. 这个位置**之前**的部分就是剧名（= 用户说的"文件名前几个字符"）；
///  3. 标记本身给出季/集；标记之前什么都没有（如 `01.mp4`）→ 没有剧名，不参与分组。
///
/// 标记分强弱两档：
///  - **强**：`S01E02`、`1x02`、`第1季第3集`、`第02集`、`第一集`、`EP05`、`[02]`、`Show.S01.01`
///  - **弱**：文件名里第一个 1~3 位数字（`Show - 01`、`Show.02`、`巨人01`、`Show01`）
///    弱识别需要「同类聚集」佐证（见 [MediaGrouping]），单文件不单独成列表。
///
/// 4 位数字（年份 1999/2023）与括号里的内容（[1080p]）不参与判断。
class MediaNamer {
  MediaNamer._();

  /// 需要剔除的发布组/画质标签
  ///
  /// 中文标签**长词必须写在前面**：正则按顺序取第一个能匹配的分支，
  /// 若 `未删减` 排在 `未删减版` 前面，就会只剩一个孤零零的「版」。
  static final _noise = RegExp(
    // 英文/数字标签
    r'(2160p|1080p|720p|480p|4k|8k|uhd|hdr|dolby|dv|web-?dl|webrip|bluray|blu-ray|bdrip|'
    r'hdtv|remux|x264|x265|h\.?264|h\.?265|hevc|avc|10bit|8bit|aac|ac3|dts(-hd)?|truehd|'
    r'atmos|flac|mp3|hq|hd|sd|repack|proper|internal|multi|dual|chs|cht|gb|big5|v2|'
    // 中文：字幕 / 音轨 / 来源
    r'官方中字|简繁中字|中文字幕|内嵌字幕|内封字幕|外挂字幕|硬字幕|软字幕|'
    r'内嵌|内封|外挂|官方|官中|简中|繁中|简繁|简英|繁英|中英|中字|'
    r'国粤|台配|国配|中配|国语|粤语|双语|字幕组|'
    // 中文：画质 / 版本
    r'蓝光原盘|导演剪辑版|未删减版|无删减版|完整版|加长版|修复版|重制版|重置版|抢先版|枪版|'
    r'未删减|无删减|高清|超清|蓝光|原盘|'
    r'手动选择|默认)',
    caseSensitive: false,
  );

  /// 括号内容（发布组 / 画质标签）
  static final _bracket = RegExp(r'[\[\(\{][^\]\)\}]*[\]\)\}]');

  /// 中文数字
  static const _cnDigits = {
    '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
    '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
  };
  static const _numChar = r'0-9一二三四五六七八九十百';

  /// 季集：S01E02 / s1e2 / S01.E02 / S01 E02 / S01-E02
  static final _seasonEpisode =
      RegExp(r'[Ss](\d{1,2})[\s._-]*[Ee][Pp]?[\s._-]?(\d{1,3})');
  /// 1x02
  static final _xFormat = RegExp(r'(?<!\d)(\d{1,2})[xX](\d{1,3})(?!\d)');
  /// 第1季第2集
  static final _cnSeasonEpisode =
      RegExp('第\\s*([$_numChar]{1,4})\\s*季.*?第\\s*([$_numChar]{1,4})\\s*[集话話期]');
  /// 第02集 / 第2话 / 第三期 / 第一集
  static final _cnEpisode = RegExp('第\\s*([$_numChar]{1,4})\\s*[集话話期]');
  /// EP02 / E02 / Ep.02
  static final _epPrefix =
      RegExp(r'(?:^|[\s._\-\[\(])[Ee][Pp]?[\s._-]?(\d{1,3})(?!\d)');
  /// [02] / (02) / [02v2]
  static final _bracketNum = RegExp(r'[\[\(]\s*(\d{1,3})(?:v\d+)?\s*[\]\)]');
  /// 第1季（只有季）
  static final _cnSeasonOnly = RegExp('第\\s*([$_numChar]{1,3})\\s*季');
  /// 单独的 S01 段（`Show.S01.01`）
  static final _seasonToken = RegExp(r'(?:^|[\s._\-])[Ss](\d{1,2})(?![\dEePp])');
  /// 年份
  static final _year = RegExp(r'(?:19|20)\d{2}');

  /// 解析文件名
  static MediaInfo parse(String filePath) {
    final fileName = p.basenameWithoutExtension(filePath);

    int? season;
    int? episode;
    var weak = false;
    int? splitAt; // 前缀截断位置：剧名 = fileName[0..splitAt]

    // ── 1) 强标记 ──
    final se = _seasonEpisode.firstMatch(fileName);
    final x = se == null ? _xFormat.firstMatch(fileName) : null;
    final cn =
        (se == null && x == null) ? _cnSeasonEpisode.firstMatch(fileName) : null;
    final cnEp = (se == null && x == null && cn == null)
        ? _cnEpisode.firstMatch(fileName)
        : null;
    final epPre = (se == null && x == null && cn == null && cnEp == null)
        ? _epPrefix.firstMatch(fileName)
        : null;
    final br = (se == null && x == null && cn == null && cnEp == null && epPre == null)
        ? _bracketNum.firstMatch(fileName)
        : null;

    if (se != null) {
      season = _num(se.group(1));
      episode = _num(se.group(2));
      splitAt = se.start;
    } else if (x != null) {
      season = _num(x.group(1));
      episode = _num(x.group(2));
      splitAt = x.start;
    } else if (cn != null) {
      season = _num(cn.group(1));
      episode = _num(cn.group(2));
      splitAt = cn.start;
    } else {
      final m = cnEp ?? epPre ?? br;
      if (m != null) {
        episode = _num(m.group(1));
        // 季可能单独出现，且可能写在集之前（`Show 第1季 第02集`）
        final s = _cnSeasonOnly.firstMatch(fileName) ??
            _seasonToken.firstMatch(fileName);
        if (s != null) season = _num(s.group(1));
        splitAt = (s != null && s.start < m.start) ? s.start : m.start;
      }
    }

    // ── 2) 只有季标记（`Show.S01.01`、`Show 第1季 01`）──
    // 季标记后面的编号就是集数；此时算明确识别，不要求聚集
    if (episode == null) {
      final s = _cnSeasonOnly.firstMatch(fileName) ??
          _seasonToken.firstMatch(fileName);
      if (s != null) {
        season = _num(s.group(1));
        splitAt = s.start;
        final cut = _firstNumber(fileName.substring(s.end));
        if (cut != null) episode = cut.$2;
      }
    }

    // ── 3) 弱标记：文件名里第一个 1~3 位数字 ──
    if (episode == null) {
      final cut = _firstNumber(fileName);
      if (cut != null) {
        episode = cut.$2;
        weak = true;
        splitAt = cut.$1;
      }
    }

    // ── 4) 前缀即剧名 ──
    String raw;
    if (splitAt == null) {
      raw = fileName;
    } else if (splitAt > 0) {
      raw = fileName.substring(0, splitAt);
    } else {
      // splitAt == 0：季集标记在最开头（01 概論 / EP01 - Show / 第02集 XXX）
      raw = _stripLeadingEpisode(fileName);
    }
    var title = _cleanTitle(raw);
    if (title.isEmpty) title = _cleanTitle(fileName);

    return MediaInfo(
      isEpisode: episode != null,
      seriesTitle: title.isEmpty ? fileName : title,
      // 完整清洗片名（不截断集数）：`流浪地球2` 这类片名自带数字的，
      // 按电影兜底搜索时要用它，否则会把第 2 部搜成第 1 部
      fullTitle: _cleanTitle(fileName),
      season: season,
      episode: episode,
      year: int.tryParse(_year.firstMatch(fileName)?.group(0) ?? ''),
      weakEpisode: weak,
    );
  }

  /// splitAt==0 时：剥掉最开头的季集标记，余下的文字就是剧名。
  /// 例：`01 概論` → `概論`、`EP05 - Show Name` → `Show Name`、`第02集 某某` → `某某`
  static String _stripLeadingEpisode(String fileName) {
    // 按优先级逐个试 matchAsPrefix（仅匹配字符串开头）
    final se = _seasonEpisode.matchAsPrefix(fileName);
    if (se != null) return _trimAfter(fileName, se.end);

    final x = _xFormat.matchAsPrefix(fileName);
    if (x != null) return _trimAfter(fileName, x.end);

    final cn = _cnSeasonEpisode.matchAsPrefix(fileName);
    if (cn != null) return _trimAfter(fileName, cn.end);

    final cnEp = _cnEpisode.matchAsPrefix(fileName);
    if (cnEp != null) return _trimAfter(fileName, cnEp.end);

    final ep = _epPrefix.matchAsPrefix(fileName);
    if (ep != null) return _trimAfter(fileName, ep.end);

    final br = _bracketNum.matchAsPrefix(fileName);
    if (br != null) return _trimAfter(fileName, br.end);

    // 弱标记：第一个 1~3 位数字
    final num = _firstNumber(fileName);
    if (num != null && num.$1 == 0) {
      return _trimAfter(fileName, _leadingDigitsLen(fileName));
    }

    return fileName;
  }

  static String _trimAfter(String s, int pos) =>
      s.substring(pos).replaceAll(RegExp(r'^[\s._\-\–—–\[\]\(\)]+'), '');

  static int _leadingDigitsLen(String s) {
    final m = RegExp(r'^\d+').firstMatch(s);
    return m == null ? 0 : m.group(0)!.length;
  }

  /// 找第一个 1~3 位数字，返回 (下标, 数值)；跳过括号内容、噪标签与 4 位以上数字。
  ///
  /// 噪标签必须先掩掉，否则 `x264`、`1080p` 里的数字会被当成集数。
  static (int, int)? _firstNumber(String raw) {
    // 括号内容与噪标签替换成**等长空格**，保证下标仍能对上原串
    var masked =
        raw.replaceAllMapped(_bracket, (m) => ' ' * m.group(0)!.length);
    masked =
        masked.replaceAllMapped(_noise, (m) => ' ' * m.group(0)!.length);
    for (final m in RegExp(r'\d+').allMatches(masked)) {
      final text = m.group(0)!;
      if (text.length > 3) continue; // 年份/分辨率之类
      final v = int.tryParse(text);
      if (v == null || v <= 0) continue;
      // 注意：`流浪地球2`、`Se7en` 这种数字夹在标题里也会命中，
      // 但这是**弱**识别 —— MediaGrouping 要求同类聚集才成列表，
      // 所以单个文件不会因此被当成剧集。
      return (m.start, v);
    }
    return null;
  }

  /// 中文/阿拉伯数字统一转 int
  static int? _num(String? s) {
    if (s == null) return null;
    if (RegExp(r'^\d+$').hasMatch(s)) return int.tryParse(s);
    if (s == '十') return 10;
    final m = RegExp(r'^([一二三四五六七八九])?十([一二三四五六七八九])?$').firstMatch(s);
    if (m != null) {
      final tens = m.group(1);
      final ones = m.group(2);
      return (tens == null ? 1 : _cnDigits[tens]!) * 10 +
          (ones == null ? 0 : _cnDigits[ones]!);
    }
    if (s.length == 1) return _cnDigits[s];
    // 二十以后的多字（如 二三 这种畸形写法）取能识别的部分
    var value = 0;
    for (final ch in s.split('')) {
      final d = _cnDigits[ch];
      if (d == null) continue;
      value = value * 10 + d;
    }
    return value == 0 ? null : value;
  }

  /// 清洗剧名：去括号、噪标签、年份、发布组、分隔符
  static String _cleanTitle(String raw) {
    var s = raw;
    s = s.replaceAll(_bracket, ' ');
    s = s.replaceAll(_noise, ' ');
    s = s.replaceAll(_seasonToken, ' ');
    s = s.replaceAll(_cnSeasonOnly, ' ');
    // 独立出现的 4 位年份
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
}

/// 识别结果
class MediaInfo {
  final bool isEpisode;
  final String seriesTitle;

  /// 完整清洗片名，**不截断集数**
  ///
  /// 用于「弱识别」兜底：`流浪地球2` 会被当成第 2 集、seriesTitle 变成「流浪地球」，
  /// 万一剧集路径查不到而改按电影搜，必须用带数字的 `流浪地球2`，
  /// 否则会搜到第 1 部、贴错海报。
  final String fullTitle;

  final int? season;
  final int? episode;
  final int? year;

  /// 集数是否来自「第一个数字」这类弱识别（未聚集佐证前不应单独成列表）
  final bool weakEpisode;

  const MediaInfo({
    required this.isEpisode,
    required this.seriesTitle,
    this.fullTitle = '',
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
