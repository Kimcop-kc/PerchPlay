import 'dart:convert';

import 'package:path/path.dart' as p;

import '../core/constants/app_constants.dart';

/// 外挂字幕「同名自动加载 + 记住上次选择」的纯逻辑
///
/// 为什么单独拆出来：自动挂字幕要判断「哪些文件算同名」「多个候选取谁」
/// 「上次的选择还算不算数」。这些判断如果和列目录 / SharedPreferences 混在
/// 一起，就只能靠跑播放器来验证。这里只收文件名和记忆数据、不碰文件系统，
/// 所以排序与选择规则可以用单测穷举（见 test/subtitle_auto_test.dart）。
class Subtitles {
  Subtitles._();

  /// 找出同一部视频的同名字幕候选，按优先级从高到低排序
  ///
  /// [videoPath] 视频完整路径；[siblingFileNames] 同目录下的文件名（传全路径
  /// 也行，只取最后一段）。为什么不在这里列目录：IO 交给
  /// [SubtitleAutoService]，纯函数才能在单测里穷举各种命名。
  ///
  /// 排序规则（越靠前越优先）：
  ///  1. 无语言后缀的普通同名永远第一（`电影.srt` / `电影.ass` …）——
  ///     那是用户自己放在视频旁边的那份，语言标记只是「可能有更合适的一条」的线索，
  ///     不能盖过用户的直接安排。
  ///  2. 其余按语言档位：中文/中英双语 > 简体/繁体 > 英文 > 其它语言。
  ///  3. 同档内按扩展名排（srt > ass > ssa > vtt > sub，直接复用
  ///     [AppConstants.supportedSubtitleFormats] 的顺序，避免两处格式表不同步）；
  ///     最后按文件名兜底 —— 目录列举顺序各平台不一致，得有个确定结果。
  static List<SubtitleCandidate> findCandidates(
    String videoPath,
    Iterable<String> siblingFileNames,
  ) {
    final videoStem = p.basenameWithoutExtension(videoPath);
    if (videoStem.isEmpty) return const <SubtitleCandidate>[];
    final videoDir = p.dirname(videoPath);
    final videoLower = videoStem.toLowerCase();

    final ranked = <({
      SubtitleCandidate candidate,
      int tier,
      int extRank,
    })>[];

    for (final raw in siblingFileNames) {
      final name = p.basename(raw);
      final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
      final extRank = AppConstants.supportedSubtitleFormats.indexOf(ext);
      // 不是项目支持的外挂字幕格式（.mp4 / .txt / .bak ...）
      if (extRank < 0) continue;

      final stem = p.basenameWithoutExtension(name);
      final stemLower = stem.toLowerCase();
      // 同名 = 去掉扩展名后完全相同，或「视频名.语言后缀」。
      // 用 `.` 隔开判断，避免 `电影2.srt`、`电影花絮.srt` 被误当成 `电影.mp4` 的字幕。
      final sameName = stemLower == videoLower;
      if (!sameName && !stemLower.startsWith('$videoLower.')) continue;

      // 普通同名（无后缀）在 _classify('') 里拿到最高档位
      final suffix = sameName ? '' : stemLower.substring(videoLower.length + 1);
      final info = _classify(suffix);
      final language = info.label ?? (suffix.isEmpty ? '外挂字幕' : suffix);

      ranked.add((
        candidate: SubtitleCandidate(
          path: p.join(videoDir, name),
          fileName: name,
          language: language,
          title: '$language (${ext.toUpperCase()})',
        ),
        tier: info.tier,
        extRank: extRank,
      ));
    }

    ranked.sort((a, b) {
      var c = a.tier.compareTo(b.tier);
      if (c != 0) return c;
      c = a.extRank.compareTo(b.extRank);
      if (c != 0) return c;
      return a.candidate.fileName.toLowerCase().compareTo(
            b.candidate.fileName.toLowerCase(),
          );
    });

    return [for (final r in ranked) r.candidate];
  }

  /// 用已知路径造一个候选
  ///
  /// 记忆里的字幕文件可能不在同目录同名候选里（用户是从 Download 之类的地方
  /// 手动选的），恢复时也要有语言/标题能在面板里正常显示。
  static SubtitleCandidate describe(String path) {
    final name = p.basename(path);
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    final stem = p.basenameWithoutExtension(name);
    final dot = stem.lastIndexOf('.');
    final suffix = dot >= 0 ? stem.substring(dot + 1).toLowerCase() : '';
    final info = _classify(suffix);
    final language = info.label ?? (suffix.isEmpty ? '外挂字幕' : suffix);
    return SubtitleCandidate(
      path: path,
      fileName: name,
      language: language,
      title: ext.isEmpty ? language : '$language (${ext.toUpperCase()})',
    );
  }

  /// 决定这次打开视频挂哪条字幕
  ///
  /// [remembered] 是「这个视频上次选了什么」；[exists] 用来判断记忆里的文件
  /// 是否还在。为什么不在这里自己判文件：pick 要保持无 IO 才能在单测里跑，
  /// 所以把「文件还在不在」做成可注入的回调（不传则按「还在」处理）。
  ///
  /// 优先级：
  ///  1. 记忆是「用户关掉了字幕」→ 什么都不挂（需求明确要求别再自动挂回来）；
  ///  2. 记忆的字幕文件还在 → 恢复它，哪怕它不是同名候选里优先级最高的；
  ///  3. 记忆的文件已被删 / 没有记忆 → 按 [findCandidates] 的顺序取第一条。
  static SubtitlePick pick(
    List<SubtitleCandidate> candidates,
    SubtitleMemory? remembered, {
    bool Function(String path)? exists,
  }) {
    if (remembered != null) {
      if (remembered.off) {
        return const SubtitlePick._(SubtitlePickKind.rememberedOff, null);
      }
      final path = remembered.subtitlePath!;
      if (exists?.call(path) ?? true) {
        SubtitleCandidate? hit;
        for (final c in candidates) {
          if (c.path == path) {
            hit = c;
            break;
          }
        }
        return SubtitlePick._(
          SubtitlePickKind.rememberedFile,
          path,
          hit ?? describe(path),
        );
      }
      // 文件没了就当作没记忆，继续往下走自动挑选
    }
    if (candidates.isEmpty) {
      return const SubtitlePick._(SubtitlePickKind.none, null);
    }
    final best = candidates.first;
    return SubtitlePick._(SubtitlePickKind.auto, best.path, best);
  }

  /// 优先级档位（数字越小越优先）
  ///
  /// 0 = 无语言后缀的普通同名：用户自己放在视频旁边那份，永远第一
  /// 1 = 中文 / 中英双语
  /// 2 = 简体 / 繁体
  /// 3 = 英文
  /// 4 = 其它语言后缀
  ///
  /// 为什么普通同名要单独占 0 档：`电影.srt` 是用户直接安排的那条，
  /// 语言标记只表示「可能存在更合适的一条」，不能反过来盖过它 ——
  /// 否则 `电影.srt` 和 `电影.en.srt` 同时存在时会被英文字幕抢走。
  static const int _tierPlain = 0;
  static const int _tierZh = 1;
  static const int _tierVariant = 2;
  static const int _tierEnglish = 3;
  static const int _tierOther = 4;

  /// 语言后缀 → 档位 + 显示名
  ///
  /// 档位见上面几个常量（0 档只属于「无后缀」，这里从 1 档起）。
  /// 注意 `chs` / `chi` 算中文档（最常见的字幕站标记），
  /// 而「简体」「繁体」「sc」「tc」这类字形标记归下一档 ——
  /// 明确标了字形的，才排在通用中文后面。
  static const Map<String, ({int tier, String label})> _suffixInfo = {
    // 1 档：中文 / 中英双语
    'zh': (tier: _tierZh, label: '中文'),
    'zh-cn': (tier: _tierZh, label: '简体中文'),
    'zh-hans': (tier: _tierZh, label: '简体中文'),
    'zh-sg': (tier: _tierZh, label: '简体中文'),
    'chs': (tier: _tierZh, label: '简体中文'),
    'chi': (tier: _tierZh, label: '中文'),
    'zho': (tier: _tierZh, label: '中文'),
    'cn': (tier: _tierZh, label: '中文'),
    '中文': (tier: _tierZh, label: '中文'),
    '中英': (tier: _tierZh, label: '中英双语'),
    '中英双语': (tier: _tierZh, label: '中英双语'),
    '双语': (tier: _tierZh, label: '中英双语'),
    // 2 档：繁体 / 简体（字形标记）
    'cht': (tier: _tierVariant, label: '繁体中文'),
    'zh-tw': (tier: _tierVariant, label: '繁体中文'),
    'zh-hk': (tier: _tierVariant, label: '繁体中文'),
    'zh-hant': (tier: _tierVariant, label: '繁体中文'),
    '繁体': (tier: _tierVariant, label: '繁体中文'),
    '繁體': (tier: _tierVariant, label: '繁体中文'),
    '繁体中文': (tier: _tierVariant, label: '繁体中文'),
    '繁體中文': (tier: _tierVariant, label: '繁体中文'),
    '简体': (tier: _tierVariant, label: '简体中文'),
    '簡體': (tier: _tierVariant, label: '简体中文'),
    '简体中文': (tier: _tierVariant, label: '简体中文'),
    'sc': (tier: _tierVariant, label: '简体中文'),
    'tc': (tier: _tierVariant, label: '繁体中文'),
    // 3 档：英文
    'en': (tier: _tierEnglish, label: 'English'),
    'eng': (tier: _tierEnglish, label: 'English'),
    'english': (tier: _tierEnglish, label: 'English'),
    'en-us': (tier: _tierEnglish, label: 'English'),
    'en-gb': (tier: _tierEnglish, label: 'English'),
    // 4 档：其它语言（有名字就显示名字，排最后）
    'ja': (tier: _tierOther, label: '日本語'),
    'jp': (tier: _tierOther, label: '日本語'),
    'jpn': (tier: _tierOther, label: '日本語'),
    'ko': (tier: _tierOther, label: '한국어'),
    'kor': (tier: _tierOther, label: '한국어'),
    'fr': (tier: _tierOther, label: 'Français'),
    'fre': (tier: _tierOther, label: 'Français'),
    'fra': (tier: _tierOther, label: 'Français'),
    'de': (tier: _tierOther, label: 'Deutsch'),
    'ger': (tier: _tierOther, label: 'Deutsch'),
    'deu': (tier: _tierOther, label: 'Deutsch'),
    'es': (tier: _tierOther, label: 'Español'),
    'spa': (tier: _tierOther, label: 'Español'),
    'ru': (tier: _tierOther, label: 'Русский'),
    'rus': (tier: _tierOther, label: 'Русский'),
  };

  /// 后缀归类；[suffix] 为空表示「普通同名，没带语言后缀」，即最高档
  ///
  /// 多段后缀（`电影.zh.chs.srt`）按 `.` 拆开取最高档，
  /// 这样 `zh.chs`、`zh-hans` 这类组合标记不会因为拼法不同被当成「其它」。
  static ({int tier, String? label}) _classify(String suffix) {
    if (suffix.isEmpty) return (tier: _tierPlain, label: null);
    var tier = _tierOther;
    String? label;
    for (final part in suffix.split('.')) {
      final info = _suffixInfo[part];
      if (info == null) continue;
      if (label == null || info.tier < tier) {
        tier = info.tier;
        label = info.label;
      }
    }
    return (tier: tier, label: label);
  }
}

/// 一条同名字幕候选
class SubtitleCandidate {
  /// 字幕文件完整路径
  final String path;

  /// 文件名（面板显示 / 排序兜底用）
  final String fileName;

  /// 语言名：识别出来的显示名，识别不了就用后缀本身（比显示 Unknown 有用）
  final String language;

  /// 面板里的一行文字，如「简体中文 (SRT)」
  final String title;

  const SubtitleCandidate({
    required this.path,
    required this.fileName,
    required this.language,
    required this.title,
  });

  @override
  String toString() => 'SubtitleCandidate($fileName)';
}

/// 这次打开视频「该不该挂字幕、挂哪条」的结论
enum SubtitlePickKind {
  /// 没有候选文件，也没有可用记忆 → 什么都不做
  none,

  /// 记忆里用户上次关掉了字幕 → 不要自动挂
  rememberedOff,

  /// 恢复记忆里的字幕文件（文件确认还在）
  rememberedFile,

  /// 按优先级自动挑的第一条同名候选
  auto,
}

/// [Subtitles.pick] 的返回值
class SubtitlePick {
  final SubtitlePickKind kind;

  /// 要挂的字幕路径；null = 不挂
  final String? path;

  /// 对应的候选（含语言/标题），自动挑选与记忆恢复都会有
  final SubtitleCandidate? candidate;

  const SubtitlePick._(this.kind, this.path, [this.candidate]);

  /// 是否需要挂字幕
  bool get shouldAttach => path != null;

  @override
  String toString() => 'SubtitlePick($kind, $path)';
}

/// 一个视频「上次选了什么字幕」的记忆
///
/// [subtitlePath] 为 null 表示用户上次把字幕关掉了 —— 下次打开不要再自动挂。
/// 这和「没有记忆」是两种状态，不能混（否则用户关一次字幕，下次又被自动挂上）。
class SubtitleMemory {
  /// 视频路径；**存储用的键是归一化过的**（Windows 上转小写，见
  /// AppSettingsService 的读写），归一化负责保证同一文件不会记成两条。
  final String videoPath;

  /// 上次选的字幕文件路径；null = 上次关掉了字幕
  final String? subtitlePath;

  /// 最近一次使用时间（毫秒时间戳），按最近使用淘汰时用
  final int updatedAt;

  const SubtitleMemory({
    required this.videoPath,
    required this.updatedAt,
    this.subtitlePath,
  });

  /// 上次是不是「关掉了字幕」
  bool get off => subtitlePath == null;

  /// 最多留多少条
  ///
  /// 为什么要上限：SharedPreferences 是整份读进内存的，片子看得越多记忆越长，
  /// 不淘汰的话会一直膨胀（启动变慢、写盘变大），而几百条之外的记忆也基本不会再命中。
  static const int maxEntries = 300;

  /// 把新记忆插到最前（最近使用），同一个视频只留最新一条，
  /// 超过 [maxEntries]（或调用方指定的 [maxEntries]）时从尾部丢最旧的。
  ///
  /// 返回新列表而不是原地改：调用方是单例里的字段，替换整个列表
  /// 才不会让别处拿到的旧引用突然变长。
  static List<SubtitleMemory> upsert(
    List<SubtitleMemory> entries,
    SubtitleMemory entry, {
    int? maxEntries,
  }) {
    final cap = maxEntries ?? SubtitleMemory.maxEntries;
    if (cap <= 0) return <SubtitleMemory>[];
    final out = <SubtitleMemory>[entry];
    for (final old in entries) {
      // 同一个视频覆盖旧记录（用户可能改选了另一条字幕，或改成关闭）
      if (old.videoPath == entry.videoPath) continue;
      if (out.length >= cap) break; // 到上限，剩下的都是更旧的
      out.add(old);
    }
    return out;
  }

  /// 查某个视频的记忆；[videoPath] 必须是归一化后的键
  static SubtitleMemory? find(List<SubtitleMemory> entries, String videoPath) {
    for (final e in entries) {
      if (e.videoPath == videoPath) return e;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'v': videoPath,
        's': subtitlePath,
        't': updatedAt,
      };

  /// 序列化成一行 JSON
  ///
  /// 为什么用 JSON 而不是把路径用分隔符拼起来：路径里可能出现各种字符，
  /// 拼接方案一旦碰上没考虑到的字符就会整条解析错位，JSON 由 dart:convert 兜底。
  String encode() => jsonEncode(toJson());

  /// 解析一行；坏数据返回 null（一条脏记录不该毁掉整份记忆）
  static SubtitleMemory? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final videoPath = decoded['v'];
      if (videoPath is! String || videoPath.isEmpty) return null;
      final subtitlePath = decoded['s'];
      final updatedAt = decoded['t'];
      return SubtitleMemory(
        videoPath: videoPath,
        subtitlePath: subtitlePath is String && subtitlePath.isNotEmpty
            ? subtitlePath
            : null,
        updatedAt: updatedAt is int ? updatedAt : 0,
      );
    } catch (_) {
      return null;
    }
  }
}
