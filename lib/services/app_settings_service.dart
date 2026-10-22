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
  static const _kPlayerOrientation = 'settings.playerOrientation';
  static const _kAllFilesPrompted = 'settings.allFilesPrompted';
  static const _kGlassBlur = 'settings.glassBlur';
  static const _kGlassBlurV2 = 'settings.glassBlurV2';
  static const _kTmdbApiKey = 'settings.tmdbApiKey';
  static const _kLibrarySort = 'settings.librarySort';
  static const _kLibraryFilter = 'settings.libraryFilter';

  // 字幕外观
  static const _kSubtitleFontSize = 'settings.subtitle.fontSize';
  static const _kSubtitleBgOpacity = 'settings.subtitle.bgOpacity';
  static const _kSubtitleTextColor = 'settings.subtitle.textColor';
  static const _kSubtitleStroke = 'settings.subtitle.stroke';
  static const _kSubtitlePosition = 'settings.subtitle.position';
  static const _kSubtitleSecondaryScale = 'settings.subtitle.secondaryScale';
  static const _kSubtitleSecondaryDim = 'settings.subtitle.secondaryDim';
  static const _kSubtitleFontFamily = 'settings.subtitle.fontFamily';
  static const _kSubtitleFontWeight = 'settings.subtitle.fontWeight';
  static const _kSubtitleLineSpacing = 'settings.subtitle.lineSpacing';
  static const _kSubtitleLineHeight = 'settings.subtitle.lineHeight';
  static const _kSubtitleBgRadius = 'settings.subtitle.bgRadius';
  static const _kSubtitleBgColor = 'settings.subtitle.bgColor';
  static const _kSubtitleShowBg = 'settings.subtitle.showBg';
  static const _kSubtitleAlign = 'settings.subtitle.align';
  static const _kSubtitleUseAssPos = 'settings.subtitle.useAssPosition';

  double _defaultSpeed = 1.0;

  /// 长按视频画面时的临时倍速（松手恢复原速），默认 2.0x
  double _longPressSpeed = 2.0;

  int _skipSeconds = 10;
  bool _autoPlayNext = true;
  bool _backgroundPlay = true;
  bool _hardwareDecoding = true;

  /// 打开视频时的屏幕方向：'auto'（跟随手机）| 'landscape'（横屏）| 'portrait'（竖屏）
  String _playerOrientation = 'auto';
  String get playerOrientation => _playerOrientation;
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

  // ─────────── 字幕外观（全部可在设置里调）───────────

  /// 字幕字号（逻辑像素，14~30）。0 = 跟随屏幕自适应（旧行为）。
  double _subtitleFontSize = 0;
  double get subtitleFontSize => _subtitleFontSize;

  /// 字幕黑底不透明度（0 = 无黑底，1 = 全黑）。默认 0.62。
  double _subtitleBgOpacity = 0.62;
  double get subtitleBgOpacity => _subtitleBgOpacity;

  /// 字幕文字颜色（ARGB int）。默认白色。
  ///
  /// 用 int 而不是 Color：本服务是纯数据层，不引入 Flutter UI 依赖。
  int _subtitleTextColor = 0xFFFFFFFF;
  int get subtitleTextColorValue => _subtitleTextColor;

  /// 是否给字幕文字加描边阴影（复杂画面上更清晰）。
  bool _subtitleStroke = true;
  bool get subtitleStroke => _subtitleStroke;

  /// 字幕垂直位置：0.0 = 贴底，1.0 = 屏幕中部偏上。默认 0.12。
  double _subtitlePosition = 0.12;
  double get subtitlePosition => _subtitlePosition;

  /// 双语字幕时，译文相对原文的字号比例（0.5~1.0）。默认 0.82。
  double _subtitleSecondaryScale = 0.82;
  double get subtitleSecondaryScale => _subtitleSecondaryScale;

  /// 双语字幕时译文是否用灰色（弱化，突出原文）。
  bool _subtitleSecondaryDim = true;
  bool get subtitleSecondaryDim => _subtitleSecondaryDim;

  /// 字幕字体族：'system' = 系统默认；其余为内置字体名。默认 'system'。
  String _subtitleFontFamily = 'system';
  String get subtitleFontFamily => _subtitleFontFamily;

  /// 字幕字体粗细（FontWeight 索引 3~8，即 w300~w800）。默认 5（w500）。
  int _subtitleFontWeight = 5;
  int get subtitleFontWeight => _subtitleFontWeight;

  /// 双语文两行之间的间距（逻辑像素，0~12）。默认 3。
  double _subtitleLineSpacing = 3;
  double get subtitleLineSpacing => _subtitleLineSpacing;

  /// 字幕行高（TextStyle.height，1.0~1.8）。默认 1.35。
  double _subtitleLineHeight = 1.35;
  double get subtitleLineHeight => _subtitleLineHeight;

  /// 字幕背景圆角（逻辑像素，0~12）。默认 4。
  double _subtitleBgRadius = 4;
  double get subtitleBgRadius => _subtitleBgRadius;

  /// 字幕背景色（ARGB int）。默认黑色。
  int _subtitleBgColor = 0xFF000000;
  int get subtitleBgColorValue => _subtitleBgColor;

  /// 是否显示字幕黑底。默认 true。
  bool _subtitleShowBg = true;
  bool get subtitleShowBg => _subtitleShowBg;

  /// 字幕对齐方式：'center' | 'start' | 'end'。默认 'center'。
  String _subtitleAlign = 'center';
  String get subtitleAlign => _subtitleAlign;

  /// 是否应用 ASS 定位/对齐（垂直位置 + numpad 对齐）。默认 true。
  bool _subtitleUseAssPosition = true;
  bool get subtitleUseAssPosition => _subtitleUseAssPosition;

  /// 【已废弃】字幕统一由 Flutter 渲染，mpv/libass 原生渲染已移除。
  ///
  /// 保留此 getter 仅为兼容旧代码/旧设置键，恒返回 false。
  /// 不再持久化，历史设置值自动忽略。
  bool get subtitleNativeAss => false;

  /// 每个视频「上次选了什么字幕」（外挂文件 / 内嵌轨 / 关掉，三态）
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
  Set<String> autoAddedFor(String playlistId) =>
      _idsFor(_autoAdded, playlistId);

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
      _playerOrientation = prefs.getString(_kPlayerOrientation) ?? 'auto';
      _allFilesPrompted = prefs.getBool(_kAllFilesPrompted) ?? false;
      // 用 v2 键：早期版本 Android 默认关闭时可能写入了 false，
      // 那些残留值会把新默认值（开启）盖掉，看起来像"开关没用/默认关闭"
      if (prefs.containsKey(_kGlassBlurV2)) {
        _glassBlur = prefs.getBool(_kGlassBlurV2) ?? true;
      } else {
        _glassBlur = true;
        await prefs.remove(_kGlassBlur); // 清掉旧键，避免继续误导
      }

      // 字幕外观
      _subtitleFontSize =
          (prefs.getDouble(_kSubtitleFontSize) ?? 0).clamp(0, 30);
      _subtitleBgOpacity =
          (prefs.getDouble(_kSubtitleBgOpacity) ?? 0.62).clamp(0.0, 1.0);
      _subtitleTextColor = prefs.getInt(_kSubtitleTextColor) ?? 0xFFFFFFFF;
      _subtitleStroke = prefs.getBool(_kSubtitleStroke) ?? true;
      _subtitlePosition =
          (prefs.getDouble(_kSubtitlePosition) ?? 0.12).clamp(0.0, 0.6);
      _subtitleSecondaryScale =
          (prefs.getDouble(_kSubtitleSecondaryScale) ?? 0.82).clamp(0.5, 1.0);
      _subtitleSecondaryDim = prefs.getBool(_kSubtitleSecondaryDim) ?? true;
      _subtitleFontFamily = prefs.getString(_kSubtitleFontFamily) ?? 'system';
      _subtitleFontWeight =
          (prefs.getInt(_kSubtitleFontWeight) ?? 5).clamp(3, 8);
      _subtitleLineSpacing =
          (prefs.getDouble(_kSubtitleLineSpacing) ?? 3).clamp(0, 12);
      _subtitleLineHeight =
          (prefs.getDouble(_kSubtitleLineHeight) ?? 1.35).clamp(1.0, 1.8);
      _subtitleBgRadius =
          (prefs.getDouble(_kSubtitleBgRadius) ?? 4).clamp(0, 12);
      _subtitleBgColor = prefs.getInt(_kSubtitleBgColor) ?? 0xFF000000;
      _subtitleShowBg = prefs.getBool(_kSubtitleShowBg) ?? true;
      _subtitleAlign = prefs.getString(_kSubtitleAlign) ?? 'center';
      _subtitleUseAssPosition = prefs.getBool(_kSubtitleUseAssPos) ?? true;
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

  // ═══════════════ 字幕记忆（外挂 / 内嵌 / 关掉） ═══════════════

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

  /// 记住某个视频「上次选的外挂字幕」
  ///
  /// [subtitlePath] 为 null 表示用户手动关掉了字幕：下次打开这个视频不要再自动挂。
  /// 覆盖 + 淘汰规则见 [SubtitleMemory.upsert]（最近使用优先，最多 300 条）。
  Future<void> rememberSubtitle(String videoPath, String? subtitlePath) async {
    final key = LibraryHiddenService.normalizePath(videoPath);
    if (key.isEmpty) return;
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _storeSubtitleMemory(
      subtitlePath == null
          ? SubtitleMemory.off(videoPath: key, updatedAt: updatedAt)
          : SubtitleMemory.external(
              videoPath: key,
              subtitlePath: subtitlePath,
              updatedAt: updatedAt,
            ),
    );
  }

  /// 记住某个视频「上次选的内嵌字幕轨」
  ///
  /// 内嵌轨用 mpv 的 track id 恢复（同一文件每次打开 id 稳定）；
  /// 换文件/id 对不上时由 [Subtitles.pick] 判定记忆失效并回落到自动逻辑。
  Future<void> rememberEmbeddedSubtitle(
    String videoPath,
    String trackId, {
    String? language,
  }) async {
    final key = LibraryHiddenService.normalizePath(videoPath);
    if (key.isEmpty || trackId.isEmpty) return;
    await _storeSubtitleMemory(
      SubtitleMemory.embedded(
        videoPath: key,
        trackId: trackId,
        language: language,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 刷新某条记忆的「最近使用」时间（打开视频命中记忆时调用）
  ///
  /// 淘汰按最近使用来的：只在"手动改选"时更新时间的话，常看的片子会被
  /// 后来选过字幕的其它片子挤出上限，明明一直在看却丢了记忆。
  Future<void> touchSubtitleMemory(SubtitleMemory memory) =>
      _storeSubtitleMemory(
        memory.touch(DateTime.now().millisecondsSinceEpoch),
      );

  /// 写入一条记忆并落盘（同一视频覆盖旧记录）
  Future<void> _storeSubtitleMemory(SubtitleMemory entry) async {
    _subtitleMemory = SubtitleMemory.upsert(_subtitleMemory, entry);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kSubtitleMemory,
        [for (final memory in _subtitleMemory) memory.encode()],
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

  Future<void> setPlayerOrientation(String value) async {
    _playerOrientation = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPlayerOrientation, value);
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
    // 已存在就不重复写：避免同一视频被隐藏两次时反复落盘，
    // 也保证「已隐藏的视频（N 个）」计数不会因为重复操作而虚高。
    if (_hiddenVideoPaths.contains(normalized)) return;
    _hiddenVideoPaths.add(normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          LibraryHiddenService.prefsKey, _hiddenVideoPaths.toList());
    } catch (_) {}
  }

  /// 清理隐藏名单里「磁盘上已不存在」的僵尸路径。
  ///
  /// 为什么需要：用户隐藏视频后又删掉/移动了磁盘文件，路径还留在名单里，
  /// 导致设置页「已隐藏的视频（N 个）」虚高、点「全部恢复」后数量对不上。
  /// 这个方法只保留文件仍然存在的路径，返回清理掉的数量。
  Future<int> pruneMissingHiddenVideos(
    Future<bool> Function(String path) exists,
  ) async {
    if (_hiddenVideoPaths.isEmpty) return 0;
    final kept = <String>{};
    var removed = 0;
    for (final path in _hiddenVideoPaths) {
      try {
        if (await exists(path)) {
          kept.add(path);
        } else {
          removed++;
        }
      } catch (_) {
        // 判存在失败（权限/网络源）：保守保留，不误删用户名单
        kept.add(path);
      }
    }
    if (removed == 0) return 0;
    _hiddenVideoPaths = kept;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (kept.isEmpty) {
        await prefs.remove(LibraryHiddenService.prefsKey);
      } else {
        await prefs.setStringList(LibraryHiddenService.prefsKey, kept.toList());
      }
    } catch (_) {}
    return removed;
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

  // ─────────── 字幕外观 setter ───────────

  Future<void> setSubtitleFontSize(double v) async {
    _subtitleFontSize = v.clamp(0, 30);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleFontSize, _subtitleFontSize);
    } catch (_) {}
  }

  Future<void> setSubtitleBgOpacity(double v) async {
    _subtitleBgOpacity = v.clamp(0.0, 1.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleBgOpacity, _subtitleBgOpacity);
    } catch (_) {}
  }

  Future<void> setSubtitleTextColor(int argb) async {
    _subtitleTextColor = argb;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleTextColor, _subtitleTextColor);
    } catch (_) {}
  }

  Future<void> setSubtitleStroke(bool v) async {
    _subtitleStroke = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleStroke, v);
    } catch (_) {}
  }

  Future<void> setSubtitlePosition(double v) async {
    _subtitlePosition = v.clamp(0.0, 0.6);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitlePosition, _subtitlePosition);
    } catch (_) {}
  }

  Future<void> setSubtitleSecondaryScale(double v) async {
    _subtitleSecondaryScale = v.clamp(0.5, 1.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleSecondaryScale, _subtitleSecondaryScale);
    } catch (_) {}
  }

  Future<void> setSubtitleSecondaryDim(bool v) async {
    _subtitleSecondaryDim = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleSecondaryDim, v);
    } catch (_) {}
  }

  Future<void> setSubtitleFontFamily(String v) async {
    _subtitleFontFamily = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSubtitleFontFamily, v);
    } catch (_) {}
  }

  Future<void> setSubtitleFontWeight(int v) async {
    _subtitleFontWeight = v.clamp(3, 8);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleFontWeight, _subtitleFontWeight);
    } catch (_) {}
  }

  Future<void> setSubtitleLineSpacing(double v) async {
    _subtitleLineSpacing = v.clamp(0, 12);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleLineSpacing, _subtitleLineSpacing);
    } catch (_) {}
  }

  Future<void> setSubtitleLineHeight(double v) async {
    _subtitleLineHeight = v.clamp(1.0, 1.8);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleLineHeight, _subtitleLineHeight);
    } catch (_) {}
  }

  Future<void> setSubtitleBgRadius(double v) async {
    _subtitleBgRadius = v.clamp(0, 12);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleBgRadius, _subtitleBgRadius);
    } catch (_) {}
  }

  Future<void> setSubtitleBgColor(int argb) async {
    _subtitleBgColor = argb;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleBgColor, _subtitleBgColor);
    } catch (_) {}
  }

  Future<void> setSubtitleShowBg(bool v) async {
    _subtitleShowBg = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleShowBg, v);
    } catch (_) {}
  }

  Future<void> setSubtitleAlign(String v) async {
    _subtitleAlign = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSubtitleAlign, v);
    } catch (_) {}
  }

  Future<void> setSubtitleUseAssPosition(bool v) async {
    _subtitleUseAssPosition = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleUseAssPos, v);
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
