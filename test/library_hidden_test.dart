// 「隐藏名单」（仅从影库移除、保留文件）的回归测试
//
// 背景：长按视频只有「从影库移除」时，只删数据库记录，下次全盘扫描会把
// 磁盘上还在的文件重新写回影库 —— 用户删了个寂寞。修法是移除时把路径记进
// 隐藏名单，扫描结果按名单过滤（并在写库之前过滤）。
//
// 这里钉的是纯逻辑部分：给定扫描结果 + 隐藏名单 → 保留/剔除的结果，
// 以及名单本身的持久化（SharedPreferences，和 autoAdded 等偏好项同一套写法）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/app_settings_service.dart';
import 'package:perchplay/services/library_hidden_service.dart';

VideoModel _video(String id, String path) => VideoModel(
      id: id,
      path: path,
      name: path.split('/').last,
      folderPath:
          path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '',
      size: 1024,
      durationMs: 60000,
      dateAdded: DateTime(2025, 1, 1),
      dateModified: DateTime(2025, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('扫描结果按隐藏名单过滤', () {
    test('名单里的路径被剔掉，其余保持原顺序', () {
      final videos = [
        _video('a', '/storage/emulated/0/Movies/a.mp4'),
        _video('b', '/storage/emulated/0/Movies/b.mp4'),
        _video('c', '/storage/emulated/0/DCIM/Camera/c.mp4'),
      ];
      final hidden = {'/storage/emulated/0/Movies/b.mp4'};

      final result = LibraryHiddenService.split(videos, hidden);

      expect(result.kept.map((v) => v.id).toList(), ['a', 'c']);
      expect(result.dropped.map((v) => v.id).toList(), ['b']);
    });

    test('空名单 → 一个都不剔除', () {
      final videos = [
        _video('a', '/storage/emulated/0/Movies/a.mp4'),
        _video('b', '/storage/emulated/0/Movies/b.mp4'),
      ];
      final result = LibraryHiddenService.split(videos, <String>{});
      expect(result.dropped, isEmpty);
      expect(result.kept.length, 2);
    });

    test('名单路径带首尾空白也能匹配上（录入时归一化）', () {
      final videos = [_video('a', '/storage/emulated/0/Movies/a.mp4')];
      final result = LibraryHiddenService.split(
        videos,
        {'  /storage/emulated/0/Movies/a.mp4  '},
      );
      expect(result.dropped.map((v) => v.id).toList(), ['a']);
    });

    test('Windows 盘符大小写不同视为同一文件（否则隐藏了又回来）', () {
      final videos = [_video('w', r'C:\Movies\Film.mp4')];
      expect(
        LibraryHiddenService.isHidden(
          r'C:\Movies\Film.mp4',
          {r'c:\movies\film.mp4'},
        ),
        isTrue,
      );
      // Android 路径区分大小写，不能一律转小写
      expect(
        LibraryHiddenService.isHidden(
          '/storage/emulated/0/Movies/A.mp4',
          {'/storage/emulated/0/Movies/a.mp4'},
        ),
        isFalse,
      );
      final result = LibraryHiddenService.split(
        videos,
        {r'c:\movies\film.mp4'},
      );
      expect(result.dropped.length, 1);
    });

    test('隐藏名单不会误伤同目录下的其它文件', () {
      final videos = [
        _video('a', '/storage/emulated/0/Movies/a.mp4'),
        _video('ab', '/storage/emulated/0/Movies/a.mp4.bak'),
      ];
      final result = LibraryHiddenService.split(
        videos,
        {'/storage/emulated/0/Movies/a.mp4'},
      );
      expect(result.kept.map((v) => v.id).toList(), ['ab']);
    });
  });

  test('名单持久化到 SharedPreferences，「全部恢复」后清空', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettingsService.instance;
    await settings.ensureLoaded();
    expect(settings.hiddenVideoCount, 0);

    await settings.hideVideoPath('/storage/emulated/0/Movies/a.mp4');
    await settings.hideVideoPath('  /storage/emulated/0/Movies/b.mp4  ');

    // 带空白的路径入库前会被归一化，所以是 2 个不重复项
    expect(settings.hiddenVideoCount, 2);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList(LibraryHiddenService.prefsKey),
      containsAll(<String>[
        '/storage/emulated/0/Movies/a.mp4',
        '/storage/emulated/0/Movies/b.mp4',
      ]),
    );

    await settings.restoreHiddenVideos();
    expect(settings.hiddenVideoCount, 0);
    expect(prefs.containsKey(LibraryHiddenService.prefsKey), isFalse,
        reason: '恢复后必须把这份名单从磁盘上清掉，否则下次冷启动又生效');
  });
}
