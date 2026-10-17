import 'dart:io';

import '../models/video_model.dart';

/// 影库里「文件已经不在磁盘上」的清理判断。
///
/// 为什么单独抽出来：
///  - 回前台/冷启动时要把整个影库过一遍，必须很便宜（只 `existsSync`，
///    不做目录遍历、不做全盘重扫）；
///  - 判断里最容易写错的是「网络来源不能按本地文件判存在」，这部分抽成
///    纯逻辑才能写单测（[findMissing] 的 exists 回调可注入，不碰真实盘）。
class LibraryPruneService {
  LibraryPruneService._();

  /// 会被当成「网络/远程来源」的路径前缀
  ///
  /// 说明现状：能进 `videos` 表的 path 目前**只有本地绝对路径**
  /// （扫描器产出的是 `/storage/emulated/0/...`、`C:\...`；NAS 页面是直接
  /// 读取播放，不写影库），所以下面的判断眼下不会命中。
  /// 之所以仍然保留：`File('smb://...').existsSync()` 一定是 false，
  /// 一旦以后把 NAS/远程源加进影库，回前台的清理会**把整个网络影库当成
  /// 已删除全部清掉** —— 这类误删代价太大，必须提前挡住。
  static const remoteSchemes = <String>[
    'http://',
    'https://',
    'smb://',
    'ftp://',
    'sftp://',
    'nfs://',
    'rtsp://',
    // Android 的 content:// 也是「系统托管」，本地 stat 不可信
    'content://',
  ];

  /// 是否可能是网络/远程地址（这类地址不能用本地文件存在性判断）
  static bool isRemotePath(String path) {
    final lower = path.trim().toLowerCase();
    if (lower.isEmpty) return false;
    for (final scheme in remoteSchemes) {
      if (lower.startsWith(scheme)) return true;
    }
    // Windows UNC（`\\server\share`）：文件在服务器上，本地 stat 不可信
    return lower.startsWith(r'\\');
  }

  /// 挑出「文件已经不存在」的视频
  ///
  /// 网络来源一律跳过，不能误判成已删除。[exists] / [dirExists] 可注入，
  /// 单测用它们替代真实文件系统（`File.existsSync` 在 CI 上没有意义的路径）。
  ///
  /// 判断规则（比"整库都判为不存在就跳过"更准确）：
  ///   - 文件还在 → 不算缺失；
  ///   - 文件不在、但**父目录还能访问** → 认定文件确实被删了，可以剔除；
  ///   - 连父目录都访问不到 → 多半是读权限被撤 / SD 卡没挂载 / 存储暂时
  ///     不可用的异常情况，跳过这条，避免误删。
  /// 这样「只有一个视频的影库」把文件删了也能正常剔除，而权限异常时
  /// 依然不会把整库清空。
  static List<VideoModel> findMissing(
    List<VideoModel> videos, {
    bool Function(String path)? exists,
    bool Function(String path)? dirExists,
  }) {
    final fileCheck = exists ?? (String path) => File(path).existsSync();
    final dirCheck =
        dirExists ?? (String path) => File(path).parent.existsSync();
    final missing = <VideoModel>[];
    for (final video in videos) {
      if (isRemotePath(video.path)) continue;
      if (fileCheck(video.path)) continue;
      // 文件没了但目录还在 = 真删了；目录都进不去 = 存储/权限异常，放过
      if (!dirCheck(video.path)) continue;
      missing.add(video);
    }
    return missing;
  }
}
