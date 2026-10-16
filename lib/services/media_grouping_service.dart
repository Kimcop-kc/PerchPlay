import 'package:path/path.dart' as p;

import 'media_namer_service.dart';

/// 一个自动分组结果
class MediaGroup {
  /// 列表名（剧名，来自文件名）
  final String name;

  /// 输入下标（已按季集/序号排好）
  final List<int> indices;

  const MediaGroup({required this.name, required this.indices});

  int get length => indices.length;
}

/// 按**视频文件名**把视频归入剧集列表
///
/// 规则（全部只看文件名，不看所在文件夹）：
///  1. 文件名里有明确季集标记（`S01E02` / `1x02` / `第02集` / `EP05` /
///     `[02]` / `Show.S01.01`）→ 按剧名归组，只有一集也成列表
///  2. 文件名里只有末尾序号（`Show - 01 [1080p]`、`Show.02.1080p`）→
///     需要**同类聚集**佐证：同一剧名至少 2 个不同集数才算剧集，
///     避免把 `Rocky 2.mkv` 这种片名带数字的电影当成剧集
///  3. 文件名里只有编号、没有剧名（`01.mp4`）→ 不成列表
///  4. 没有集数信息的（电影等）→ 不进任何列表
///
/// 注意：**没有「电影」列表**，也**不再拿文件夹名当剧名**。
class MediaGrouping {
  MediaGrouping._();

  static List<MediaGroup> group(List<String> paths) {
    // 一次解析，避免重复解析同一个路径
    final infos = <int, MediaInfo>{
      for (var i = 0; i < paths.length; i++) i: MediaNamer.parse(paths[i]),
    };

    // key(剧名规范化) → 成员下标；key 不含目录，跨文件夹的同名剧集合成一个列表
    final strong = <String, List<int>>{};
    final weak = <String, List<int>>{};

    for (var i = 0; i < paths.length; i++) {
      final info = infos[i]!;
      if (!info.isEpisode) continue;
      if (!_hasSeriesName(info, paths[i])) continue;
      final key = normalize(info.seriesTitle);
      if (key.isEmpty) continue;
      (info.weakEpisode ? weak : strong).putIfAbsent(key, () => []).add(i);
    }

    int orderOf(int i) {
      final info = infos[i]!;
      return (info.season != null ? (info.season! + 1) * 100000 : 0) +
          (info.episode ?? 0) * 10;
    }

    final groups = <MediaGroup>[];

    // ── 明确标记：一集也成列表 ──
    strong.forEach((key, members) {
      members.sort((a, b) => orderOf(a).compareTo(orderOf(b)));
      groups.add(MediaGroup(
        name: infos[members.first]!.seriesTitle,
        indices: members,
      ));
    });

    // ── 末尾序号（弱标记）：要有同类聚集（≥2 个不同集数）才认 ──
    weak.forEach((key, members) {
      final eps = members.map((i) => infos[i]!.episode).toSet();
      if (eps.length < 2) return;
      members.sort((a, b) => orderOf(a).compareTo(orderOf(b)));
      groups.add(MediaGroup(
        name: infos[members.first]!.seriesTitle,
        indices: members,
      ));
    });

    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  /// 剧名规范化：用于跨目录合并同一个剧集（忽略大小写与分隔符差异）
  static String normalize(String title) =>
      title.toLowerCase().replaceAll(RegExp(r'[\s._\-]+'), '').trim();

  /// 文件名里是否真的给出了剧名（而不是只有编号）
  static bool _hasSeriesName(MediaInfo info, String path) {
    final name = info.seriesTitle.trim();
    if (name.isEmpty) return false;
    if (RegExp(r'^\d+$').hasMatch(name)) return false;
    final base = p.basenameWithoutExtension(path).trim();
    // 去掉标记后剩下的就是编号本身 → 没有剧名
    if (name.toLowerCase() == base.toLowerCase()) return false;
    return true;
  }
}
