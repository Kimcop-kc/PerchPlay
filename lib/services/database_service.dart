import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/video_model.dart';
import '../models/playlist_model.dart';
import 'playlist_prune_service.dart';

class DatabaseService {
  DatabaseService._();
  static final instance = DatabaseService._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'vidflow.db');
    return openDatabase(
      path,
      version: 4,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE videos (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        folderPath TEXT NOT NULL,
        size INTEGER NOT NULL,
        durationMs INTEGER NOT NULL,
        dateAdded TEXT NOT NULL,
        dateModified TEXT NOT NULL,
        thumbnailPath TEXT DEFAULT '',
        lastPosition REAL DEFAULT 0.0,
        playCount INTEGER DEFAULT 0,
        isFavorite INTEGER DEFAULT 0,
        lastPlayed TEXT
      )
    ''');

    await _createOtherTables(db);
  }

  Future<void> _createOtherTables(Database db) async {
    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        videoIds TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        sortOrder INTEGER DEFAULT 0,
        isAuto INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE playback_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        videoId TEXT NOT NULL,
        position REAL NOT NULL,
        playedAt TEXT NOT NULL,
        FOREIGN KEY (videoId) REFERENCES videos(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE scrape_cache (
        search_key TEXT NOT NULL,
        title TEXT NOT NULL,
        original_title TEXT,
        year INTEGER,
        overview TEXT,
        poster_path TEXT,
        backdrop_path TEXT,
        rating REAL,
        vote_count INTEGER,
        genres TEXT NOT NULL DEFAULT '[]',
        type TEXT NOT NULL,
        tmdb_id INTEGER NOT NULL,
        season_number INTEGER,
        episode_number INTEGER,
        episode_title TEXT,
        cached_at TEXT NOT NULL,
        video_path TEXT,
        PRIMARY KEY (search_key, type)
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_scrape_cache_vpath ON scrape_cache (video_path)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 的 videos 表没有 lastPlayed 列，补上
      await db.execute('ALTER TABLE videos ADD COLUMN lastPlayed TEXT');
    }
    if (oldVersion < 3) {
      // 自动生成的播放列表需要标记，扫描时才能只重建这部分
      try {
        await db.execute(
            'ALTER TABLE playlists ADD COLUMN isAuto INTEGER DEFAULT 0');
      } catch (_) {}
    }
    if (oldVersion < 4) {
      // v4: 刮削缓存表（TMDB 海报/元数据离线可用）
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS scrape_cache (
            search_key TEXT NOT NULL,
            title TEXT NOT NULL,
            original_title TEXT,
            year INTEGER,
            overview TEXT,
            poster_path TEXT,
            backdrop_path TEXT,
            rating REAL,
            vote_count INTEGER,
            genres TEXT NOT NULL DEFAULT '[]',
            type TEXT NOT NULL,
            tmdb_id INTEGER NOT NULL,
            season_number INTEGER,
            episode_number INTEGER,
            episode_title TEXT,
            cached_at TEXT NOT NULL,
            video_path TEXT,
            PRIMARY KEY (search_key, type)
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_scrape_cache_vpath ON scrape_cache (video_path)');
      } catch (_) {}
    }
  }

  // ---------- 视频操作 ----------

  Future<List<VideoModel>> getAllVideos() async {
    final db = await database;
    final maps = await db.query('videos', orderBy: 'dateModified DESC');
    return maps.map((map) => VideoModel.fromJson(map)).toList();
  }

  Future<void> insertVideos(List<VideoModel> videos) async {
    final db = await database;
    final batch = db.batch();
    for (final video in videos) {
      batch.insert('videos', video.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 按路径取单条记录（播放器恢复进度用）
  Future<VideoModel?> getVideoByPath(String path) async {
    final db = await database;
    final maps = await db.query('videos',
        where: 'path = ?', whereArgs: [path], limit: 1);
    if (maps.isEmpty) return null;
    return VideoModel.fromJson(maps.first);
  }

  /// 扫描结果写入：保留已有的用户数据（进度/播放次数/收藏/缩略图/最后播放时间）。
  ///
  /// 直接用 replace 会把 lastPosition 覆盖回 0，导致观看进度丢失。
  Future<void> upsertScannedVideos(List<VideoModel> videos) async {
    if (videos.isEmpty) return;
    final db = await database;
    final existing = {for (final v in await getAllVideos()) v.id: v};
    final batch = db.batch();
    for (final video in videos) {
      final old = existing[video.id];
      final merged = old == null
          ? video
          : video.copyWith(
              lastPosition: old.lastPosition,
              playCount: old.playCount,
              isFavorite: old.isFavorite,
              lastPlayed: old.lastPlayed,
              thumbnailPath: old.thumbnailPath.isNotEmpty
                  ? old.thumbnailPath
                  : video.thumbnailPath,
              // 扫描到的时长若为 0，保留之前播放时测得的时长
              durationMs:
                  video.durationMs > 0 ? video.durationMs : old.durationMs,
            );
      batch.insert('videos', merged.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);

    // 清理历史重复记录：早期照片库导出在「导出成功但索引没落盘」时会生成
    // xxx_1.mp4 之类的新文件名，同一视频因此变成多条不同 path 的记录。
    // 修好导出逻辑后，这些脏数据也要顺手清掉，否则用户升级后仍看到重复条目。
    await _pruneDuplicateAssetCopies(
      {for (final v in videos) v.path},
    );
  }

  /// 清理同一照片库资产被重复导出的副本。
  ///
  /// 文件名格式由 LocalMediaImportService 决定：`ph_<12位hash>_<标题>.<ext>`。
  /// 这里按 `ph_ + 12 位 hash + _`（前 16 字符）分组，每组只保留一条。
  Future<void> _pruneDuplicateAssetCopies(Set<String> keepPaths) async {
    try {
      final all = await getAllVideos();
      final groups = <String, List<VideoModel>>{};
      for (final v in all) {
        final name = v.path.split('/').last;
        if (!name.startsWith('ph_') || name.length < 16) continue;
        groups.putIfAbsent(name.substring(0, 16), () => []).add(v);
      }
      final removeIds = <String>[];
      final removePaths = <String>[];
      for (final list in groups.values) {
        if (list.length < 2) continue;
        // 优先保留「本次扫描结果里」的那条，其次保留播放进度最完整的
        list.sort((a, b) {
          final ka = keepPaths.contains(a.path) ? 0 : 1;
          final kb = keepPaths.contains(b.path) ? 0 : 1;
          if (ka != kb) return ka - kb;
          return b.playCount.compareTo(a.playCount);
        });
        for (var i = 1; i < list.length; i++) {
          removeIds.add(list[i].id);
          removePaths.add(list[i].path);
        }
      }
      if (removeIds.isEmpty) return;
      await deleteVideos(removeIds);
      // 顺带删掉多余文件本体，避免继续占空间
      for (final path in removePaths) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      debugPrint('[DB] 已清理 ${removeIds.length} 条重复的相册导出记录');
    } catch (e) {
      debugPrint('[DB] 清理重复记录失败: $e');
    }
  }

  /// 删除单条视频记录（不删除磁盘文件）
  Future<void> deleteVideo(String id) => deleteVideos([id]);

  /// 批量删除视频记录（不删除磁盘文件），顺带清掉播放历史与刮削缓存
  ///
  /// 刮削缓存是跟着「这个文件」走的（海报/元数据只对它有意义）：
  /// 影库记录都没了还留着，不只是占空间，同路径再次入库时会被当成
  /// "已经刮削过"，界面继续用旧的错配结果。
  Future<void> deleteVideos(List<String> ids,
      {List<String> videoPaths = const []}) async {
    if (ids.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final id in ids) {
      batch.delete('videos', where: 'id = ?', whereArgs: [id]);
      batch.delete('playback_history', where: 'videoId = ?', whereArgs: [id]);
    }
    for (final path in videoPaths) {
      if (path.isEmpty) continue;
      batch.delete('scrape_cache', where: 'video_path = ?', whereArgs: [path]);
    }
    await batch.commit(noResult: true);
  }

  /// 只更新缩略图路径
  ///
  /// 后台补缩略图是「一批一次」地写：不能用 [upsertScannedVideos]，那个要先把
  /// 整表读出来合并（为了保住播放进度/收藏），几百个视频时每批都全表读一遍，
  /// 比生成缩略图本身还慢。
  Future<void> updateThumbnailPaths(Map<String, String> idToPath) async {
    if (idToPath.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in idToPath.entries) {
      batch.update('videos', {'thumbnailPath': entry.value},
          where: 'id = ?', whereArgs: [entry.key]);
    }
    await batch.commit(noResult: true);
  }

  /// 保存播放进度（同时刷新 lastPlayed，供历史页排序）
  Future<void> updatePlayPosition(String videoId, double position,
      {int? durationMs}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final hasDur = durationMs != null && durationMs > 0;
    await db.rawUpdate(
      'UPDATE videos SET lastPosition = ?, lastPlayed = ?'
      '${hasDur ? ', durationMs = ?' : ''}, playCount = playCount + 1'
      ' WHERE id = ?',
      [position, now, if (hasDur) durationMs, videoId],
    );
    // 记录播放历史
    await db.insert('playback_history', {
      'videoId': videoId,
      'position': position,
      'playedAt': now,
    });
  }

  /// 只写进度，不累加播放次数（播放中周期性调用 / 退出时调用）
  Future<void> saveProgress(String videoId, double position,
      {int? durationMs}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final hasDur = durationMs != null && durationMs > 0;
    await db.rawUpdate(
      'UPDATE videos SET lastPosition = ?, lastPlayed = ?'
      '${hasDur ? ', durationMs = ?' : ''} WHERE id = ?',
      [position, now, if (hasDur) durationMs, videoId],
    );
  }

  Future<List<Map<String, dynamic>>> getPlayHistory({int limit = 50}) async {
    final db = await database;
    // 每个视频取最新的播放记录
    return db.rawQuery('''
      SELECT v.*, h.playedAt as lastPlayedAt
      FROM videos v
      INNER JOIN (
        SELECT videoId, MAX(playedAt) as playedAt
        FROM playback_history
        GROUP BY videoId
      ) h ON v.id = h.videoId
      ORDER BY h.playedAt DESC
      LIMIT ?
    ''', [limit]);
  }

  // ---------- 文件夹操作 ----------

  Future<List<String>> getAllFolders() async {
    final db = await database;
    final maps = await db
        .rawQuery('SELECT DISTINCT folderPath FROM videos ORDER BY folderPath');
    return maps.map((m) => m['folderPath'] as String).toList();
  }

  Future<List<VideoModel>> getVideosByFolder(String folderPath) async {
    final db = await database;
    final maps = await db.query(
      'videos',
      where: 'folderPath = ?',
      whereArgs: [folderPath],
      orderBy: 'name ASC',
    );
    return maps.map((map) => VideoModel.fromJson(map)).toList();
  }

  // ---------- 播放列表操作 ----------

  Future<List<Playlist>> getAllPlaylists() async {
    final db = await database;
    final maps = await db.query('playlists', orderBy: 'sortOrder ASC');
    return maps.map(_playlistFromRow).toList();
  }

  /// sqflite 只支持基本类型，videoIds 以 JSON 字符串存放
  Playlist _playlistFromRow(Map<String, dynamic> map) {
    final raw = map['videoIds'];
    var ids = <String>[];
    if (raw is String && raw.isNotEmpty) {
      try {
        ids = List<String>.from(jsonDecode(raw) as List);
      } catch (_) {
        ids = <String>[];
      }
    } else if (raw is List) {
      ids = List<String>.from(raw);
    }
    return Playlist(
      id: map['id'] as String,
      name: map['name'] as String,
      videoIds: ids,
      createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ??
          DateTime.now(),
      sortOrder: (map['sortOrder'] as int?) ?? 0,
      isAuto: ((map['isAuto'] as int?) ?? 0) == 1,
    );
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final db = await database;
    final map = playlist.toJson();
    // 关键：List 不能直接写库（会抛 unsupported type），序列化为字符串
    map['videoIds'] = jsonEncode(playlist.videoIds);
    map['isAuto'] = playlist.isAuto ? 1 : 0;
    await db.insert('playlists', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 删除所有「自动生成」的列表（每次扫描后重建）
  Future<void> deleteAutoPlaylists() async {
    final db = await database;
    await db.delete('playlists', where: 'isAuto = 1');
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  /// 把所有播放列表里指向这些视频的 id 剔掉并落库（自动列表 + 手动列表）
  ///
  /// 视频从影库移除后这些 id 永远播不了：手动列表不会重建，残留下来就是一条
  /// 点不开的黑条目。**列表本身保留**（剔空就变空列表），不能顺手删列表。
  /// 返回被改动的列表数。
  Future<int> stripVideoIdsFromPlaylists(Set<String> removedVideoIds) async {
    if (removedVideoIds.isEmpty) return 0;
    final playlists = await getAllPlaylists();
    var changed = 0;
    for (final playlist in playlists) {
      // 没变化返回 null → 不写库（列表多的时候别每次都全量重写）
      final updated = PlaylistPruneService.strip(playlist, removedVideoIds);
      if (updated == null) continue;
      await savePlaylist(updated);
      changed++;
    }
    return changed;
  }

  // ---------- 清理 ----------

  Future<void> removeVideosNotInPaths(List<String> existingPaths) async {
    final db = await database;
    final allVideos = await getAllVideos();
    // Set 查找 + 批量删除：原来用 List.contains（O(N²)）且每条一次事务，
    // 几千个视频时扫描会明显卡顿
    final keep = existingPaths.toSet();
    final toDelete = <String>[];
    for (final video in allVideos) {
      if (!keep.contains(video.path)) toDelete.add(video.id);
    }
    if (toDelete.isEmpty) return;
    final batch = db.batch();
    for (final id in toDelete) {
      batch.delete('videos', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  // ---------- 刮削缓存 ----------

  Future<void> upsertScrapeCache(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert('scrape_cache', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getScrapeCache(
      String searchKey, String type) async {
    final db = await database;
    final rows = await db.query('scrape_cache',
        where: 'search_key = ? AND type = ?',
        whereArgs: [searchKey, type],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> getScrapeCacheByPath(String videoPath) async {
    final db = await database;
    final rows = await db.query('scrape_cache',
        where: 'video_path = ?', whereArgs: [videoPath], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> getAllScrapeCache() async {
    final db = await database;
    return db.query('scrape_cache', orderBy: 'cached_at DESC');
  }

  Future<void> deleteScrapeCache(String searchKey, String type) async {
    final db = await database;
    await db.delete('scrape_cache',
        where: 'search_key = ? AND type = ?', whereArgs: [searchKey, type]);
  }
}
