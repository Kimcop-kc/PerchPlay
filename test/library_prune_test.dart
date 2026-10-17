// 「回前台剔除已消失文件」的回归测试
//
// 背景：在手机里把视频文件删掉后，数据库里还有记录，首页会一直挂一张
// 点不开的卡片。清理逻辑必须满足三点：
//   1. 文件不存在的要挑出来（交给上层从列表/数据库剔除）；
//   2. 网络来源（NAS / 远程播放源）不能按本地文件判存在——
//      `File('smb://...').existsSync()` 恒为 false，误判会把网络影库清空；
//   3. 只有「文件不在 + 父目录还能访问」才算真删了。父目录都读不到时
//      多半是读权限被撤 / SD 卡没挂载，必须放过（否则整库被误删）。
//      这条规则同时让「只有一个视频的影库」能正常自动剔除。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/library_prune_service.dart';

VideoModel _video(String id, String path) => VideoModel(
      id: id,
      path: path,
      name: path.split('/').last,
      folderPath: '/storage/emulated/0/Movies',
      size: 1024,
      durationMs: 60000,
      dateAdded: DateTime(2025, 1, 1),
      dateModified: DateTime(2025, 1, 1),
    );

void main() {
  test('只挑出「文件已经不存在」的本地视频', () {
    final videos = [
      _video('ok1', '/storage/emulated/0/Movies/a.mp4'),
      _video('gone1', '/storage/emulated/0/Movies/b.mp4'),
      _video('ok2', '/storage/emulated/0/DCIM/Camera/c.mp4'),
      _video('gone2', '/storage/emulated/0/Movies/d.mp4'),
    ];
    // 注入假的存在性判断，不碰真实文件系统
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (path) => !path.endsWith('b.mp4') && !path.endsWith('d.mp4'),
      dirExists: (_) => true,
    );

    expect(missing.map((v) => v.id).toList(), ['gone1', 'gone2']);
  });

  test('全部文件都在时返回空列表（上层据此不刷新界面）', () {
    final videos = [
      _video('v1', '/storage/emulated/0/Movies/a.mp4'),
      _video('v2', '/storage/emulated/0/Movies/b.mp4'),
    ];
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (_) => true,
      dirExists: (_) => true,
    );
    expect(missing, isEmpty);
  });

  test('网络来源一律跳过存在性检查，不会被当成已删除', () {
    final videos = [
      _video('http', 'https://example.com/a.mp4'),
      _video('smb', 'smb://nas/media/movie.mkv'),
      _video('ftp', 'ftp://192.168.1.2/movie.mkv'),
      _video('unc', r'\\NAS\share\movie.mkv'),
      _video('content', 'content://media/external/video/media/42'),
      _video('localGone', '/storage/emulated/0/Movies/b.mp4'),
    ];
    var checks = 0;
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (path) {
        checks++;
        return false; // 所有本地路径都判为不存在
      },
      dirExists: (_) => true,
    );

    // 只检查了那一个本地路径，网络来源一个都没问
    expect(checks, 1);
    expect(missing.map((v) => v.id).toList(), ['localGone']);
  });

  test('isRemotePath 识别常见网络协议与 UNC 路径', () {
    expect(LibraryPruneService.isRemotePath('http://x/y.mp4'), isTrue);
    expect(LibraryPruneService.isRemotePath('HTTPS://x/y.mp4'), isTrue);
    expect(LibraryPruneService.isRemotePath('smb://nas/y.mkv'), isTrue);
    expect(LibraryPruneService.isRemotePath(r'\\NAS\share\y.mkv'), isTrue);

    expect(LibraryPruneService.isRemotePath('/storage/emulated/0/y.mp4'),
        isFalse);
    expect(LibraryPruneService.isRemotePath(r'C:\Users\a\y.mp4'), isFalse);
    expect(LibraryPruneService.isRemotePath(''), isFalse);
  });

  test('空影库不会产出任何待删项', () {
    expect(
      LibraryPruneService.findMissing([], exists: (_) => false),
      isEmpty,
    );
  });

  // ── 追加的「逐个判断父目录」规则 ──

  test('只有一个视频的影库，文件删了也要能剔除（不再整库跳过）', () {
    final videos = [_video('only', '/storage/emulated/0/Movies/only.mp4')];
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (_) => false, // 文件确实没了
      dirExists: (_) => true, // 但 Movies 目录还在 → 是真删了
    );
    expect(missing.map((v) => v.id).toList(), ['only']);
  });

  test('父目录也访问不到时跳过：权限被撤 / SD 卡未挂载不能误删', () {
    final videos = [
      _video('sd1', '/storage/1234-ABCD/Movies/a.mp4'),
      _video('sd2', '/storage/1234-ABCD/Movies/b.mp4'),
    ];
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (_) => false, // 没权限时 existsSync 对共享存储一律 false
      dirExists: (_) => false, // SD 卡没挂载，父目录也不存在
    );
    expect(missing, isEmpty, reason: '整个存储都读不到时应放弃清理');
  });

  test('混合情况：目录可访问的剔除，目录不可访问的保留', () {
    final videos = [
      _video('local', '/storage/emulated/0/Movies/deleted.mp4'),
      _video('unmounted', '/storage/FFFF-0000/Movies/gone.mp4'),
    ];
    final missing = LibraryPruneService.findMissing(
      videos,
      exists: (_) => false,
      dirExists: (path) => !path.startsWith('/storage/FFFF-0000'),
    );
    expect(missing.map((v) => v.id).toList(), ['local']);
  });
}
