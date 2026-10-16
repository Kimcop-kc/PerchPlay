import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置持久化服务
///
/// 所有播放/界面设置统一通过 SharedPreferences 持久化，
/// 播放器通过 [AppSettingsService.instance] 读取实际生效值。
class AppSettingsService {
  AppSettingsService._();
  static final instance = AppSettingsService._();

  static const _kDefaultSpeed = 'settings.defaultSpeed';
  static const _kSkipSeconds = 'settings.skipSeconds';
  static const _kAutoPlayNext = 'settings.autoPlayNext';
  static const _kBackgroundPlay = 'settings.backgroundPlay';
  static const _kHardwareDecoding = 'settings.hardwareDecoding';
  static const _kAllFilesPrompted = 'settings.allFilesPrompted';
  static const _kGlassBlur = 'settings.glassBlur';
  static const _kGlassBlurV2 = 'settings.glassBlurV2';
  static const _kTmdbApiKey = 'settings.tmdbApiKey';

  double _defaultSpeed = 1.0;
  int _skipSeconds = 10;
  bool _autoPlayNext = true;
  bool _backgroundPlay = true;
  bool _hardwareDecoding = true;
  bool _loaded = false;

  double get defaultSpeed => _defaultSpeed;
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

  /// 用户手动删掉的「自动列表」id
  ///
  /// 自动列表是每次扫描后重建的，如果只删数据库记录，下次扫描就长回来，
  /// 所以这里记住用户的删除意图，重建时跳过这些 id。
  static const _kHiddenAutoPlaylists = 'settings.hiddenAutoPlaylists';
  Set<String> _hiddenAutoPlaylists = <String>{};
  Set<String> get hiddenAutoPlaylists => _hiddenAutoPlaylists;
  bool isAutoPlaylistHidden(String id) => _hiddenAutoPlaylists.contains(id);

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
      _autoAdded =
          (prefs.getStringList(_kAutoAdded) ?? const <String>[]).toSet();
      _autoRemoved =
          (prefs.getStringList(_kAutoRemoved) ?? const <String>[]).toSet();
      _tmdbApiKey = prefs.getString(_kTmdbApiKey) ?? '';
    } catch (_) {
      // 读取失败时保留默认值
    }
    _loaded = true;
  }

  Future<void> setDefaultSpeed(double value) async {
    _defaultSpeed = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kDefaultSpeed, value);
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

  /// 恢复所有被删掉的自动列表（下次扫描重建）
  Future<void> restoreAutoPlaylists() async {
    _hiddenAutoPlaylists = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kHiddenAutoPlaylists);
    } catch (_) {}
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