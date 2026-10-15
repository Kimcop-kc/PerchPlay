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

  /// 用户手动删掉的「自动列表」id
  ///
  /// 自动列表是每次扫描后重建的，如果只删数据库记录，下次扫描就长回来，
  /// 所以这里记住用户的删除意图，重建时跳过这些 id。
  static const _kHiddenAutoPlaylists = 'settings.hiddenAutoPlaylists';
  Set<String> _hiddenAutoPlaylists = <String>{};
  Set<String> get hiddenAutoPlaylists => _hiddenAutoPlaylists;
  bool isAutoPlaylistHidden(String id) => _hiddenAutoPlaylists.contains(id);

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
}