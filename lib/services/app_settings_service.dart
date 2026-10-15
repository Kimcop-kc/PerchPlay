import 'dart:io' show Platform;
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

  /// 毛玻璃实时模糊
  ///
  /// Android 上导航栏背后的内容一直在滚动，实时模糊每帧都要重算，
  /// 是发热/掉帧的主要来源之一，因此默认关闭（保留半透明玻璃观感）。
  /// iOS 的合成效率高，默认开启。
  bool _glassBlur = !Platform.isAndroid;
  bool get glassBlur => _glassBlur;

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
      _glassBlur = prefs.getBool(_kGlassBlur) ?? !Platform.isAndroid;
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
      await prefs.setBool(_kGlassBlur, value);
    } catch (_) {}
  }
}