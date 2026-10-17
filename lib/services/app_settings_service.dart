import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_model.dart';
import '../models/video_model.dart';
import 'library_hidden_service.dart';
import 'media_grouping_service.dart';
import 'subtitle_matcher.dart';
import 'video_source_service.dart';

/// 应用设置持久化服务
///
/// 所有播放/界面设置统一通过 SharedPreferences 持久化，
/// 播放器通过 [AppSettingsService.instance] 读取实际生效值。
class AppSettingsService {
  AppSettingsService._();
  static final instance = AppSettingsService._();

  static const _kDefaultSpeed = 'settings.defaultSpeed';
  static const _kLongPressSpeed = 'settings.longPressSpeed';
  static const _kSkipSeconds = 'settings.skipSeconds';
  static const _kAutoPlayNext = 'settings.autoPlayNext';
  static const _kBackgroundPlay = 'settings.backgroundPlay';
  static const _kHardwareDecoding = 'settings.hardwareDecoding';
  static const _kAllFilesPrompted = 'settings.allFilesPrompted';
  static const _kGlassBlur = 'settings.glassBlur';
  static const _kGlassBlurV2 = 'settings.glassBlurV2';
  static const _kTmdbApiKey = 'settings.tmdbApiKey';
  static const _kLibrarySort = 'settings.librarySort';
  static const _kLibraryFilter = 'settings.libraryFilter';

  double _defaultSpeed = 1.0;

  /// 长按视频画面时的临时倍速（松手恢复原速），默认 2.0x
  double _longPressSpeed = 2.0;

  int _skipSeconds = 10;
  bool _autoPlayNext = true;
  bool _backgroundPlay = true;
  bool _hardwareDecoding = true;
  bool _loaded = false;

  double get defaultSpeed => _defaultSpeed;

  /// 长按画面时的临时倍速（松手恢复原速）
  double get longPressSpeed => _longPressSpeed;

  int get skipSeconds => _skipSeconds;
  bool get autoPlayNext => _autoPlayNext;
  bool get backgroundPlay => _backgroundPlay;

  /// 硬件解码（默认开启；关闭则用软解，兼容花屏/黑屏的机型）
  bool get hardwareDecoding => _hardwareDecoding;

  /// 是否已经引导过「所有文件访问权限」（只自动跳一次，避免反复打扰）
  bool _allFilesPrompted = false;
  bool get allFilesPrompted => _allFilesPrompted;

  /// 毛玻璃实时模糊（液态玻璃观感的核心）
  ///
  /// **默认开启**：效果优先。性能问题用真实优化解决（重建范围收敛、
  /// RepaintBoundary、动画改用 FadeTransition 等），不靠关特效。
  /// 低端机可以在设置里关掉以省电/防发热。
  bool _glassBlur = true;
  bool get glassBlur => _glassBlur;

  /// TMDB API Key（用于刮削电影/电视剧海报与元数据）
  ///
  /// 留空 = 不启用刮削。去 https://www.themoviedb.org/settings/api
  /// 免费注册即可拿到 key。
  String _tmdbApiKey = '';
  String get tmdbApiKey => _tmdbApiKey;

  /// 影库列表的排序方式（LibrarySort.id，默认按名称）
  String _librarySort = 'name';
  String get librarySort => _librarySort;

  /// 影库列表的筛选方式（LibraryFilter.id，默认全部）
  String _libraryFilter = 'all';
  String get libraryFilter => _libraryFilter;

  /// 每个视频「上次选了什么外挂字幕」
  ///
  /// 为什么放这里：SharedPreferences 的读写统一收敛在这个单例，播放器不用关心
  /// 持久化细节。键格式、最近使用排序、条数上限（[SubtitleMemory.maxEntries]）
  /// 全在 [SubtitleMemory] 里 —— 那个类是纯逻辑，能直接单测淘汰规则。
  ///
  /// 存成 StringList（每行一条 JSON），而不是一个大 JSON 字符串：
  /// 单条坏掉时只丢那一条，不会整份记忆都读不出来。
  static const _kSubtitleMemory = 'settings.subtitleMemory';
  List<SubtitleMemory> _subtitleMemory = const <SubtitleMemory>[];

  /// 用户手动删掉的「自动列表」id
  ///
  /// 自动列表是每次扫描后重建的，如果只删数据库记录，下次扫描就长回来，
  /// 所以这里记住用户的删除意图，重建时跳过这些 id。
  static const _kHiddenAutoPlaylists = 'settings.hiddenAutoPlaylists';
  Set<String> _hiddenAutoPlaylists = <String>{};
  Set<String> get hiddenAutoPlaylists => _hiddenAutoPlaylists;
  bool isAutoPlaylistHidden(String id) => _hiddenAutoPlaylists.contains(id);

  /// 被「仅从影库移除（保留文件）」移出去的视频路径
  ///
  /// 为什么必须记下来：只删数据库记录的话，下次全盘扫描会把磁盘上还在的
  /// 文件重新写回影库（见 [LibraryHiddenService]）。键/归一化规则都在那个
  /// 纯逻辑类里，这里只负责读写。
  Set<String> _hiddenVideoPaths = <String>{};
  Set<String> get hiddenVideoPaths => _hiddenVideoPaths;

  /// 隐藏了多少个视频（设置页「已隐藏的视频（N 个）」用）
  int get hiddenVideoCount => _hiddenVideoPaths.length;

  /// 用户在「自动列表」里手动加进来 / 手动移出去的视频
  ///
  /// 自动列表每次扫描都会按文件名重建；如果不管用户的增删，手动加进去的会被
  /// 清掉、手动删掉的会长回来（用起来就是"锁死、改不动"）。这里记住差异，
  /// 重建时套用：
  ///   最终成员 =（按文件名算出的成员 − 手动移出）∪ 手动加入
  static const _kAutoAdded = 'settings.autoPlaylistAdded';
  static const _kAutoRemoved = 'settings.autoPlaylistRemoved';
  Set<String> _autoAdded = <String>{};
  Set<String> _autoRemoved = <String>{};

  static String _ovKey(String playlistId, String videoId) =>
      '$playlistId\u0000$videoId';

  static Set<String> _idsFor(Set<String> set, String playlistId) => set
      .where((e) => e.startsWith('$playlistId\u0000'))
      .map((e) => e.substring(playlistId.length + 1))
      .toSet();

  /// 某个自动列表里被用户手动加入的视频 id
  Set<String> autoAddedFor(String playlistId) => _idsFor(_autoAdded, playlistId);

  /// 某个自动列表里被用户手动移除的视频 id
  Set<String> autoRemovedFor(String playlistId) =>
      _idsFor(_autoRemoved, playlistId);

  /// 记录「用户手动加入」
  Future<void> markAutoAdded(String playlistId, String videoId) async {
    _autoAdded.add(_ovKey(playlistId, videoId));
    _autoRemoved.remove(_ovKey(playlistId, videoId));
    await _saveOverlays();
  }

  /// 记录「用户手动移除」
  Future<void> markAutoRemoved(String playlistId, String videoId) async {
    _autoRemoved.add(_ovKey(playlistId, videoId));
    _autoAdded.remove(_ovKey(playlistId, videoId));
    await _saveOverlays();
  }

  Future<void> _saveOverlays() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kAutoAdded, _autoAdded.toList());
      await prefs.setStringList(_kAutoRemoved, _autoRemoved.toList());
    } catch (_) {}
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _defaultSpeed = prefs.getDouble(_kDefaultSpeed) ?? 1.0;
      _longPressSpeed = prefs.getDouble(_kLongPressSpeed) ?? 2.0;
      _skipSeconds = prefs.getInt(_kSkipSeconds) ?? 10;
      _autoPlayNext = prefs.getBool(_kAutoPlayNext) ?? true;
      _backgroundPlay = prefs.getBool(_kBackgroundPlay) ?? true;
      _hardwareDecoding = prefs.getBool(_kHardwareDecoding) ?? true;
      _allFilesPrompted = prefs.getBool(_kAllFilesPrompted) ?? false;
      // 用 v2 键：早期版本 Android 默认关闭时可能写入了 false，
      // 那些残留值会把新默认值（开启）盖掉，看起来像"开关没用/默认关闭"
      if (prefs.containsKey(_kGlassBlurV2)) {
        _glassBlur = prefs.getBool(_kGlassBlurV2) ?? true;
      } else {
        _glassBlur = true;
        await prefs.remove(_kGlassBlur); // 清掉旧键，避免继续误导
      }
      _hiddenAutoPlaylists =
          (prefs.getStringList(_kHiddenAutoPlaylists) ?? const <String>[])
              .toSet();
      _hiddenVideoPaths = LibraryHiddenService.normalizeAll(
          prefs.getStringList(LibraryHiddenService.prefsKey) ??
              const <String>[]);
      _autoAdded =
          (prefs.getStringList(_kAutoAdded) ?? const <String>[]).toSet();
      _autoRemoved =
          (prefs.getStringList(_kAutoRemoved) ?? const <String>[]).toSet();
      _tmdbApiKey = prefs.getString(_kTmdbApiKey) ?? '';
      _librarySort = prefs.getString(_kLibrarySort) ?? 'name';
      _libraryFilter = prefs.getString(_kLibraryFilter) ?? 'all';
      _subtitleMemory = _decodeSubtitleMemory(
          prefs.getStringList(_kSubtitleMemory) ?? const <String>[]);
    } catch (_) {
      // 读取失败时保留默认值
    }
    _loaded = true;
  }

  Future<void> setLibrarySort(String value) async {
    _librarySort = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLibrarySort, value);
    } catch (_) {}
  }

  Future<void> setLibraryFilter(String value) async {
    _libraryFilter = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLibraryFilter, value);
    } catch (_) {}
  }

  // ═══════════════ 外挂字幕记忆 ═══════════════

  /// 当前全部字幕记忆（最近使用的在最前）
  List<SubtitleMemory> get subtitleMemory => _subtitleMemory;

  /// 查这个视频上次选了什么字幕；没记录返回 null
  ///
  /// 键统一归一化（[LibraryHiddenService.normalizePath]）：Windows 路径大小写
  /// 不敏感，`D:\A\b.mp4` 和 `d:\a\B.mp4` 是同一个文件，不归一化会记成两条，
  /// 记忆时好时坏。
  SubtitleMemory? subtitleMemoryFor(String videoPath) {
    final key = LibraryHiddenService.normalizePath(videoPath);
    if (key.isEmpty) return null;
    return SubtitleMemory.find(_subtitleMemory, key);
  }

  /// 记住某个视频「上次选的字幕」
  ///
  /// [subtitlePath] 为 null 表示用户手动关掉了字幕：下次打开这个视频不要再自动挂。
  /// 覆盖 + 淘汰规则见 [SubtitleMemory.upsert]（最近使用优先，最多 300 条）。
  Future<void> rememberSubtitle(String videoPath, String? subtitlePath) async {
    final key = LibraryHiddenService.normalizePath(videoPath);
    if (key.isEmpty) return;
    _subtitleMemory = SubtitleMemory.upsert(
      _subtitleMemory,
      SubtitleMemory(
        videoPath: key,
        subtitlePath: subtitlePath,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kSubtitleMemory,
        [for (final entry in _subtitleMemory) entry.encode()],
      );
    } catch (_) {}
  }

  /// 清空字幕记忆（设置项复位 / 单测用）
  ///
  /// 不给出口的话，用户手动选错一次就会一直被自动挂上，没法回到「自动挑选」。
  Future<void> clearSubtitleMemory() async {
    _subtitleMemory = const <SubtitleMemory>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSubtitleMemory);
    } catch (_) {}
  }

  /// 解析存储的 StringList
  ///
  /// 先按时间倒序再按视频去重：老版本/手工写入的数据不保证顺序，
  /// 去重必须保留「最新的那条」，否则会恢复到上上次的选择。
  static List<SubtitleMemory> _decodeSubtitleMemory(List<String> raw) {
    final parsed = <SubtitleMemory>[];
    for (final line in raw) {
      final entry = SubtitleMemory.tryDecode(line);
      if (entry != null) parsed.add(entry);
    }
    parsed.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final out = <SubtitleMemory>[];
    final seen = <String>{};
    for (final entry in parsed) {
      if (!seen.add(entry.videoPath)) continue;
      out.add(entry);
      if (out.length >= SubtitleMemory.maxEntries) break;
    }
    return out;
  }

  Future<void> setDefaultSpeed(double value) async {
    _defaultSpeed = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kDefaultSpeed, value);
    } catch (_) {}
  }

  Future<void> setLongPressSpeed(double value) async {
    _longPressSpeed = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kLongPressSpeed, value);
    } catch (_) {}
  }

  Future<void> setSkipSeconds(int value) async {
    _skipSeconds = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSkipSeconds, value);
    } catch (_) {}
  }

  Future<void> setAutoPlayNext(bool value) async {
    _autoPlayNext = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoPlayNext, value);
    } catch (_) {}
  }

  Future<void> setBackgroundPlay(bool value) async {
    _backgroundPlay = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBackgroundPlay, value);
    } catch (_) {}
  }

  Future<void> setHardwareDecoding(bool value) async {
    _hardwareDecoding = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHardwareDecoding, value);
    } catch (_) {}
  }

  /// 记住「这个自动列表被用户删了」，重建时不再生成
  Future<void> hideAutoPlaylist(String id) async {
    _hiddenAutoPlaylists.add(id);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _kHiddenAutoPlaylists, _hiddenAutoPlaylists.toList());
    } catch (_) {}
  }

  /// 记住「这个文件的路径被用户从影库移除了」（保留磁盘文件）
  Future<void> hideVideoPath(String path) async {
    final normalized = LibraryHiddenService.normalizePath(path);
    if (normalized.isEmpty) return;
    _hiddenVideoPaths.add(normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          LibraryHiddenService.prefsKey, _hiddenVideoPaths.toList());
    } catch (_) {}
  }

  /// 清空隐藏名单（设置页「全部恢复」）
  ///
  /// 清空后下次扫描会把这些文件重新写回影库；不提供这个出口的话，
  /// 用户误点一次「仅从影库移除」就永远找不回来了。
  Future<void> restoreHiddenVideos() async {
    _hiddenVideoPaths = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(LibraryHiddenService.prefsKey);
    } catch (_) {}
  }

  /// 恢复所有被删掉的自动列表（下次扫描重建）
  Future<void> restoreAutoPlaylists() async {
    _hiddenAutoPlaylists = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kHiddenAutoPlaylists);
    } catch (_) {}
  }

  /// 清掉「手动加入 / 手动移出」的记忆（设置里恢复默认用；单测也用它复位）
  ///
  /// 不清的话这些记录会一直累积，用户在界面里再也没有"回到自动分组"的办法。
  Future<void> clearAutoOverlays() async {
    _autoAdded = <String>{};
    _autoRemoved = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAutoAdded);
      await prefs.remove(_kAutoRemoved);
    } catch (_) {}
  }

  /// 把「按文件名（+刮削修正）算出的分组」变成最终的自动列表。
  ///
  /// 放在这里而不是 notifier 里，是因为这层规则完全由本服务的状态决定
  /// （隐藏 / 手动加 / 手动移出），而且它是纯函数 —— 没有数据库依赖，
  /// 可以直接写单测钉住"重建不会冲掉用户的手动增删"。
  ///
  /// 规则（原有行为，别改）：
  ///   最终成员 =（分组内成员 − 手动移出）∪（手动加入 ∩ 库里还有 − 手动移出）
  ///   列表为空就不生成（某个视频从剧集挪到电影后，旧剧集组空了要能消失）
  ///   被删掉的列表（[isAutoPlaylistHidden]）直接跳过
  List<Playlist> applyAutoOverrides(
    List<SourceGroup> groups,
    List<VideoModel> videos,
  ) {
    final existingVidIds = videos.map((v) => v.id).toSet();
    final auto = <Playlist>[];

    // 自动列表按类型排：电影 → 剧集 → 其它（兜底分组 / 个人来源这类杂项）。
    // 这里用「按优先级分桶再拼接」而不是 List.sort：Dart 的 sort 不稳定，
    // 直接按优先级排序会打乱同类型内 groupAll 的原始相对顺序。
    final ordered = <SourceGroup>[
      for (final g in groups)
        if (g.kindPriority == 0) g,
      for (final g in groups)
        if (g.kindPriority == 1) g,
      for (final g in groups)
        if (g.kindPriority == 2) g,
    ];

    // 从 -1000 起递增：负数编号保证自动列表整体排在手动列表
    // （sortOrder 默认 0）**之前**，两者不会交错；分组数远小于 1000，
    // 不会溢出到非负数去占手动列表的位置。
    var order = -1000;

    for (final g in ordered) {
      final kind = g.isSeries
          ? 'series'
          : g.isMovie
              ? 'movie'
              : g.isFallback
                  ? 'fallback'
                  : 'personal';
      final id = 'auto:$kind:${MediaGrouping.normalize(g.name)}';
      if (isAutoPlaylistHidden(id)) continue;

      final removed = autoRemovedFor(id);
      final added = autoAddedFor(id);

      final ids = <String>{
        for (final i in g.indices)
          if (i >= 0 && i < videos.length && !removed.contains(videos[i].id))
            videos[i].id,
        for (final vid in added)
          if (existingVidIds.contains(vid) && !removed.contains(vid)) vid,
      }.toList();

      if (ids.isEmpty) continue;

      auto.add(Playlist(
        id: id,
        name: g.name,
        videoIds: ids,
        createdAt: DateTime.now(),
        sortOrder: order++,
        isAuto: true,
      ));
    }

    return auto;
  }

  Future<void> setAllFilesPrompted(bool value) async {
    _allFilesPrompted = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAllFilesPrompted, value);
    } catch (_) {}
  }

  Future<void> setGlassBlur(bool value) async {
    _glassBlur = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGlassBlurV2, value);
    } catch (_) {}
  }

  Future<void> setTmdbApiKey(String value) async {
    _tmdbApiKey = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTmdbApiKey, value);
    } catch (_) {}
  }
}