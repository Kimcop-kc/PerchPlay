import 'dart:math' as math;

import '../models/scrape_result.dart';

/// 从 TMDB 的候选结果里挑出最匹配的一个
///
/// 背景：原来直接取 `results.first`，而 TMDB 的相关性排序对**中文片名**很不友好——
/// 搜 `Heartstopper Forever` 可能第一条是别的片子，于是贴错海报且无从察觉。
///
/// 打分维度：
///  1. 片名相似度（同时比 `title` 与 `originalTitle`，取高的那个）
///     —— zh-CN 语言下 title 是中文名、originalTitle 才是原名，
///     拿英文文件名去比 title 会全军覆没
///  2. 年份：解析出的年份和候选年份一致加分；差 >=3 年重罚
///     （同名翻拍/续集最容易在这里挑错）
///  3. 投票数：同名片子多版本时，优先更知名的那个
///
/// 纯函数，方便单测。
class ScrapeMatcher {
  ScrapeMatcher._();

  /// 低于这个分数认为"没有一条像"，宁可不出海报也不贴错的
  static const double minScore = 30;

  /// 从候选里挑最佳；都不像则返回 null
  static ScrapeResult? best(
    List<ScrapeResult> candidates, {
    required String query,
    int? year,
    double floor = minScore,
  }) {
    if (candidates.isEmpty) return null;
    ScrapeResult? bestOne;
    var bestScore = double.negativeInfinity;
    for (final c in candidates) {
      final s = score(c, query: query, year: year);
      if (s > bestScore) {
        bestScore = s;
        bestOne = c;
      }
    }
    return bestScore >= floor ? bestOne : null;
  }

  /// 单个候选的得分
  static double score(
    ScrapeResult c, {
    required String query,
    int? year,
  }) {
    final sim = math.max(
      similarity(c.title, query),
      similarity(c.originalTitle ?? '', query),
    );
    var s = sim * 100;

    if (year != null && c.year != null) {
      final d = (c.year! - year).abs();
      if (d == 0) {
        s += 30;
      } else if (d == 1) {
        s += 12;
      } else if (d >= 3) {
        s -= 25;
      } else {
        s -= 10;
      }
    }

    // 热度：最多加 10 分，只用于同分时拉开差距，不影响"像不像"的判断
    final votes = c.voteCount ?? 0;
    if (votes > 0) {
      s += math.min(10, math.log(votes + 1) / math.ln10 * 3);
    }
    return s;
  }

  /// 归一化：小写、去掉标点与分隔符，只留字母/数字/汉字
  static String normalize(String s) {
    final lower = s.toLowerCase();
    final buf = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      final keep = RegExp(r'[a-z0-9]').hasMatch(ch) ||
          // CJK 统一表意文字：中文没有词边界，按字符保留
          (rune >= 0x4E00 && rune <= 0x9FFF);
      if (keep) {
        buf.write(ch);
      } else if (buf.isNotEmpty && !buf.toString().endsWith(' ')) {
        buf.write(' ');
      }
    }
    return buf.toString().trim();
  }

  /// 相似度 0~1
  static double similarity(String a, String b) {
    final na = normalize(a).replaceAll(' ', '');
    final nb = normalize(b).replaceAll(' ', '');
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;

    // 包含关系：`流浪地球` vs `流浪地球2`、`Show` vs `Show 第二季`
    if (na.contains(nb) || nb.contains(na)) {
      final short = math.min(na.length, nb.length);
      final long = math.max(na.length, nb.length);
      return 0.75 + 0.25 * (short / long);
    }

    // Dice 系数（按 2-gram）：对中英文都稳，且不受词序影响
    final ba = _bigrams(na);
    final bb = _bigrams(nb);
    if (ba.isEmpty || bb.isEmpty) return 0;
    final inter = ba.intersection(bb).length;
    return 2 * inter / (ba.length + bb.length);
  }

  static Set<String> _bigrams(String s) {
    if (s.length < 2) return {s};
    final out = <String>{};
    for (var i = 0; i + 2 <= s.length; i++) {
      out.add(s.substring(i, i + 2));
    }
    return out;
  }
}
