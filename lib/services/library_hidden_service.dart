import '../models/video_model.dart';

/// 影库「隐藏名单」的纯逻辑
///
/// 为什么需要这份名单：用户点「仅从影库移除（保留文件）」时，如果只删数据库
/// 记录，下次全盘扫描会把**磁盘上还在的文件**重新写回影库 —— 用户删了个寂寞。
/// 所以移除时把路径记进名单（持久化在 `AppSettingsService.hiddenVideoPaths`），
/// 扫描结果统一按名单过滤一遍。
///
/// 这里只放不依赖 IO / SharedPreferences 的判断，才能在纯 Dart 单测里钉住
/// 「给定路径集合 + 隐藏名单 → 过滤结果」（名单的读写交给设置服务）。
class LibraryHiddenService {
  LibraryHiddenService._();

  /// SharedPreferences 里的键（集合型偏好项，写成 StringList）
  static const prefsKey = 'settings.hiddenVideoPaths';

  /// 路径归一化
  ///
  /// 两个原因：
  ///  1. 首尾空白：从界面/配置粘贴进来的路径偶尔带空格，不裁就永远匹配不上；
  ///  2. Windows 盘符/路径大小写不敏感：`C:\Movies\A.mp4` 和 `c:\movies\a.mp4`
  ///     是同一个文件，不统一大小写会记成两条，隐藏了又"回来"。
  ///     Android 的路径区分大小写，不能一律转小写。
  static String normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    return _isWindowsStyle(trimmed) ? trimmed.toLowerCase() : trimmed;
  }

  /// 是否 Windows 风格路径（盘符开头或 UNC `\\server\share`）
  static bool _isWindowsStyle(String path) =>
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');

  /// 批量归一化（同时丢掉空串）
  static Set<String> normalizeAll(Iterable<String> paths) {
    final out = <String>{};
    for (final path in paths) {
      final normalized = normalizePath(path);
      if (normalized.isNotEmpty) out.add(normalized);
    }
    return out;
  }

  /// 这个路径是否在隐藏名单里
  static bool isHidden(String path, Set<String> hiddenPaths) {
    if (hiddenPaths.isEmpty) return false;
    return hiddenPaths.contains(normalizePath(path));
  }

  /// 把扫描结果拆成「保留」和「命中隐藏名单」两部分
  ///
  /// 为什么返回剔除项而不只返回保留项：扫描器还要顺手清掉命中项可能残留的
  /// 数据库记录（隐藏名单写成功、删库那一步失败时，卡片会一直挂在首页）。
  static ({List<VideoModel> kept, List<VideoModel> dropped}) split(
    List<VideoModel> videos,
    Set<String> hiddenPaths,
  ) {
    if (hiddenPaths.isEmpty) {
      return (kept: videos, dropped: const <VideoModel>[]);
    }
    // 名单本身也归一化一次：老版本/手工写入的名单可能没归一化过
    final hidden = normalizeAll(hiddenPaths);
    final kept = <VideoModel>[];
    final dropped = <VideoModel>[];
    for (final video in videos) {
      if (hidden.contains(normalizePath(video.path))) {
        dropped.add(video);
      } else {
        kept.add(video);
      }
    }
    return (kept: kept, dropped: dropped);
  }
}
