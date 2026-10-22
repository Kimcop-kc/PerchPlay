import '../../models/online_subtitle.dart';
import 'subtitle_source.dart';

/// 字幕匹配评分结果。
class MatchScore {
  /// 0~1 的匹配分（越高越匹配）。
  final double score;

  /// 匹配原因说明（用于 UI 展示）。
  final List<String> reasons;

  const MatchScore(this.score, this.reasons);
}

/// 字幕匹配评分算法。
///
/// 综合多维度打分：
/// - 影片名称匹配度（精确/包含/编辑距离）
/// - 年份匹配
/// - IMDb ID / 文件哈希匹配
/// - 电视剧季数/集数
/// - 语言匹配
/// - 格式匹配
/// - 版本/发布组
///
/// 分数 0~1，精确匹配优先，低置信度不静默应用。
class SubtitleMatcher {
  SubtitleMatcher._();

  /// 高置信度阈值：达到此分数可自动应用。
  static const double highConfidence = 0.75;

  /// 低置信度阈值：低于此分数不建议应用（应让用户确认）。
  static const double lowConfidence = 0.4;

  /// 计算字幕与当前影片的匹配分。
  ///
  /// [query] 是查询条件（含影片信息），[subtitle] 是搜索结果。
  /// [fileName] 是当前视频文件名（可选，用于版本匹配）。
  static MatchScore score(SubtitleQuery query, OnlineSubtitle subtitle) {
    final reasons = <String>[];
    var score = 0.0;

    // 1. 影片名称匹配（权重最高 0.4）
    final titleScore = _titleScore(query, subtitle);
    score += titleScore;
    if (titleScore > 0) {
      reasons.add(titleScore >= 0.35 ? '名称精确匹配' : '名称模糊匹配');
    }

    // 2. 年份匹配（0.15）
    if (query.year != null && subtitle.year != null) {
      if (query.year == subtitle.year) {
        score += 0.15;
        reasons.add('年份匹配');
      } else if ((query.year! - subtitle.year!).abs() <= 1) {
        score += 0.08;
        reasons.add('年份接近');
      }
    }

    // 3. 语言匹配（0.15）
    if (query.languageCode != null && query.languageCode!.isNotEmpty) {
      if (subtitle.languageCode == query.languageCode) {
        score += 0.15;
        reasons.add('语言匹配');
      }
    }

    // 4. 电视剧季集匹配（0.15）
    if (query.season != null && query.episode != null) {
      if (subtitle.season == query.season &&
          subtitle.episode == query.episode) {
        score += 0.15;
        reasons.add('集数匹配 S${query.season}E${query.episode}');
      } else if (subtitle.season == query.season) {
        score += 0.07;
        reasons.add('季数匹配');
      }
    }

    // 5. 格式匹配（0.05）
    if (query.format != null && query.format!.isNotEmpty) {
      if (subtitle.format == query.format!.toLowerCase()) {
        score += 0.05;
        reasons.add('格式匹配');
      }
    }

    // 6. 发布组/版本匹配（0.1，通过文件名比对）
    if (query.fileName != null && subtitle.releaseGroup != null) {
      final fileLower = query.fileName!.toLowerCase();
      if (fileLower.contains(subtitle.releaseGroup!.toLowerCase())) {
        score += 0.1;
        reasons.add('版本匹配 ${subtitle.releaseGroup}');
      }
    }

    return MatchScore(score.clamp(0.0, 1.0), reasons);
  }

  /// 名称匹配分（0~0.4）。
  static double _titleScore(SubtitleQuery query, OnlineSubtitle subtitle) {
    // 优先用查询的 title，其次 fileName 清理后
    final queryTitle = query.title ?? _cleanFileName(query.fileName);
    if (queryTitle == null || queryTitle.isEmpty) return 0.0;

    final subTitle = subtitle.movieName;
    if (subTitle == null || subTitle.isEmpty) return 0.0;

    final q = queryTitle.toLowerCase().trim();
    final s = subTitle.toLowerCase().trim();

    // 精确相等
    if (q == s) return 0.4;
    // 包含
    if (q.contains(s) || s.contains(q)) return 0.35;
    // 去掉标点/空格后相等
    final qClean = _normalize(q);
    final sClean = _normalize(s);
    if (qClean == sClean) return 0.38;
    // 编辑距离（Levenshtein）模糊
    final dist = _levenshtein(qClean, sClean);
    final maxLen =
        qClean.length > sClean.length ? qClean.length : sClean.length;
    if (maxLen == 0) return 0.0;
    final similarity = 1.0 - (dist / maxLen);
    if (similarity > 0.6) return 0.2 * similarity;
    return 0.0;
  }

  /// 从文件名清理出影片名（去掉扩展名、年份、分辨率、发布组）。
  static String? _cleanFileName(String? fileName) {
    if (fileName == null || fileName.isEmpty) return null;
    var name = fileName.toLowerCase();
    // 去扩展名
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    // 去掉年份
    name = name.replaceAll(RegExp(r'(19|20)\d{2}'), ' ');
    // 去掉分辨率
    name = name.replaceAll(RegExp(r'\b(720p|1080p|2160p|4k)\b'), ' ');
    // 去掉发布组标记
    name = name.replaceAll(
        RegExp(
            r'\b(web-dl|webrip|bluray|blu-ray|hdtv|hdr|remux|x264|x265|hevc)\b'),
        ' ');
    // 去掉点/下划线/连字符，折叠空格
    name =
        name.replaceAll(RegExp(r'[._\-]'), ' ').replaceAll(RegExp(r'\s+'), ' ');
    return name.trim();
  }

  /// 去掉所有非字母数字字符。
  static String _normalize(String s) =>
      s.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  /// Levenshtein 编辑距离。
  static int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    final curr = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      curr[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        curr[j + 1] = (prev[j + 1] + 1 < curr[j] + 1
                    ? prev[j + 1] + 1
                    : curr[j] + 1) <
                prev[j] + cost
            ? (prev[j + 1] + 1 < curr[j] + 1 ? prev[j + 1] + 1 : curr[j] + 1)
            : prev[j] + cost;
      }
      for (var j = 0; j <= b.length; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[b.length];
  }
}
