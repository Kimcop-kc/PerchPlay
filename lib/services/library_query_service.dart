import '../models/video_model.dart';

/// 影库排序方式
enum LibrarySort {
  name('name', '名称'),
  dateModified('dateModified', '最近修改'),
  dateAdded('dateAdded', '加入时间'),
  duration('duration', '时长'),
  size('size', '文件大小');

  const LibrarySort(this.id, this.label);
  final String id;
  final String label;

  static LibrarySort fromId(String? id) => LibrarySort.values.firstWhere(
        (e) => e.id == id,
        orElse: () => LibrarySort.name,
      );
}

/// 影库筛选方式
enum LibraryFilter {
  all('all', '全部'),
  favorite('favorite', '只看收藏'),
  unwatched('unwatched', '未看完');

  const LibraryFilter(this.id, this.label);
  final String id;
  final String label;

  static LibraryFilter fromId(String? id) => LibraryFilter.values.firstWhere(
        (e) => e.id == id,
        orElse: () => LibraryFilter.all,
      );
}

/// 影库列表的搜索 / 排序 / 筛选
///
/// 故意做成不依赖 Flutter 的纯函数，方便单测（UI 只负责把结果铺出来）。
class LibraryQuery {
  LibraryQuery._();

  /// 判为「已看完」的进度比例：>= 95% 视为看完
  static const double watchedThreshold = 0.95;

  static bool isUnwatched(VideoModel v) {
    if (v.durationMs <= 0) return false;
    return v.lastPosition / v.durationMs < watchedThreshold;
  }

  /// 是否命中搜索词：文件名或所在目录任一包含即可（大小写不敏感）
  static bool matches(VideoModel v, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (v.name.toLowerCase().contains(q)) return true;
    return v.folderPath.toLowerCase().contains(q);
  }

  static bool passesFilter(VideoModel v, LibraryFilter filter) {
    switch (filter) {
      case LibraryFilter.all:
        return true;
      case LibraryFilter.favorite:
        return v.isFavorite;
      case LibraryFilter.unwatched:
        return isUnwatched(v);
    }
  }

  /// 过滤 + 排序；返回新列表，不改动入参
  static List<VideoModel> apply(
    List<VideoModel> videos, {
    String query = '',
    LibrarySort sort = LibrarySort.name,
    LibraryFilter filter = LibraryFilter.all,
  }) {
    final result = [
      for (final v in videos)
        if (passesFilter(v, filter) && matches(v, query)) v,
    ];
    sortInPlace(result, sort);
    return result;
  }

  /// 按 [sort] 原地排序
  static void sortInPlace(List<VideoModel> videos, LibrarySort sort) {
    switch (sort) {
      case LibrarySort.name:
        // 自然一点：忽略大小写，数字按数值比较（第 2 集排在 第 10 集前）
        videos.sort((a, b) => compareNatural(a.name, b.name));
        break;
      case LibrarySort.dateModified:
        videos.sort((a, b) => b.dateModified.compareTo(a.dateModified));
        break;
      case LibrarySort.dateAdded:
        videos.sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
        break;
      case LibrarySort.duration:
        videos.sort((a, b) => b.durationMs.compareTo(a.durationMs));
        break;
      case LibrarySort.size:
        videos.sort((a, b) => b.size.compareTo(a.size));
        break;
    }
  }

  /// 大小写不敏感 + 数字段按数值比较的自然排序
  static int compareNatural(String a, String b) {
    final ra = _split(a);
    final rb = _split(b);
    for (var i = 0; i < ra.length && i < rb.length; i++) {
      final x = ra[i];
      final y = rb[i];
      final nx = int.tryParse(x);
      final ny = int.tryParse(y);
      int cmp;
      if (nx != null && ny != null) {
        cmp = nx.compareTo(ny);
      } else {
        cmp = x.toLowerCase().compareTo(y.toLowerCase());
      }
      if (cmp != 0) return cmp;
    }
    return ra.length.compareTo(rb.length);
  }

  /// 切成「文字段 / 数字段」交替的片段
  static List<String> _split(String s) {
    final out = <String>[];
    final buf = StringBuffer();
    bool? lastWasDigit;
    for (final ch in s.split('')) {
      final isDigit = RegExp(r'\d').hasMatch(ch);
      if (lastWasDigit != null && isDigit != lastWasDigit) {
        out.add(buf.toString());
        buf.clear();
      }
      buf.write(ch);
      lastWasDigit = isDigit;
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out.where((e) => e.isNotEmpty).toList();
  }
}
