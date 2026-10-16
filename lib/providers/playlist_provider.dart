import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/playlist_model.dart';
import '../models/scrape_result.dart';
import '../models/video_model.dart';
import '../services/database_service.dart';
import '../services/app_settings_service.dart';
import '../services/video_source_service.dart';
import 'library_provider.dart';
import 'scrape_provider.dart';
import 'package:uuid/uuid.dart';

final playlistListProvider =
    AsyncNotifierProvider<PlaylistListNotifier, List<Playlist>>(
  PlaylistListNotifier.new,
);

class PlaylistListNotifier extends AsyncNotifier<List<Playlist>> {
  final _db = DatabaseService.instance;
  final _uuid = const Uuid();

  /// 刮削结果陆续到达后的重分组防抖计时器（见 [_scheduleRegroup]）
  Timer? _regroupDebounce;

  /// 防抖窗口（秒）：批量刮削每秒一条，必须攒够一批再重建，
  /// 否则每来一条海报就全量删表 + 重写一遍播放列表。
  static const _regroupDebounceDelay = Duration(seconds: 2);

  /// 有没有一次重分组正在跑：刮削结束时被重新触发也不会两次并发的写库
  bool _regrouping = false;

  /// 运行期间攒下的一次重分组请求，跑完补做
  bool _regroupPending = false;

  @override
  Future<List<Playlist>> build() async {
    // 刮削结果到达后要重分组（先用文件名分组，刮削到的类型再修正）。
    // 只监听 results：queueLength / error 的变化不改变分组结果，
    // 监听它们只会白白排一遍防抖。
    ref.listen<Map<String, ScrapeResult?>>(
      scrapeProvider.select((s) => s.results),
      (previous, next) {
        if (previous == null) return; // 首次挂载，没有"新结果"可言
        _scheduleRegroup();
      },
    );
    ref.onDispose(() {
      _regroupDebounce?.cancel();
      _regroupDebounce = null;
    });
    return _db.getAllPlaylists();
  }

  /// 刮削结果变化后延迟重分组：2 秒内的连续变化只重建一次
  ///
  /// 为什么不是每次变化都重建：批量刮削每秒产出一条，重建要
  /// `deleteAutoPlaylists` + 全量 `savePlaylist`，几十条就是几十轮写库。
  void _scheduleRegroup() {
    _regroupDebounce?.cancel();
    _regroupDebounce = Timer(_regroupDebounceDelay, _regroupFromScrape);
  }

  /// 用当前的视频库 + 刮削结果重建自动列表
  Future<void> _regroupFromScrape() async {
    _regroupDebounce = null;
    if (_regrouping) {
      // 正在写库时又到了新结果：打完补丁再走，避免两次 syncAutoPlaylists
      // 交错（后一次的 deleteAutoPlaylists 会把前一次刚写的删掉）
      _regroupPending = true;
      return;
    }
    // 影库还没加载出来时不动：空列表重建会把所有自动列表删光
    final videos = ref.read(videoListProvider).valueOrNull;
    if (videos == null || videos.isEmpty) return;

    _regrouping = true;
    try {
      await syncAutoPlaylists(videos);
    } finally {
      _regrouping = false;
    }
    if (_regroupPending) {
      _regroupPending = false;
      await _regroupFromScrape();
    }
  }

  Future<void> createPlaylist(String name) async {
    final playlist = Playlist(
      id: _uuid.v4(),
      name: name,
      videoIds: [],
      createdAt: DateTime.now(),
    );
    await _db.savePlaylist(playlist);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> addVideoToPlaylist(String playlistId, String videoId) async {
    final playlists = state.value ?? [];
    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;

    final playlist = playlists[index];
    if (playlist.videoIds.contains(videoId)) return;

    // 自动列表：记住"这是用户手动加进来的"，下次扫描重建时不会被清掉
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.markAutoAdded(playlistId, videoId);
    }

    final updated = playlist.copyWith(
      videoIds: [...playlist.videoIds, videoId],
    );
    await _db.savePlaylist(updated);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> removeVideoFromPlaylist(
      String playlistId, String videoId) async {
    final playlists = state.value ?? [];
    final index = playlists.indexWhere((p) => p.id == playlistId);
    if (index == -1) return;

    final playlist = playlists[index];

    // 自动列表：记住"这是用户手动移出去的"，下次扫描不会又长回来
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.markAutoRemoved(playlistId, videoId);
    }

    final updated = playlist.copyWith(
      videoIds: playlist.videoIds.where((id) => id != videoId).toList(),
    );
    await _db.savePlaylist(updated);
    state = AsyncData(await _db.getAllPlaylists());
  }

  Future<void> deletePlaylist(String playlistId) async {
    // 自动列表是扫描后重建的，只删记录会"删了又长回来"，
    // 所以额外记住用户的删除意图
    if (playlistId.startsWith('auto:')) {
      await AppSettingsService.instance.hideAutoPlaylist(playlistId);
    }
    await _db.deletePlaylist(playlistId);
    state = AsyncData(await _db.getAllPlaylists());
  }

  /// 恢复被删掉的自动列表并立即重建
  Future<void> restoreAutoPlaylists(List<VideoModel> videos) async {
    await AppSettingsService.instance.restoreAutoPlaylists();
    await syncAutoPlaylists(videos);
  }

  /// 扫描后重建「自动列表」：
  ///   - 个人视频（相机/剪辑/短视频/录屏/社交）→ 按来源+前缀分组，不走 TMDB
  ///   - 影视（other/download）→ 按文件名识别剧名+季集，可走 TMDB 刮削
  ///   - 未被剧集分组的影视路径 → 前缀兜底（≥2 个相同前缀才成组）
  ///   - 刮削已给出类型的视频 → 以刮削类型为准修正（《流浪地球2》这类
  ///     片名带数字的电影原来会被判成剧集，永远进不了「🎬 电影」）
  ///   - 用户手动删掉的列表不再生成
  ///   - 用户手动加进来 / 移出去的视频会保留
  /// 手动创建的列表不受影响。
  ///
  /// [scrapedTypes] 不传时按 [scrapeProvider] 当前结果取（这是唯一的真实来源）。
  Future<void> syncAutoPlaylists(
    List<VideoModel> videos, {
    Map<String, String>? scrapedTypes,
  }) async {
    try {
      await AppSettingsService.instance.ensureLoaded();
      await _db.deleteAutoPlaylists();

      final allGroups = VideoSourceService.groupAll(
        videos.map((v) => v.path).toList(),
        scrapedTypes: scrapedTypes ?? _scrapedTypes(),
      );

      final auto = AppSettingsService.instance.applyAutoOverrides(
        allGroups,
        videos,
      );

      for (final pl in auto) {
        await _db.savePlaylist(pl);
      }
      state = AsyncData(await _db.getAllPlaylists());
    } catch (e) {
      // 自动分组失败不应影响影库
      state = AsyncData(await _db.getAllPlaylists());
    }
  }

  /// 按 id 取列表（播放队列用）
  Playlist? byId(String id) {
    for (final p in state.value ?? const <Playlist>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 把刮削结果整理成 `groupAll` 要的「路径 → 电影/剧集」映射
  ///
  /// 只收非空结果：没刮到（网络失败 / 没开刮削）时保持按文件名分组的原行为。
  Map<String, String> _scrapedTypes() {
    final results = ref.read(scrapeProvider).results;
    if (results.isEmpty) return const {};
    final out = <String, String>{};
    for (final entry in results.entries) {
      final r = entry.value;
      if (r == null) continue;
      out[entry.key] = r.type == ScrapeType.movie
          ? ScrapeKind.movie
          : ScrapeKind.tv;
    }
    return out;
  }

  /// 按名称取列表（新建后立即取回）
  Playlist? byName(String name) {
    for (final p in state.value ?? const <Playlist>[]) {
      if (p.name == name) return p;
    }
    return null;
  }
}

// 向后兼容别名
final playlistProvider = playlistListProvider;