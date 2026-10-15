import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/video_model.dart';
import '../models/playlist_model.dart';

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
      version: 2,
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
        sortOrder INTEGER DEFAULT 0
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
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 的 videos 表没有 lastPlayed 列，补上
      await db.execute('ALTER TABLE videos ADD COLUMN lastPlayed TEXT');
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
    final maps =
        await db.query('videos', where: 'path = ?', whereArgs: [path], limit: 1);
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
              durationMs: video.durationMs > 0 ? video.durationMs : old.durationMs,
            );
      batch.insert('videos', merged.toJson(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 删除单条视频记录（不删除磁盘文件）
  Future<void> deleteVideo(String id) async {
    final db = await database;
    await db.delete('videos', where: 'id = ?', whereArgs: [id]);
    await db.delete('playback_history', where: 'videoId = ?', whereArgs: [id]);
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
    final maps = await db.rawQuery(
        'SELECT DISTINCT folderPath FROM videos ORDER BY folderPath');
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
    return maps.map((map) => Playlist.fromJson(map)).toList();
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final db = await database;
    await db.insert('playlists', playlist.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deletePlaylist(String id) async {
    final db = await database;
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  // ---------- 清理 ----------

  Future<void> removeVideosNotInPaths(List<String> existingPaths) async {
    final db = await database;
    // 简单处理：传入当前存在的路径列表，清理不存在于列表的记录
    final allVideos = await getAllVideos();
    for (final video in allVideos) {
      if (!existingPaths.contains(video.path)) {
        await db.delete('videos', where: 'id = ?', whereArgs: [video.id]);
      }
    }
  }
}