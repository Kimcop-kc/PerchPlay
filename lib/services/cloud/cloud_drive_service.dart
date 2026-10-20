import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/cloud_drive_model.dart';
import 'aliyun_drive_client.dart';
import 'baidu_drive_client.dart';
import 'pan115_drive_client.dart';
import 'quark_drive_client.dart';

/// 云盘统一入口。
///
/// 各家协议差异很大（夸克用 fid 树、115 用 cid、百度用路径、阿里用 file_id），
/// 这里只统一「连接 / 列目录 / 取直链」三件事，其余交给各自 client。
class CloudDriveService {
  CloudDriveService._();
  static final instance = CloudDriveService._();

  static const _kAccounts = 'cloud.accounts';

  List<CloudDriveAccount> _accounts = [];
  List<CloudDriveAccount> get accounts => List.unmodifiable(_accounts);

  bool _loaded = false;

  // 当前活跃的连接对象（按需创建）
  QuarkDriveClient? _quark;
  Pan115DriveClient? _pan115;
  BaiduDriveClient? _baidu;
  AliyunDriveClient? _aliyun;

  /// 阿里云盘开放平台凭据（可选）
  String _aliyunClientId = '';
  String _aliyunClientSecret = '';
  String get aliyunClientId => _aliyunClientId;

  // ──────────── 持久化 ────────────

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kAccounts);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          _accounts = list
              .whereType<Map>()
              .map((e) =>
                  CloudDriveAccount.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      }
      _aliyunClientId = prefs.getString('cloud.aliyunClientId') ?? '';
      _aliyunClientSecret = prefs.getString('cloud.aliyunClientSecret') ?? '';
    } catch (e) {
      debugPrint('[Cloud] 加载失败: $e');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kAccounts,
        jsonEncode(_accounts.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[Cloud] 保存失败: $e');
    }
  }

  Future<void> setAliyunCredentials(String id, String secret) async {
    _aliyunClientId = id.trim();
    _aliyunClientSecret = secret.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cloud.aliyunClientId', _aliyunClientId);
      await prefs.setString('cloud.aliyunClientSecret', _aliyunClientSecret);
    } catch (_) {}
  }

  // ──────────── 账号管理 ────────────

  /// 添加账号。
  ///
  /// 同一个云盘**只保留一条**：id 是时间戳生成的，若只按 id 去重，
  /// 用户每次重新登录都会多出一条，列表越用越乱。这里按 [type] 覆盖。
  Future<void> addAccount(CloudDriveAccount acc) async {
    _accounts = [
      ..._accounts.where((e) => e.id != acc.id && e.type != acc.type),
      acc,
    ];
    await _save();
  }

  Future<void> removeAccount(String id) async {
    _accounts = _accounts.where((e) => e.id != id).toList();
    await _save();
  }

  Future<void> updateAccount(CloudDriveAccount acc) async {
    final i = _accounts.indexWhere((e) => e.id == acc.id);
    if (i >= 0) {
      final next = [..._accounts];
      next[i] = acc;
      _accounts = next;
      await _save();
    }
  }

  // ──────────── 连接 ────────────

  /// 测试连接并返回昵称（null = 失败）。
  Future<String?> testConnection(CloudDriveAccount acc) async {
    _disposeClients();
    switch (acc.type) {
      case CloudDriveType.quark:
        _quark = QuarkDriveClient(acc);
        return _quark!.connect();
      case CloudDriveType.pan115:
        _pan115 = Pan115DriveClient(acc);
        return _pan115!.connect();
      case CloudDriveType.baidu:
        _baidu = BaiduDriveClient(acc);
        return _baidu!.connect();
      case CloudDriveType.aliyun:
        _aliyun = AliyunDriveClient(
          acc,
          clientId: _aliyunClientId,
          clientSecret: _aliyunClientSecret,
        );
        return _aliyun!.connect();
    }
  }

  /// 建立某账号的连接（供浏览页使用）。
  Future<String?> connect(CloudDriveAccount acc) async {
    _disposeClients();
    switch (acc.type) {
      case CloudDriveType.quark:
        _quark = QuarkDriveClient(acc);
        return _quark!.connect();
      case CloudDriveType.pan115:
        _pan115 = Pan115DriveClient(acc);
        return _pan115!.connect();
      case CloudDriveType.baidu:
        _baidu = BaiduDriveClient(acc);
        return _baidu!.connect();
      case CloudDriveType.aliyun:
        _aliyun = AliyunDriveClient(
          acc,
          clientId: _aliyunClientId,
          clientSecret: _aliyunClientSecret,
        );
        return _aliyun!.connect();
    }
  }

  /// 列目录。
  ///
  /// [dirId] 含义按云盘不同：
  ///  - 夸克：fid（根 `'0'`）
  ///  - 115 ：cid（根 `'0'`）
  ///  - 百度：绝对路径（根 `'/'`）
  ///  - 阿里：file_id（根 `'root'`）
  Future<List<CloudFileItem>?> listDirectory(
    CloudDriveType type,
    String dirId, {
    String parentPath = '/',
  }) async {
    try {
      switch (type) {
        case CloudDriveType.quark:
          return await _quark?.listDirectory(dirId, parentPath: parentPath);
        case CloudDriveType.pan115:
          return await _pan115?.listDirectory(dirId, parentPath: parentPath);
        case CloudDriveType.baidu:
          return await _baidu?.listDirectory(dirId, parentPath: parentPath);
        case CloudDriveType.aliyun:
          return await _aliyun?.listDirectory(dirId, parentPath: parentPath);
      }
    } catch (e) {
      debugPrint('[Cloud] listDirectory 失败: $e');
      return null;
    }
  }

  /// 取文件直链（播放用）。
  Future<String?> getDownloadUrl(CloudDriveType type, String fileId) async {
    try {
      switch (type) {
        case CloudDriveType.quark:
          return await _quark?.getDownloadUrl(fileId);
        case CloudDriveType.pan115:
          return await _pan115?.getDownloadUrl(fileId);
        case CloudDriveType.baidu:
          return await _baidu?.getDownloadUrl(fileId);
        case CloudDriveType.aliyun:
          return await _aliyun?.getDownloadUrl(fileId);
      }
    } catch (e) {
      debugPrint('[Cloud] getDownloadUrl 失败: $e');
      return null;
    }
  }

  void _disposeClients() {
    _quark?.dispose();
    _pan115?.dispose();
    _baidu?.dispose();
    _aliyun?.dispose();
    _quark = null;
    _pan115 = null;
    _baidu = null;
    _aliyun = null;
  }

  /// 释放底层连接（不动已保存的账号）。
  ///
  /// 页面退出时调用。下次 [connect] 会重新创建 client，
  /// 账号列表仍从 SharedPreferences 读，不受影响。
  void dispose() => _disposeClients();
}
