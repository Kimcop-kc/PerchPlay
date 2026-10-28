import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist_model.dart';
import '../models/video_model.dart';
import 'library_hidden_service.dart';
import 'media_grouping_service.dart';
import 'subtitle_matcher.dart';
import 'video_source_service.dart';

/// 应用设置持久化服务
///
/// **双存储架构**：SharedPreferences + JSON 文件镜像。
/// - SP 是主存储，读写性能好，适合少量键值
/// - JSON 文件每次 setter 调用后在 150ms 内异步落盘（debounce），且 flush 为同步写
/// - 启动时 JSON 文件优先（它的写入更可靠），SP 兜底
/// - App 进入后台时通过 [flush] 立即强制落盘，防止进程被杀丢数据
///
/// 为什么需要双存储：SharedPreferences Android 底层用 `Editor.apply()` 异步写盘，
/// 国产 ROM（小米/华为/OPPO 等）杀进程时未完成的写入直接丢失，导致"改了设置但没保存"。
class AppSettingsService {
  AppSettingsService._();
  static final instance = AppSettingsService._();

  // ─────────── SP 键名 ───────────
  static const _kDefaultSpeed = 'settings.defaultSpeed';
  static const _kLongPressSpeed = 'settings.longPressSpeed';
  static const _kSkipSeconds = 'settings.skipSeconds';
  static const _kAutoPlayNext = 'settings.autoPlayNext';
  static const _kBackgroundPlay = 'settings.backgroundPlay';
  static const _kHardwareDecoding = 'settings.hardwareDecoding';
  static const _kPlayerOrientation = 'settings.playerOrientation';
  static const _kHdrOutputMode = 'settings.hdrOutputMode';
  static const _kAnime4kMode = 'settings.anime4kMode';
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

  // ─────────── 内存字段 ───────────
  double _defaultSpeed = 1.0;
  double _longPressSpeed = 2.0;
  int _skipSeconds = 10;
  bool _autoPlayNext = true;
  bool _backgroundPlay = true;
  bool _hardwareDecoding = true;
  String _playerOrientation = 'auto';
  String _hdrOutputMode = 'off';
  String _anime4kMode = 'off';
  bool _allFilesPrompted = false;
  bool _glassBlur = true;
  String _tmdbApiKey = '';
  String _librarySort = 'name';
  String _libraryFilter = 'all';

  // 字幕外观
  double _subtitleFontSize = 0;
  double _subtitleBgOpacity = 0.62;
  int _subtitleTextColor = 0xFFFFFFFF;
  bool _subtitleStroke = true;
  double _subtitlePosition = 0.12;
  double _subtitleSecondaryScale = 0.82;
  bool _subtitleSecondaryDim = true;
  String _subtitleFontFamily = 'system';
  int _subtitleFontWeight = 5;
  double _subtitleLineSpacing = 3;
  double _subtitleLineHeight = 1.35;
  double _subtitleBgRadius = 4;
  int _subtitleBgColor = 0xFF000000;
  bool _subtitleShowBg = true;
  String _subtitleAlign = 'center';
  bool _subtitleUseAssPosition = true;

  // 集合类型
  static const _kSubtitleMemory = 'settings.subtitleMemory';
  List<SubtitleMemory> _subtitleMemory = const <SubtitleMemory>[];

  static const _kHiddenAutoPlaylists = 'settings.hiddenAutoPlaylists';
  Set<String> _hiddenAutoPlaylists = <String>{};

  Set<String> _hiddenVideoPaths = <String>{};

  static const _kAutoAdded = 'settings.autoPlaylistAdded';
  static const _kAutoRemoved = 'settings.autoPlaylistRemoved';
  Set<String> _autoAdded = <String>{};
  Set<String> _autoRemoved = <String>{};

  // ─────────── 加载状态 & JSON 文件 ───────────
  bool _loaded = false;
  File? _jsonFile;
  Timer? _flushTimer;
  bool _dirty = false;

  // ─────────── getter ───────────
  double get defaultSpeed => _defaultSpeed;
  double get longPressSpeed => _longPressSpeed;
  int get skipSeconds => _skipSeconds;
  bool get autoPlayNext => _autoPlayNext;
  bool get backgroundPlay => _backgroundPlay;
  bool get hardwareDecoding => _hardwareDecoding;
  String get playerOrientation => _playerOrientation;
  bool get allFilesPrompted => _allFilesPrompted;
  bool get glassBlur => _glassBlur;
  String get tmdbApiKey => _tmdbApiKey;
  String get librarySort => _librarySort;
  String get libraryFilter => _libraryFilter;

  // 字幕外观
  double get subtitleFontSize => _subtitleFontSize;
  double get subtitleBgOpacity => _subtitleBgOpacity;
  int get subtitleTextColorValue => _subtitleTextColor;
  bool get subtitleStroke => _subtitleStroke;
  double get subtitlePosition => _subtitlePosition;
  double get subtitleSecondaryScale => _subtitleSecondaryScale;
  bool get subtitleSecondaryDim => _subtitleSecondaryDim;
  String get subtitleFontFamily => _subtitleFontFamily;
  int get subtitleFontWeight => _subtitleFontWeight;
  double get subtitleLineSpacing => _subtitleLineSpacing;
  double get subtitleLineHeight => _subtitleLineHeight;
  double get subtitleBgRadius => _subtitleBgRadius;
  int get subtitleBgColorValue => _subtitleBgColor;
  bool get subtitleShowBg => _subtitleShowBg;
  String get subtitleAlign => _subtitleAlign;
  bool get subtitleUseAssPosition => _subtitleUseAssPosition;

  bool get subtitleNativeAss => false; // 已废弃，恒 false

  List<SubtitleMemory> get subtitleMemory => _subtitleMemory;
  Set<String> get hiddenAutoPlaylists => _hiddenAutoPlaylists;
  Set<String> get hiddenVideoPaths => _hiddenVideoPaths;
  int get hiddenVideoCount => _hiddenVideoPaths.length;

  bool isAutoPlaylistHidden(String id) => _hiddenAutoPlaylists.contains(id);

  static String _ovKey(String playlistId, String videoId) =>
      '$playlistId\u0000$videoId';

  static Set<String> _idsFor(Set<String> set, String playlistId) => set
      .where((e) => e.startsWith('$playlistId\u0000'))
      .map((e) => e.substring(playlistId.length + 1))
      .toSet();

  Set<String> autoAddedFor(String playlistId) =>
      _idsFor(_autoAdded, playlistId);
  Set<String> autoRemovedFor(String playlistId) =>
      _idsFor(_autoRemoved, playlistId);

  // ═══════════════════════════════════════════════════════════
  // JSON 文件路径
  // ═══════════════════════════════════════════════════════════

  Future<File> _getJsonFile() async {
    if (_jsonFile != null) return _jsonFile!;
    final dir = await getApplicationDocumentsDirectory();
    _jsonFile = File('${dir.path}/perchplay_settings.json');
    return _jsonFile!;
  }

  // ═══════════════════════════════════════════════════════════
  // JSON 序列化 / 反序列化
  // ═══════════════════════════════════════════════════════════

  Map<String, dynamic> _toJson() => {
        _kDefaultSpeed: _defaultSpeed,
        _kLongPressSpeed: _longPressSpeed,
        _kSkipSeconds: _skipSeconds,
        _kAutoPlayNext: _autoPlayNext,
        _kBackgroundPlay: _backgroundPlay,
        _kHardwareDecoding: _hardwareDecoding,
        _kPlayerOrientation: _playerOrientation,
    _kHdrOutputMode: _hdrOutputMode,
    _kAnime4kMode: _anime4kMode,
        _kAllFilesPrompted: _allFilesPrompted,
        _kGlassBlurV2: _glassBlur,
        _kTmdbApiKey: _tmdbApiKey,
        _kLibrarySort: _librarySort,
        _kLibraryFilter: _libraryFilter,
        _kSubtitleFontSize: _subtitleFontSize,
        _kSubtitleBgOpacity: _subtitleBgOpacity,
        _kSubtitleTextColor: _subtitleTextColor,
        _kSubtitleStroke: _subtitleStroke,
        _kSubtitlePosition: _subtitlePosition,
        _kSubtitleSecondaryScale: _subtitleSecondaryScale,
        _kSubtitleSecondaryDim: _subtitleSecondaryDim,
        _kSubtitleFontFamily: _subtitleFontFamily,
        _kSubtitleFontWeight: _subtitleFontWeight,
        _kSubtitleLineSpacing: _subtitleLineSpacing,
        _kSubtitleLineHeight: _subtitleLineHeight,
        _kSubtitleBgRadius: _subtitleBgRadius,
        _kSubtitleBgColor: _subtitleBgColor,
        _kSubtitleShowBg: _subtitleShowBg,
        _kSubtitleAlign: _subtitleAlign,
        _kSubtitleUseAssPos: _subtitleUseAssPosition,
        _kSubtitleMemory:
            [for (final m in _subtitleMemory) m.encode()],
        _kHiddenAutoPlaylists: _hiddenAutoPlaylists.toList(),
        LibraryHiddenService.prefsKey: _hiddenVideoPaths.toList(),
        _kAutoAdded: _autoAdded.toList(),
        _kAutoRemoved: _autoRemoved.toList(),
      };

  // ═══════════════════════════════════════════════════════════
  // Debounced flush
  // ═══════════════════════════════════════════════════════════

  /// 标记脏数据，150ms 内自动落盘 JSON 文件。
  ///
  /// 连续多次调用（如滑杆拖动触发 17 次 setter）会被 debounce 合并成一次写入。
  void _scheduleJsonFlush() {
    _dirty = true;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 150), () {
      _doJsonFlush();
    });
  }

  void _doJsonFlush() {
    if (!_dirty) return;
    _dirty = false;
    _getJsonFile().then((file) {
      try {
        final json = _toJson();
        final sink = file.openWrite(mode: FileMode.write);
        sink.write(jsonEncode(json));
        sink.flush().then((_) => sink.close());
      } catch (e) {
        debugPrint('[PerchPlay] JSON settings flush failed: $e');
      }
    }).catchError((Object e) {
      debugPrint('[PerchPlay] JSON settings file access failed: $e');
    });
  }

  /// 强制立即落盘 JSON 文件（供 App 进入后台时调用）。
  ///
  /// 不等待 debounce，直接同步写入。调用后 150ms 内的自动 flush 会被跳过。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty) return;
    _dirty = false;
    try {
      final file = await _getJsonFile();
      final json = _toJson();
      final sink = file.openWrite(mode: FileMode.write);
      sink.write(jsonEncode(json));
      await sink.flush();
      await sink.close();
    } catch (e) {
      debugPrint('[PerchPlay] flush() failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 启动加载（JSON 优先 → SP 兜底）
  // ═══════════════════════════════════════════════════════════

  Future<void> ensureLoaded() async {
    if (_loaded) return;

    // 先尝试 JSON 文件
    final jsonLoaded = await _tryLoadJson();

    // SP 兜底：JSON 没读到或不存在时，从 SP 读
    final prefs = await SharedPreferences.getInstance();
    if (!jsonLoaded) {
      await _loadFromPrefs(prefs);
    }

    // ═══════════════════════════════════════════════════════════
    // v1.1.8 → v1.1.9 一次性安全重置
    //
    // v1.1.8 的 gpu-next 有个严重 bug：切换 HDR 输出模式 / Anime4K 时
    // 会「重建 VideoController」，但 media_kit 以 player handle 缓存
    // 实例，重建拿到旧实例、Dart 层指向空壳 → 黑屏，且设置被持久化，
    // **重启也无法恢复**（每次启动都再次尝试 gpu-next）。
    //
    // 所以升级到 v1.1.9 时，强制把这两个 gpu-next 依赖的设置重置为
    // off 一次。用户之后可以重新手动开启（新版已修复 vo 切换逻辑，
    // 且加了 vo-configured 自检兜底）。
    // ═══════════════════════════════════════════════════════════
    const resetKey = 'gpuNextReset_v119';
    if (!(prefs.getBool(resetKey) ?? false)) {
      _hdrOutputMode = 'off';
      _anime4kMode = 'off';
      await prefs.setBool(resetKey, true);
      // 同步写回 SP，避免 JSON 里旧值又覆盖回来
      await prefs.setString(_kHdrOutputMode, 'off');
      await prefs.setString(_kAnime4kMode, 'off');
      debugPrint('[PerchPlay] v1.1.9 安全重置：HDR/Anime4K 已回 off');
    }

    // 集合类型 SP 仍作为权威源（JSON 可能不完整）
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
    _subtitleMemory = _decodeSubtitleMemory(
        prefs.getStringList(_kSubtitleMemory) ?? const <String>[]);

    // 确保 JSON 文件存在（首次启动 / 从旧版本升级时可能没有）
    _scheduleJsonFlush();

    _loaded = true;
  }

  /// 从 JSON 文件加载，成功返回 true。
  Future<bool> _tryLoadJson() async {
    try {
      final file = await _getJsonFile();
      if (!await file.exists()) {
        debugPrint('[PerchPlay] No JSON settings file, will load from SP');
        return false;
      }
      final raw = await file.readAsString();
      if (raw.isEmpty) return false;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _applyJsonMap(map);
      debugPrint('[PerchPlay] Settings loaded from JSON file');
      return true;
    } catch (e) {
      debugPrint('[PerchPlay] JSON settings load failed: $e, falling back to SP');
      return false;
    }
  }

  void _applyJsonMap(Map<String, dynamic> map) {
    _defaultSpeed = (map[_kDefaultSpeed] as num?)?.toDouble() ?? 1.0;
    _longPressSpeed = (map[_kLongPressSpeed] as num?)?.toDouble() ?? 2.0;
    _skipSeconds = (map[_kSkipSeconds] as num?)?.toInt() ?? 10;
    _autoPlayNext = map[_kAutoPlayNext] as bool? ?? true;
    _backgroundPlay = map[_kBackgroundPlay] as bool? ?? true;
    _hardwareDecoding = map[_kHardwareDecoding] as bool? ?? true;
    _playerOrientation = map[_kPlayerOrientation] as String? ?? 'auto';
    _hdrOutputMode = map[_kHdrOutputMode] as String? ?? 'off';
    _anime4kMode = map[_kAnime4kMode] as String? ?? 'off';
    _allFilesPrompted = map[_kAllFilesPrompted] as bool? ?? false;
    _glassBlur = map[_kGlassBlurV2] as bool? ?? true;
    _tmdbApiKey = map[_kTmdbApiKey] as String? ?? '';
    _librarySort = map[_kLibrarySort] as String? ?? 'name';
    _libraryFilter = map[_kLibraryFilter] as String? ?? 'all';
    _subtitleFontSize =
        ((map[_kSubtitleFontSize] as num?)?.toDouble() ?? 0).clamp(0, 30);
    _subtitleBgOpacity =
        ((map[_kSubtitleBgOpacity] as num?)?.toDouble() ?? 0.62)
            .clamp(0.0, 1.0);
    _subtitleTextColor = map[_kSubtitleTextColor] as int? ?? 0xFFFFFFFF;
    _subtitleStroke = map[_kSubtitleStroke] as bool? ?? true;
    _subtitlePosition =
        ((map[_kSubtitlePosition] as num?)?.toDouble() ?? 0.12).clamp(0.0, 0.6);
    _subtitleSecondaryScale =
        ((map[_kSubtitleSecondaryScale] as num?)?.toDouble() ?? 0.82)
            .clamp(0.5, 1.0);
    _subtitleSecondaryDim = map[_kSubtitleSecondaryDim] as bool? ?? true;
    _subtitleFontFamily =
        map[_kSubtitleFontFamily] as String? ?? 'system';
    _subtitleFontWeight =
        ((map[_kSubtitleFontWeight] as num?)?.toInt() ?? 5).clamp(3, 8);
    _subtitleLineSpacing =
        ((map[_kSubtitleLineSpacing] as num?)?.toDouble() ?? 3).clamp(0, 12);
    _subtitleLineHeight =
        ((map[_kSubtitleLineHeight] as num?)?.toDouble() ?? 1.35)
            .clamp(1.0, 1.8);
    _subtitleBgRadius =
        ((map[_kSubtitleBgRadius] as num?)?.toDouble() ?? 4).clamp(0, 12);
    _subtitleBgColor = map[_kSubtitleBgColor] as int? ?? 0xFF000000;
    _subtitleShowBg = map[_kSubtitleShowBg] as bool? ?? true;
    _subtitleAlign = map[_kSubtitleAlign] as String? ?? 'center';
    _subtitleUseAssPosition =
        map[_kSubtitleUseAssPos] as bool? ?? true;
  }

  Future<void> _loadFromPrefs(SharedPreferences prefs) async {
    _defaultSpeed = prefs.getDouble(_kDefaultSpeed) ?? 1.0;
    _longPressSpeed = prefs.getDouble(_kLongPressSpeed) ?? 2.0;
    _skipSeconds = prefs.getInt(_kSkipSeconds) ?? 10;
    _autoPlayNext = prefs.getBool(_kAutoPlayNext) ?? true;
    _backgroundPlay = prefs.getBool(_kBackgroundPlay) ?? true;
    _hardwareDecoding = prefs.getBool(_kHardwareDecoding) ?? true;
    _playerOrientation = prefs.getString(_kPlayerOrientation) ?? 'auto';
    _hdrOutputMode = prefs.getString(_kHdrOutputMode) ?? 'off';
    _anime4kMode = prefs.getString(_kAnime4kMode) ?? 'off';
    _allFilesPrompted = prefs.getBool(_kAllFilesPrompted) ?? false;
    if (prefs.containsKey(_kGlassBlurV2)) {
      _glassBlur = prefs.getBool(_kGlassBlurV2) ?? true;
    } else {
      _glassBlur = true;
      await prefs.remove(_kGlassBlur);
    }
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
    _tmdbApiKey = prefs.getString(_kTmdbApiKey) ?? '';
    _librarySort = prefs.getString(_kLibrarySort) ?? 'name';
    _libraryFilter = prefs.getString(_kLibraryFilter) ?? 'all';
    debugPrint('[PerchPlay] Settings loaded from SharedPreferences');
  }

  // ═══════════════════════════════════════════════════════════
  // Setter（每个同时写 SP + schedule JSON flush）
  // ═══════════════════════════════════════════════════════════

  Future<void> setLibrarySort(String value) async {
    _librarySort = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLibrarySort, value);
    } catch (e) {
      debugPrint('[PerchPlay] setLibrarySort SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setLibraryFilter(String value) async {
    _libraryFilter = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLibraryFilter, value);
    } catch (e) {
      debugPrint('[PerchPlay] setLibraryFilter SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  // ═══════════════ 字幕记忆 ═══════════════

  SubtitleMemory? subtitleMemoryFor(String videoPath) {
    final key = LibraryHiddenService.normalizePath(videoPath);
    if (key.isEmpty) return null;
    return SubtitleMemory.find(_subtitleMemory, key);
  }

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

  Future<void> touchSubtitleMemory(SubtitleMemory memory) =>
      _storeSubtitleMemory(
        memory.touch(DateTime.now().millisecondsSinceEpoch),
      );

  Future<void> _storeSubtitleMemory(SubtitleMemory entry) async {
    _subtitleMemory = SubtitleMemory.upsert(_subtitleMemory, entry);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kSubtitleMemory,
        [for (final memory in _subtitleMemory) memory.encode()],
      );
    } catch (e) {
      debugPrint('[PerchPlay] _storeSubtitleMemory SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> clearSubtitleMemory() async {
    _subtitleMemory = const <SubtitleMemory>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSubtitleMemory);
    } catch (e) {
      debugPrint('[PerchPlay] clearSubtitleMemory SP remove failed: $e');
    }
    _scheduleJsonFlush();
  }

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
    } catch (e) {
      debugPrint('[PerchPlay] setDefaultSpeed SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setLongPressSpeed(double value) async {
    _longPressSpeed = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kLongPressSpeed, value);
    } catch (e) {
      debugPrint('[PerchPlay] setLongPressSpeed SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSkipSeconds(int value) async {
    _skipSeconds = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSkipSeconds, value);
    } catch (e) {
      debugPrint('[PerchPlay] setSkipSeconds SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setAutoPlayNext(bool value) async {
    _autoPlayNext = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoPlayNext, value);
    } catch (e) {
      debugPrint('[PerchPlay] setAutoPlayNext SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setBackgroundPlay(bool value) async {
    _backgroundPlay = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBackgroundPlay, value);
    } catch (e) {
      debugPrint('[PerchPlay] setBackgroundPlay SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setHardwareDecoding(bool value) async {
    _hardwareDecoding = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHardwareDecoding, value);
    } catch (e) {
      debugPrint('[PerchPlay] setHardwareDecoding SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setPlayerOrientation(String value) async {
    _playerOrientation = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPlayerOrientation, value);
    } catch (e) {
      debugPrint('[PerchPlay] setPlayerOrientation SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  /// HDR 输出模式（存的稳定字符串 id，见 `HdrOutputModeX.id`）。
  ///
  /// 默认 `off`：绝大多数设备/片源用不到，且开启后走 gpu-next +
  /// Vulkan 渲染路径，兼容性不如默认的 OpenGL 路径。只有用户明确
  /// 想要 HDR 直通时才手动开。
  String get hdrOutputMode => _hdrOutputMode;

  Future<void> setHdrOutputMode(String value) async {
    _hdrOutputMode = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHdrOutputMode, value);
    } catch (e) {
      debugPrint('[PerchPlay] setHdrOutputMode SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  /// Anime4K 动漫放大档位（存的稳定字符串 id，见 `Anime4kModeX.id`）。
  ///
  /// 默认 `off`。与 HDR 输出模式互斥：两者都写 mpv 的 `glsl-shader`，
  /// 叠加会互相干扰，切换时由 PlayerNotifier 负责关掉另一个。
  String get anime4kMode => _anime4kMode;

  Future<void> setAnime4kMode(String value) async {
    _anime4kMode = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAnime4kMode, value);
    } catch (e) {
      debugPrint('[PerchPlay] setAnime4kMode SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> hideAutoPlaylist(String id) async {
    _hiddenAutoPlaylists.add(id);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _kHiddenAutoPlaylists, _hiddenAutoPlaylists.toList());
    } catch (e) {
      debugPrint('[PerchPlay] hideAutoPlaylist SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> hideVideoPath(String path) async {
    final normalized = LibraryHiddenService.normalizePath(path);
    if (normalized.isEmpty) return;
    if (_hiddenVideoPaths.contains(normalized)) return;
    _hiddenVideoPaths.add(normalized);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          LibraryHiddenService.prefsKey, _hiddenVideoPaths.toList());
    } catch (e) {
      debugPrint('[PerchPlay] hideVideoPath SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

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
    } catch (e) {
      debugPrint('[PerchPlay] pruneMissingHiddenVideos SP write failed: $e');
    }
    _scheduleJsonFlush();
    return removed;
  }

  Future<void> restoreHiddenVideos() async {
    _hiddenVideoPaths = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(LibraryHiddenService.prefsKey);
    } catch (e) {
      debugPrint('[PerchPlay] restoreHiddenVideos SP remove failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> restoreAutoPlaylists() async {
    _hiddenAutoPlaylists = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kHiddenAutoPlaylists);
    } catch (e) {
      debugPrint('[PerchPlay] restoreAutoPlaylists SP remove failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> clearAutoOverlays() async {
    _autoAdded = <String>{};
    _autoRemoved = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAutoAdded);
      await prefs.remove(_kAutoRemoved);
    } catch (e) {
      debugPrint('[PerchPlay] clearAutoOverlays SP remove failed: $e');
    }
    _scheduleJsonFlush();
  }

  List<Playlist> applyAutoOverrides(
    List<SourceGroup> groups,
    List<VideoModel> videos,
  ) {
    final existingVidIds = videos.map((v) => v.id).toSet();
    final auto = <Playlist>[];

    final ordered = <SourceGroup>[
      for (final g in groups)
        if (g.kindPriority == 0) g,
      for (final g in groups)
        if (g.kindPriority == 1) g,
      for (final g in groups)
        if (g.kindPriority == 2) g,
    ];

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

  Future<void> markAutoAdded(String playlistId, String videoId) async {
    _autoAdded.add(_ovKey(playlistId, videoId));
    _autoRemoved.remove(_ovKey(playlistId, videoId));
    await _saveOverlays();
  }

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
    } catch (e) {
      debugPrint('[PerchPlay] _saveOverlays SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setAllFilesPrompted(bool value) async {
    _allFilesPrompted = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAllFilesPrompted, value);
    } catch (e) {
      debugPrint('[PerchPlay] setAllFilesPrompted SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setGlassBlur(bool value) async {
    _glassBlur = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kGlassBlurV2, value);
    } catch (e) {
      debugPrint('[PerchPlay] setGlassBlur SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  // ═══════════════ 字幕外观 setter ═══════════════

  Future<void> setSubtitleFontSize(double v) async {
    _subtitleFontSize = v.clamp(0, 30);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleFontSize, _subtitleFontSize);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleFontSize SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleBgOpacity(double v) async {
    _subtitleBgOpacity = v.clamp(0.0, 1.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleBgOpacity, _subtitleBgOpacity);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleBgOpacity SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleTextColor(int argb) async {
    _subtitleTextColor = argb;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleTextColor, _subtitleTextColor);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleTextColor SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleStroke(bool v) async {
    _subtitleStroke = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleStroke, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleStroke SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitlePosition(double v) async {
    _subtitlePosition = v.clamp(0.0, 0.6);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitlePosition, _subtitlePosition);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitlePosition SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleSecondaryScale(double v) async {
    _subtitleSecondaryScale = v.clamp(0.5, 1.0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(
          _kSubtitleSecondaryScale, _subtitleSecondaryScale);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleSecondaryScale SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleSecondaryDim(bool v) async {
    _subtitleSecondaryDim = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleSecondaryDim, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleSecondaryDim SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleFontFamily(String v) async {
    _subtitleFontFamily = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSubtitleFontFamily, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleFontFamily SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleFontWeight(int v) async {
    _subtitleFontWeight = v.clamp(3, 8);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleFontWeight, _subtitleFontWeight);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleFontWeight SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleLineSpacing(double v) async {
    _subtitleLineSpacing = v.clamp(0, 12);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleLineSpacing, _subtitleLineSpacing);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleLineSpacing SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleLineHeight(double v) async {
    _subtitleLineHeight = v.clamp(1.0, 1.8);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleLineHeight, _subtitleLineHeight);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleLineHeight SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleBgRadius(double v) async {
    _subtitleBgRadius = v.clamp(0, 12);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSubtitleBgRadius, _subtitleBgRadius);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleBgRadius SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleBgColor(int argb) async {
    _subtitleBgColor = argb;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSubtitleBgColor, _subtitleBgColor);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleBgColor SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleShowBg(bool v) async {
    _subtitleShowBg = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleShowBg, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleShowBg SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleAlign(String v) async {
    _subtitleAlign = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSubtitleAlign, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleAlign SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setSubtitleUseAssPosition(bool v) async {
    _subtitleUseAssPosition = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSubtitleUseAssPos, v);
    } catch (e) {
      debugPrint('[PerchPlay] setSubtitleUseAssPosition SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  Future<void> setTmdbApiKey(String value) async {
    _tmdbApiKey = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTmdbApiKey, value);
    } catch (e) {
      debugPrint('[PerchPlay] setTmdbApiKey SP write failed: $e');
    }
    _scheduleJsonFlush();
  }

  // ═══════════════════════════════════════════════════════════
  // 批量设置字幕样式（字幕面板用，一次 SP 批量写入 + 一次 JSON flush）
  // ═══════════════════════════════════════════════════════════

  /// 一次性设置全部字幕外观参数，减少 SP 写入次数。
  ///
  /// 字幕样式面板有 15 个参数，逐个 setter 调用会触发 15 次 SP 写入 +
  /// 15 次 debounce 重置。改用此方法：一次 SP batch + 一次 JSON flush。
  Future<void> batchSetSubtitleStyle({
    required double fontSize,
    required double position,
    required double bgOpacity,
    required int textColor,
    required bool stroke,
    required double secScale,
    required bool secDim,
    required String fontFamily,
    required int fontWeightIdx,
    required double lineSpacing,
    required double lineHeight,
    required double bgRadius,
    required int bgColor,
    required bool showBg,
    required String align,
    required bool useAssPos,
  }) async {
    // 先更新内存
    _subtitleFontSize = fontSize.clamp(0, 30);
    _subtitlePosition = position.clamp(0.0, 0.6);
    _subtitleBgOpacity = bgOpacity.clamp(0.0, 1.0);
    _subtitleTextColor = textColor;
    _subtitleStroke = stroke;
    _subtitleSecondaryScale = secScale.clamp(0.5, 1.0);
    _subtitleSecondaryDim = secDim;
    _subtitleFontFamily = fontFamily;
    _subtitleFontWeight = fontWeightIdx.clamp(3, 8);
    _subtitleLineSpacing = lineSpacing.clamp(0, 12);
    _subtitleLineHeight = lineHeight.clamp(1.0, 1.8);
    _subtitleBgRadius = bgRadius.clamp(0, 12);
    _subtitleBgColor = bgColor;
    _subtitleShowBg = showBg;
    _subtitleAlign = align;
    _subtitleUseAssPosition = useAssPos;

    // SP 批量写入
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setDouble(_kSubtitleFontSize, _subtitleFontSize),
        prefs.setDouble(_kSubtitlePosition, _subtitlePosition),
        prefs.setDouble(_kSubtitleBgOpacity, _subtitleBgOpacity),
        prefs.setInt(_kSubtitleTextColor, _subtitleTextColor),
        prefs.setBool(_kSubtitleStroke, _subtitleStroke),
        prefs.setDouble(_kSubtitleSecondaryScale, _subtitleSecondaryScale),
        prefs.setBool(_kSubtitleSecondaryDim, _subtitleSecondaryDim),
        prefs.setString(_kSubtitleFontFamily, _subtitleFontFamily),
        prefs.setInt(_kSubtitleFontWeight, _subtitleFontWeight),
        prefs.setDouble(_kSubtitleLineSpacing, _subtitleLineSpacing),
        prefs.setDouble(_kSubtitleLineHeight, _subtitleLineHeight),
        prefs.setDouble(_kSubtitleBgRadius, _subtitleBgRadius),
        prefs.setInt(_kSubtitleBgColor, _subtitleBgColor),
        prefs.setBool(_kSubtitleShowBg, _subtitleShowBg),
        prefs.setString(_kSubtitleAlign, _subtitleAlign),
        prefs.setBool(_kSubtitleUseAssPos, _subtitleUseAssPosition),
      ]);
    } catch (e) {
      debugPrint('[PerchPlay] batchSetSubtitleStyle SP write failed: $e');
    }

    _scheduleJsonFlush();
  }
}