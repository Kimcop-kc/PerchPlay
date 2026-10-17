// 「自动列表排序：电影 / 剧集在前，杂项在后」的回归测试
//
// 现状：自动列表的 sortOrder 直接按 groupAll 的返回顺序编号，而 groupAll 里
// 「电影」集合是最后才加进去的，个人来源分组在最前面 —— 列表页看起来就是
// 随手拍/录屏排在电影、剧集前面。这里钉住优先级，并保证：
//   - 同一优先级内保持 groupAll 的原始相对顺序（稳定）；
//   - sortOrder 仍然整体为负，排在手动列表（默认 0）之前。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/app_settings_service.dart';
import 'package:perchplay/services/video_source_service.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = AppSettingsService.instance;
    await settings.ensureLoaded();
    // 单例会跨测试残留「隐藏/手动增删」记录，先复位
    await settings.restoreAutoPlaylists();
    await settings.clearAutoOverlays();
  });

  test('电影 → 剧集 → 其它（兜底/个人），同类内保持原始顺序', () {
    final videos = [
      _video('p1', '/storage/emulated/0/DCIM/Camera/IMG_1.mp4'),
      _video('p2', '/storage/emulated/0/DCIM/Camera/IMG_2.mp4'),
      _video('s1', '/storage/emulated/0/Movies/ShowA.S01E01.mkv'),
      _video('s2', '/storage/emulated/0/Movies/ShowA.S01E02.mkv'),
      _video('s3', '/storage/emulated/0/Movies/ShowB.S01E01.mkv'),
      _video('f1', '/storage/emulated/0/Download/Trip01.mp4'),
      _video('f2', '/storage/emulated/0/Download/Trip02.mp4'),
      _video('m1', '/storage/emulated/0/Movies/Interstellar.2014.mkv'),
    ];

    // 故意按「个人 → 剧集 → 兜底 → 电影」这种 groupAll 的产出来排，
    // 验证排序真的按类型重排，而不是原样照抄
    final groups = [
      const SourceGroup(name: '📷 相机', indices: [0, 1]),
      const SourceGroup(name: 'ShowA', indices: [2, 3], isSeries: true),
      const SourceGroup(name: 'ShowB', indices: [4], isSeries: true),
      const SourceGroup(name: '📂 Trip', indices: [5, 6], isFallback: true),
      const SourceGroup(
        name: VideoSourceService.movieGroupName,
        indices: [7],
        isMovie: true,
      ),
    ];

    final auto = settings.applyAutoOverrides(groups, videos);
    expect(auto.map((p) => p.name).toList(), [
      VideoSourceService.movieGroupName, // 电影优先
      'ShowA', // 剧集其次，且保持原有先后（ShowA 在 ShowB 前）
      'ShowB',
      '📷 相机', // 杂项最后，依然是原始顺序
      '📂 Trip',
    ]);
  });

  test('sortOrder 递增且全为负（手动列表默认 0，永远排在自动列表之后）', () {
    final videos = [
      _video('m1', '/storage/emulated/0/Movies/Interstellar.2014.mkv'),
      _video('s1', '/storage/emulated/0/Movies/ShowA.S01E01.mkv'),
      _video('p1', '/storage/emulated/0/DCIM/Camera/IMG_1.mp4'),
    ];
    final groups = [
      const SourceGroup(name: '📷 相机', indices: [2]),
      const SourceGroup(name: 'ShowA', indices: [1], isSeries: true),
      const SourceGroup(
        name: VideoSourceService.movieGroupName,
        indices: [0],
        isMovie: true,
      ),
    ];

    final auto = settings.applyAutoOverrides(groups, videos);
    expect(auto.length, 3);
    expect(auto.first.name, VideoSourceService.movieGroupName);
    for (var i = 1; i < auto.length; i++) {
      expect(auto[i].sortOrder, greaterThan(auto[i - 1].sortOrder));
    }
    for (final p in auto) {
      expect(p.sortOrder, lessThan(0));
    }
  });

  test('同一优先级内保持 groupAll 的原始顺序（稳定排序）', () {
    final videos = [
      _video('s1', '/storage/emulated/0/Movies/ShowB.S01E01.mkv'),
      _video('s2', '/storage/emulated/0/Movies/ShowA.S01E01.mkv'),
      _video('s3', '/storage/emulated/0/Movies/ShowC.S01E01.mkv'),
    ];
    final groups = [
      const SourceGroup(name: 'ShowB', indices: [0], isSeries: true),
      const SourceGroup(name: 'ShowA', indices: [1], isSeries: true),
      const SourceGroup(name: 'ShowC', indices: [2], isSeries: true),
    ];

    final auto = settings.applyAutoOverrides(groups, videos);
    expect(auto.map((p) => p.name).toList(), ['ShowB', 'ShowA', 'ShowC']);
  });
}
