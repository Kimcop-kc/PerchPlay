import 'package:path/path.dart' as p;

import 'media_namer_service.dart';

/// 一个自动分组结果
class MediaGroup {
  /// 列表名（剧集名，或电影桶的「电影」）
  final String name;

  /// 是否为「电影」桶
  final bool isMovieBucket;

  /// 输入下标（已按季集/序号排好）
  final List<int> indices;

  const MediaGroup({
    required this.name,
    required this.indices,
    this.isMovieBucket = false,
  });

  int get length => indices.length;
}

/// 把一堆视频路径分成「剧集列表」和「电影」
///
/// 判定顺序：
///  1. 文件名里有**明确**季集标记（S01E02 / 1x02 / 第2集 / EP02 / [02]）
///     → 按剧集名归组
///  2. 只有**末尾序号**（`Show - 02`、`Show.02.1080p`、`02.mkv`）或干脆没标题
///     → 看**所在文件夹**：同一子文件夹里 ≥2 个带序号的文件，即成剧集，
///       剧集名取文件夹名（`Movies/Show/01.mkv`、`02.mkv`）
///  3. 同一目录下剧集名相同且序号不同（`Movies/Show.01.mkv`、`Show.02.mkv`）
///     → 也算剧集
///  4. **只剩一个成员的剧集不算剧集**，回落到「电影」
///     （避免把 `Liuliang.Earth.2.2023.2160p` 这种片名带数字的电影吞掉）
///  5. 其余都是电影，合成一个「电影」列表
class MediaGrouping {
  MediaGrouping._();

  /// 少于这个数量不成列表
  static const minGroupSize = 2;

  static List<MediaGroup> group(List<String> paths) {
    final parsed = <int, MediaInfo>{};
    for (var i = 0; i < paths.length; i++) {
      parsed[i] = MediaNamer.parse(paths[i]);
    }

    // key → (名称, 成员)
    final strong = <String, List<int>>{}; // 明确标记
    final byFolder = <String, List<int>>{}; // 靠文件夹聚集
    final byTitle = <String, List<int>>{}; // 同目录同名聚集

    for (var i = 0; i < paths.length; i++) {
      final info = parsed[i]!;
      final path = paths[i];
      if (!info.isEpisode) continue;

      if (!info.weakEpisode) {
        strong.putIfAbsent(_key(info.seriesTitle), () => []).add(i);
        continue;
      }

      // 弱识别：先按「非通用父目录」聚集
      final folder = MediaNamer.folderTitle(path);
      if (folder != null) {
        byFolder.putIfAbsent(p.dirname(path), () => []).add(i);
      }
      // 同时按「同目录 + 同名」聚集，兜住 Movies/ 根目录下的 Show.01/02
      final dir = p.dirname(path);
      final title = info.seriesTitle;
      if (title.isNotEmpty && title != p.basenameWithoutExtension(path)) {
        byTitle.putIfAbsent('$dir\u0000${_key(title)}', () => []).add(i);
      }
    }

    final groups = <MediaGroup>[];
    final claimed = <int>{};

    void take(int i) => claimed.add(i);

    // ── 明确标记的剧集 ──
    strong.forEach((key, members) {
      if (members.length < minGroupSize) return;
      members.sort((a, b) => _order(parsed[a]!).compareTo(_order(parsed[b]!)));
      members.forEach(take);
      groups.add(MediaGroup(name: parsed[members.first]!.seriesTitle, indices: members));
    });

    // ── 同目录同名聚集（文件名里已经能看出剧集名，优先用它）──
    byTitle.forEach((key, members) {
      final fresh = members.where((i) => !claimed.contains(i)).toList();
      if (fresh.length < minGroupSize) return;
      final eps = fresh.map((i) => parsed[i]!.episode).toSet();
      if (eps.length < minGroupSize) return;
      fresh.sort((a, b) => _order(parsed[a]!).compareTo(_order(parsed[b]!)));
      fresh.forEach(take);
      groups.add(MediaGroup(name: parsed[fresh.first]!.seriesTitle, indices: fresh));
    });

    // ── 文件夹聚集（文件名里没有剧集名时才用文件夹名兜底）──
    byFolder.forEach((dir, members) {
      final fresh = members.where((i) => !claimed.contains(i)).toList();
      if (fresh.length < minGroupSize) return;
      // 序号必须各不相同，否则可能是同一集的不同版本
      final eps = fresh.map((i) => parsed[i]!.episode).toSet();
      if (eps.length < minGroupSize) return;
      fresh.sort((a, b) => _order(parsed[a]!).compareTo(_order(parsed[b]!)));
      fresh.forEach(take);
      groups.add(MediaGroup(
        name: MediaNamer.folderTitle(paths[fresh.first]) ?? '未命名剧集',
        indices: fresh,
      ));
    });

    // ── 电影：剩下的全部（含没凑成剧集的孤立「剧集」）──
    final movies = <int>[
      for (var i = 0; i < paths.length; i++)
        if (!claimed.contains(i)) i,
    ];
    if (movies.length >= minGroupSize) {
      movies.sort((a, b) => p
          .basename(paths[a])
          .toLowerCase()
          .compareTo(p.basename(paths[b]).toLowerCase()));
      groups.add(MediaGroup(name: '电影', indices: movies, isMovieBucket: true));
    }

    // 自动列表排序：剧集按名称，电影桶放最后
    groups.sort((a, b) {
      if (a.isMovieBucket != b.isMovieBucket) return a.isMovieBucket ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return groups;
  }

  /// 先按季、再按集；没有季的按集排
  static int _order(MediaInfo info) =>
      (info.season != null ? (info.season! + 1) * 100000 : 0) +
      (info.episode ?? 0) * 10;

  static String _key(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s._\-]+'), '').trim();
}
