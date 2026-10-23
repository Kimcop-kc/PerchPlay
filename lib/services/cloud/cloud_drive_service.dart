import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/cloud_drive_model.dart';
import 'aliyun_drive_client.dart';
import 'baidu_drive_client.dart';
import 'pan115_drive_client.dart';
import 'quark_drive_client.dart';
import 'stream_proxy_server.dart';

/// 云盘统一入口。
///
/// 各家协议差异很大（夸克用 fid 树、115 用 cid、百度用路径、阿里用 file_id），
/// 这里只统一「连接 / 列目录 / 取直链」三件事，其余交给各自 client。
///
/// ## 多账号支持
/// v1.0.96 之前每种类型只有一个 client 槽（如 `_quark`），第二个同类型登录会
/// 把第一个 dispose 掉，导致两个夸克不能同时用。现在改用 `Map<accountId, client>`
/// 连接池，每个账号独立一个 client，切换不互相影响。
class CloudDriveService {
  CloudDriveService._();
  static final instance = CloudDriveService._();

  static const _kAccounts = 'cloud.accounts';

  List<CloudDriveAccount> _accounts = [];
  List<CloudDriveAccount> get accounts => List.unmodifiable(_accounts);

  bool _loaded = false;

  // 每个账号一个独立 client（按 accountId 索引）
  // 用 dynamic 因为各 client 在不同文件，无法实现私有抽象接口
  final Map<String, dynamic> _clients = {};

  /// 阿里云盘开放平台凭据（可选）
  String _aliyunClientId = '';
  String _aliyunClientSecret = '';
  String get aliyunClientId => _aliyunClientId;
  Future<void> setAliyunCredentials(String id, String secret) async {
    _aliyunClientId = id.trim();
    _aliyunClientSecret = secret.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cloud.aliyunClientId', _aliyunClientId);
      await prefs.setString('cloud.aliyunClientSecret', _aliyunClientSecret);
    } catch (_) {}
  }

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

  // ──────────── 账号管理 ────────────

  /// 添加账号。按 [id] 去重，允许同类型多个账号。
  Future<void> addAccount(CloudDriveAccount acc) async {
    _accounts = [
      ..._accounts.where((e) => e.id != acc.id),
      acc,
    ];
    await _save();
  }

  Future<void> removeAccount(String id) async {
    _accounts = _accounts.where((e) => e.id != id).toList();
    _clients[id]?.dispose();
    _clients.remove(id);
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

  // ──────────── 连接（按 accountId） ────────────

  /// 建立某账号的连接（返回昵称，null = 失败）。
  ///
  /// 每次都会重建 client：Cookie / token 可能在外部（WebView 重新登录）更新，
  /// 复用旧 client 会一直拿着过期的凭证。重建成本只是 new 一个对象 +
  /// 一次网络请求，可以接受。
  ///
  /// 注：这里原来有个 `if (existing != null) return _connectClient(acc);`
  /// 的分支，但它和 else 走的是同一句，等于「看起来在复用、其实每次重建」。
  /// 已删掉那个误导性的判断。
  Future<String?> connect(CloudDriveAccount acc) async {
    return _connectClient(acc);
  }

  /// 断开某个账号的连接（页面退出时调用）。
  void disconnect(String accountId) {
    _clients[accountId]?.dispose();
    _clients.remove(accountId);
  }

  Future<String?> _connectClient(CloudDriveAccount acc) async {
    // 先 dispose 旧的同 id client
    try {
      (_clients[acc.id] as dynamic).dispose();
    } catch (_) {}
    _clients.remove(acc.id);

    dynamic client;
    switch (acc.type) {
      case CloudDriveType.quark:
        client = QuarkDriveClient(acc);
        break;
      case CloudDriveType.pan115:
        client = Pan115DriveClient(acc);
        break;
      case CloudDriveType.baidu:
        client = BaiduDriveClient(acc);
        break;
      case CloudDriveType.aliyun:
        client = AliyunDriveClient(
          acc,
          clientId: _aliyunClientId,
          clientSecret: _aliyunClientSecret,
        );
        break;
    }

    // ⚠ 先注册再 connect，而不是等 connect 成功后才注册。
    //
    // 原因：`connect()` 失败时（典型是 Cookie 过期 → errno=-6），
    // 我们需要通过 [lastErrorHint] 把失败的 client 上记录的 errno 读出来。
    // 原来存的是「connect 成功才放进 _clients」，失败路径下 client 根本没
    // 入表，lastErrorHint 永远返回空串，UI 只能退化成笼统提示 ——
    // 那条按 errno 区分原因的修复等于白做。
    _clients[acc.id] = client;
    final nick = await client.connect();
    return nick;
  }

  /// 列目录。
  ///
  /// [accountId] 是账号 id（不是 type）。
  /// [dirId] 含义按云盘不同：
  ///  - 夸克：fid（根 `'0'`）
  ///  - 115 ：cid（根 `'0'`）
  ///  - 百度：绝对路径（根 `'/'`）
  ///  - 阿里：file_id（根 `'root'`）
  Future<List<CloudFileItem>?> listDirectory(
    String accountId,
    String dirId, {
    String parentPath = '/',
  }) async {
    try {
      final c = _clients[accountId];
      if (c == null) return null;
      return await c.listDirectory(dirId, parentPath: parentPath);
    } catch (e) {
      debugPrint('[Cloud] listDirectory 失败: $e');
      return null;
    }
  }

  /// 最近一次失败的人话说明（供 UI 展示真实原因）。
  ///
  /// 之前无论什么错误都提示「登录可能已过期」，用户被误导着反复重新登录；
  /// 实际上可能是「目录不存在」或「账号被限」。
  String lastErrorHint(String accountId) {
    final c = _clients[accountId];
    if (c is BaiduDriveClient) {
      final errno = c.lastErrno;
      switch (errno) {
        case -6:
          return '百度账号未登录或登录已过期。请删除该云盘后重新添加并完成登录。';
        case -7:
        case -9:
          return '该目录不存在（可能已被删除或改名）。请返回上一级重试。';
        case 31066:
          return '百度账号受限：需要在百度网盘完成实名认证或解除限制。';
        case 2:
          return '请求参数错误，请重新添加云盘。';
        default:
          if (errno != null) {
            return '百度返回错误码 $errno'
                '${c.lastErrmsg.isEmpty ? '' : '：${c.lastErrmsg}'}';
          }
      }
    }
    if (c is QuarkDriveClient) {
      final errno = c.lastErrno;
      if (errno != null) {
        // 夸克常见的认证失效码
        if (errno == 31001 || errno == 401 || errno == 403) {
          return '夸克账号登录已过期。请删除该云盘后重新添加并完成登录。';
        }
        return '夸克返回错误码 $errno'
            '${c.lastErrmsg.isEmpty ? '' : '：${c.lastErrmsg}'}';
      }
    }
    return '';
  }

  /// 取文件直链（播放用）。
  Future<String?> getDownloadUrl(String accountId, String fileId) async {
    try {
      final c = _clients[accountId];
      if (c == null) return null;
      return await c.getDownloadUrl(fileId);
    } catch (e) {
      debugPrint('[Cloud] getDownloadUrl 失败: $e');
      return null;
    }
  }

  /// 取某个账号「当前生效」的 Cookie。
  ///
  /// 夸克会在响应里轮换 `__pus`/`__puus`，播放时必须用轮换后的最新值，
  /// 而不是登录时抓到的旧值，否则 CDN 会 403。
  /// 其他网盘直接返回账号里存的 cookie。
  String currentCookie(String accountId) {
    final c = _clients[accountId];
    if (c is QuarkDriveClient) {
      try {
        return c.cookie;
      } catch (_) {}
    }
    return '';
  }

  /// 取阿里云盘当前 access_token（播放时作为 Authorization 头）。
  ///
  /// 阿里直链虽然自带签名，但部分账号/文件仍要求带 Bearer 头，
  /// 不带就会 403。其它云盘返回 null（它们靠 Cookie）。
  Future<String?> currentAccessToken(String accountId) async {
    final c = _clients[accountId];
    if (c is AliyunDriveClient) {
      try {
        return await c.currentToken();
      } catch (_) {}
    }
    return null;
  }

  /// 取 115 直链时服务端下发的附加 Cookie（形如 `k=v`，可能为空）。
  ///
  /// 115 直链 URL 里的 `f` 参数决定播放校验要求，`f=3` 时必须带上这个
  /// Cookie，否则 403。其它云盘返回空串。
  String currentExtraCookie(String accountId) {
    final c = _clients[accountId];
    if (c is Pan115DriveClient) {
      try {
        return c.lastSetCookie;
      } catch (_) {}
    }
    return '';
  }

  // ──────────── 串流代理 ────────────

  /// 当前活跃的串流代理（同一时间只服务一个播放）。
  StreamProxyServer? _stream;

  /// 为某个文件启动本地串流代理，返回播放器可用的 URL。
  ///
  /// 为什么不直接把直链给播放器：
  ///  - mpv 发 Range 请求时不会带 Cookie/UA，CDN 分块校验会 403
  ///  - 拿不到 CDN 的 Set-Cookie 轮换，也校验不了 206
  ///  - 控制不了并发，对已限速的网盘反而更慢
  ///
  /// 代理层把这些全接管后，mpv 只需要连 `127.0.0.1`。
  ///
  /// 返回 null 表示启动失败（调用方应退回直链播放）。
  Future<String?> startStreamProxy(
    String accountId,
    String fileId, {
    required Map<String, String> Function() headers,
  }) async {
    await stopStreamProxy();
    try {
      final server = await StreamProxyServer.start(
        resolveUrl: () => getDownloadUrl(accountId, fileId),
        headers: headers,
      );
      _stream = server;
      final url = server.urlFor();
      debugPrint('[Cloud] 串流代理已启动: $url');
      return url;
    } catch (e) {
      debugPrint('[Cloud] 启动串流代理失败: $e');
      return null;
    }
  }

  /// 停止当前串流代理（换片 / 退出播放时调用）。
  Future<void> stopStreamProxy() async {
    final s = _stream;
    _stream = null;
    if (s != null) {
      try {
        await s.stop();
      } catch (_) {}
    }
  }

  /// 释放所有底层连接（App 退出时调用）。
  void dispose() {
    for (final c in _clients.values) {
      c.dispose();
    }
    _clients.clear();
  }
}