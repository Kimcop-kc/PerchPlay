import 'package:path/path.dart' as p;

import 'media_grouping_service.dart';

/// 视频来源分类
enum VideoSource {
  /// 系统相机 / DCIM / 厂商相机
  camera,

  /// 剪映 / CapCut / 快影 / InShot 等剪辑软件
  capcut,

  /// 抖音 / TikTok / 快手 / 微信视频号 / 微博 等
  shortVideo,

  /// 屏幕录制
  screenRecord,

  /// 聊天/社交保存（微信/QQ/Telegram/WhatsApp）
  social,

  /// Download 目录
  download,

  /// 其他自定义目录
  other,
}

/// 分组结果
class SourceGroup {
  final String name;
  final List<int> indices;
  final bool isSeries;   // true=影视剧集，false=个人视频
  final bool isFallback; // true=按前缀兜底分组
  final bool isMovie;    // true=「电影」集合（影视文件里没归成剧集/前缀的那些）

  const SourceGroup({
    required this.name,
    required this.indices,
    this.isSeries = false,
    this.isFallback = false,
    this.isMovie = false,
  });
}

/// 按**文件夹路径**判断视频来源，决定用哪种分组策略。
class VideoSourceService {
  VideoSourceService._();

  // ═══════════════════════════════════════════════════════════════
  // 来源识别
  // ═══════════════════════════════════════════════════════════════

  static VideoSource classify(String path) {
    final folder = p.dirname(path).replaceAll('/', '\\').toLowerCase();

    // ── 剪辑/图片美化软件（必须在相机之前判断，防止"无他相机"被"相机"误命中）──
    if (_containsAny(folder, const [
      'capcut',
      'com.lemon.lv',
      '剪映',
      '快影',
      '必剪',
      '巧影',
      'inshot',
      'vivacut',
      'kineMaster',
      'kinemaster',
      'powerdirector',
      'filmora',
      'video.guru',
      'vlognow',
      'viva video',
      'vn video',
      'vn.',
      '美图秀秀',
      '美颜',
      '轻颜',
      '无他相机',
      '快剪辑',
      '乐秀',
      '小影',
      'viva cut',
      'splice',
      'premiere rush',
      'lumafusion',
      'alight motion',
      'node video',
      'video leap',
    ])) {
      return VideoSource.capcut;
    }

    // ── 聊天/社交（优先级高于 Download，因为微信/QQ 保存也在 Download 子目录）──
    if (_containsAny(folder, const [
      r'tencent\micromsg',
      'wechat',
      '微信',
      r'qq\video',
      r'qq\shortvideo',
      r'qq\ptt',
      r'\qq\',
      'qq视频',
      'telegram video',
      'telegram\\video',
      'whatsapp video',
      'whatsapp\\video',
      'messenger\\video',
      'signal\\video',
      'line_movies',
      'kakaotalk',
    ])) {
      return VideoSource.social;
    }

    // ── 相机 ──
    if (_containsAny(folder, const [
      r'\dcim\camera',
      r'\dcim\100',
      r'\dcim\101',
      r'\dcim\102',
      r'\dcim\103',
      r'\dcim\open',
      r'\dcim\restored',
      r'\pictures\camera',
      r'\pictures\raw',
      // 小米
      r'\dcim\camerax',
      '相机',
      r'\miui\gallery',
      // 华为
      r'\huawei\camera',
      r'\华为\相机',
      // OPPO / realme
      r'\oppo\camera',
      r'\realme\camera',
      // vivo / iQOO
      r'\vivo\camera',
      r'\iqoo\camera',
      // 三星
      r'\dcim\gcam',
      // 截图
      r'\screenshot',
      r'\screenshots',
      r'\截屏',
      r'\截图',
    ])) {
      return VideoSource.camera;
    }

    // ── 屏幕录制 ──
    if (_containsAny(folder, const [
      'screen record',
      'screenrecord',
      'screen_record',
      'screen-recorder',
      '屏幕录制',
      '录屏',
      '录制的视频',
      'az screen recorder',
      'mobizen',
      'screen cam',
      'screen capture',
      'omlet arcade',
      'du recorder',
    ])) {
      return VideoSource.screenRecord;
    }

    // ── 短视频 App ──
    if (_containsAny(folder, const [
      'tiktok',
      'douyin',
      '抖音',
      'kuaishou',
      '快手',
      'reels',
      r'instagram\video',
      '小红书',
      'snapchat',
      'likee',
      'kwai',
      'weishi',
      '微视',
      '火山',
      '西瓜视频',
      'youtube',
      'bilibili',
      'b站',
      '哔哩哔哩',
      'twitch',
      'vimeo',
      'dailymotion',
      '最右',
      '皮皮虾',
      '微博',
      'weibo',
    ])) {
      return VideoSource.shortVideo;
    }

    // ── Download ──
    if (_containsAny(folder, const [
      r'\download',
      r'\downloads',
      '下载',
      r'\baiduNetdisk',
      r'\baidunetdiskdownload',
      r'\baiduyun',
      '迅雷下载',
      'thunder',
      'ucdownloads',
      'uc浏览器',
      'qq浏览器',
      'edge\\download',
      'firefox\\download',
    ])) {
      return VideoSource.download;
    }

    return VideoSource.other;
  }

  // ═══════════════════════════════════════════════════════════════
  // 完整分组：合并个人分组 + 影视分组 + 兜底前缀分组
  // ═══════════════════════════════════════════════════════════════

  /// 对所有视频做完整分组，返回一组 [SourceGroup]。
  ///
  /// 策略：
  ///  1. 个人来源（相机/剪辑/短视频/录屏/社交）→ 按来源+前缀分组
  ///  2. 影视来源（other/download）→ `MediaGrouping.group()` 识别剧集
  ///  3. 影视来源中未被剧集分组的 → 按前缀兜底分组（≥2 个才成组）
  static List<SourceGroup> groupAll(List<String> paths) {
    final groups = <SourceGroup>[];

    // ── 先按来源分桶 ──
    final personal = <int>[]; // camera/capcut/shortVideo/screenRecord/social
    final media = <int>[];    // other/download

    for (var i = 0; i < paths.length; i++) {
      final src = classify(paths[i]);
      if (src == VideoSource.other || src == VideoSource.download) {
        media.add(i);
      } else {
        personal.add(i);
      }
    }

    // ── 1) 个人视频 → 按来源+前缀分组 ──
    final personalGroups = _groupBySourceAndPrefix(paths, personal);
    groups.addAll(personalGroups);

    // ── 2) 影视路径 → MediaGrouping 识别剧集 ──
    final mediaPaths = media.map((i) => paths[i]).toList();
    final seriesGroups = MediaGrouping.group(mediaPaths);
    final usedInSeries = <int>{};

    for (final g in seriesGroups) {
      final mapped = g.indices.map((mi) => media[mi]).toList();
      usedInSeries.addAll(mapped);
      groups.add(SourceGroup(name: g.name, indices: mapped, isSeries: true));
    }

    // ── 3) 影视路径中未被剧集分组的 → 前缀兜底（≥2 个相同前缀才成组）──
    final remainingMedia = <int>[
      for (final mi in media)
        if (!usedInSeries.contains(mi)) mi,
    ];

    if (remainingMedia.isNotEmpty) {
      final fallback = _groupByPrefix(paths, remainingMedia, minSize: 2);
      final usedInFallback = <int>{};
      for (final f in fallback) {
        usedInFallback.addAll(f.indices);
        groups.add(SourceGroup(
          name: '📂 ${f.name}',
          indices: f.indices,
          isFallback: true,
        ));
      }

      // ── 4) 还是没归组的影视文件 → 统一进「电影」集合 ──
      // 单部电影（`Heartstopper.Forever.2160p.内嵌官中.mkv`）既不是剧集、
      // 前缀又凑不满 2 个，以前会**任何列表都不进**，用户在播放列表里看不到它。
      final leftovers = <int>[
        for (final mi in remainingMedia)
          if (!usedInFallback.contains(mi)) mi,
      ];
      if (leftovers.isNotEmpty) {
        groups.add(SourceGroup(
          name: movieGroupName,
          indices: leftovers,
          isMovie: true,
        ));
      }
    }

    return groups;
  }

  /// 「电影」集合的固定列表名（参与生成列表 id，改名等于换一个列表，慎改）
  static const movieGroupName = '🎬 电影';

  // ═══════════════════════════════════════════════════════════════
  // 标签
  // ═══════════════════════════════════════════════════════════════

  static String sourceLabel(VideoSource source, {String? path}) {
    switch (source) {
      case VideoSource.camera:
        return '📷 相机';
      case VideoSource.capcut:
        return _capcutLabel(path);
      case VideoSource.shortVideo:
        return _shortVideoLabel(path);
      case VideoSource.screenRecord:
        return '🖥️ 录屏';
      case VideoSource.social:
        return _socialLabel(path);
      case VideoSource.download:
      case VideoSource.other:
        return '';
    }
  }

  /// 来源对应的 emoji（用于 UI 标签）
  static String sourceEmoji(VideoSource source) {
    switch (source) {
      case VideoSource.camera:
        return '📷';
      case VideoSource.capcut:
        return '✂️';
      case VideoSource.shortVideo:
        return '🎬';
      case VideoSource.screenRecord:
        return '🖥️';
      case VideoSource.social:
        return '💬';
      case VideoSource.download:
      case VideoSource.other:
        return '';
    }
  }

  static String _capcutLabel(String? path) {
    if (path == null) return '✂️ 剪辑';
    final f = p.dirname(path).toLowerCase().replaceAll('/', '\\');
    if (f.contains(r'\capcut')) return '✂️ CapCut';
    if (f.contains('inshot')) return '✂️ InShot';
    if (f.contains('kinemaster')) return '✂️ KineMaster';
    if (f.contains('powerdirector')) return '✂️ PowerDirector';
    if (f.contains('filmora')) return '✂️ Filmora';
    return '✂️ 剪辑';
  }

  static String _shortVideoLabel(String? path) {
    if (path == null) return '🎬 短视频';
    final f = p.dirname(path).toLowerCase().replaceAll('/', '\\');
    if (f.contains(r'\tiktok')) return '🎬 TikTok';
    if (f.contains('douyin') || f.contains('抖音')) return '🎬 抖音';
    if (f.contains('kuaishou') || f.contains('快手')) return '🎬 快手';
    if (f.contains('小红书')) return '🎬 小红书';
    if (f.contains(r'\youtube')) return '🎬 YouTube';
    if (f.contains('bilibili') || f.contains('哔哩哔哩')) return '🎬 B站';
    if (f.contains('微博') || f.contains('weibo')) return '🎬 微博';
    return '🎬 短视频';
  }

  static String _socialLabel(String? path) {
    if (path == null) return '💬 社交';
    final f = p.dirname(path).toLowerCase().replaceAll('/', '\\');
    if (f.contains(r'\wechat') || f.contains('微信')) return '💬 微信';
    if (f.contains(r'\qq\') || f.contains('qq视频')) return '💬 QQ';
    if (f.contains(r'\telegram')) return '💬 Telegram';
    if (f.contains(r'\whatsapp')) return '💬 WhatsApp';
    return '💬 社交';
  }

  // ═══════════════════════════════════════════════════════════════
  // 内部分组
  // ═══════════════════════════════════════════════════════════════

  /// 按来源+前缀分组：同来源内相同前缀的归到一个列表
  static List<SourceGroup> _groupBySourceAndPrefix(
    List<String> paths,
    List<int> indices,
  ) {
    final groups = <SourceGroup>[];

    // 按来源分桶
    final bySource = <VideoSource, List<int>>{};
    for (final i in indices) {
      final src = classify(paths[i]);
      bySource.putIfAbsent(src, () => []).add(i);
    }

    for (final entry in bySource.entries) {
      final src = entry.key;
      final idxs = entry.value;
      final label = sourceLabel(src, path: paths[idxs.first]);

      // 同来源内按前缀再细分（大小写不敏感）
      final byPrefix = <String, List<int>>{};
      final prefixDisplay = <String, String>{}; // key → 首次出现的原始大小写
      for (final i in idxs) {
        final name = p.basenameWithoutExtension(paths[i]);
        final pre = _extractPrefix(name);
        final key = pre.toLowerCase();
        byPrefix.putIfAbsent(key, () => []).add(i);
        prefixDisplay.putIfAbsent(key, () => pre);
      }

      for (final pb in byPrefix.entries) {
        final display = prefixDisplay[pb.key] ?? pb.key;
        final name = display.isEmpty ? label : '$label · $display';
        groups.add(SourceGroup(name: name, indices: pb.value));
      }
    }

    return groups;
  }

  /// 纯前缀分组（用于兜底）：取文件名中分隔符前的部分，相同前缀 ≥ minSize 则成组
  static List<SourceGroup> _groupByPrefix(
    List<String> paths,
    List<int> indices, {
    int minSize = 2,
  }) {
    if (indices.length < minSize) return [];

    // key → indices; display 存首次出现的原始文件名
    final buckets = <String, List<int>>{};
    final displayNames = <String, String>{};
    for (final i in indices) {
      final name = p.basenameWithoutExtension(paths[i]);
      final key = _groupKey(name);
      if (key.isEmpty) continue; // 纯数字文件名，无意义前缀，跳过
      buckets.putIfAbsent(key, () => []).add(i);
      displayNames.putIfAbsent(key, () => name);
    }

    final groups = <SourceGroup>[];
    for (final entry in buckets.entries) {
      if (entry.value.length >= minSize) {
        // 显示用前缀段（原始大小写）
        final raw = displayNames[entry.key] ?? '';
        final display = _displayPrefix(raw, entry.key);
        groups.add(SourceGroup(
          name: display.isEmpty ? entry.key : display,
          indices: entry.value,
        ));
      }
    }
    return groups;
  }

  /// 从原始文件名提取显示前缀：第一个分隔符前的段 + 去尾数，
  /// 保留原始大小写（与 _groupKey 同逻辑，但不做 lowercase）。
  static String _displayPrefix(String fileName, String fallback) {
    var s = fileName.replaceFirst(RegExp(r'^\d{1,4}\s*[-_.\s–—]+'), '');
    final m = RegExp(r'^([^-_~–—.\s]{1,20})').firstMatch(s);
    final raw = m?.group(1) ?? (s.length > 20 ? s.substring(0, 20) : s);
    final trimmed = raw.replaceFirst(RegExp(r'\d+$'), '').trim();
    if (trimmed.isNotEmpty) return trimmed;
    return raw;
  }

  /// 提取归组 key：取第一个分隔符前的文本段，去头去尾数字，
  /// 再裁剪尾部序号 → Show01 / Show02 统一为 Show
  static String _groupKey(String fileName) {
    // 去掉纯数字开头（01-xxx → xxx）
    var s = fileName.replaceFirst(RegExp(r'^\d{1,4}\s*[-_.\s–—]+'), '');
    // 统一小写避免 LV / lv 拆散
    s = s.toLowerCase();

    // 取第一个分隔符之前的段
    final m = RegExp(r'^([^-_~–—.\s]{1,20})').firstMatch(s);
    final raw = m?.group(1) ?? (s.length > 20 ? s.substring(0, 20) : s);

    // 去掉尾部数字 → Show01 → Show
    final trimmed = raw.replaceFirst(RegExp(r'\d+$'), '').trim();
    if (trimmed.isNotEmpty) return trimmed;

    return raw;
  }

  /// 提取文件名前缀（源标签后用 · 连接的小标识）。
  /// 返回原始大小写，大小写不敏感的分组由调用方处理。
  static String _extractPrefix(String fileName) {
    var s = fileName.replaceFirst(RegExp(r'^\d{1,4}\s*[-_.\s–—]+'), '');
    final sep = RegExp(r'[-_~–—]').firstMatch(s);
    if (sep != null && sep.start > 0) {
      final prefix = s.substring(0, sep.start).trim();
      if (prefix.isNotEmpty && prefix.length <= 12) return prefix;
    }
    final ascii = RegExp(r'^[A-Za-z]{2,6}').firstMatch(s);
    if (ascii != null) return ascii.group(0)!;
    return '';
  }

  // ═══════════════════════════════════════════════════════════════
  // 工具
  // ═══════════════════════════════════════════════════════════════

  static bool _containsAny(String text, List<String> needles) {
    return needles.any(text.contains);
  }
}