// 自动列表「重建时套用用户手动增删」的回归测试
//
// 任务背景：刮削结果到达后会再重建一次自动列表（电影/剧集重分类）。
// 重建次数变多之后，用户手动加进来 / 移出去的记录更不能被冲掉，
// 被删掉的列表也不能又长回来。
// 这里直接测决定成员的那段纯逻辑（AppSettingsService.applyAutoOverrides）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/app_settings_service.dart';
import 'package:perchplay/services/video_source_service.dart';

VideoModel _video(String id, String path) => VideoModel(
      id: id,
      path: path,
      name: path.split('/').last,
      folderPath: '/sdcard/MyVideos',
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
    // AppSettingsService 是单例，跨测试会残留隐藏/增删记录，先复位
    await settings.restoreAutoPlaylists();
    await settings.clearAutoOverlays();
  });

  List<SourceGroup> seriesGroup() => const [
        SourceGroup(name: 'Show', indices: [0, 1], isSeries: true),
      ];

  test('自动列表 id 按类型 + 规范化名称生成', () {
    final videos = [
      _video('v1', '/sdcard/MyVideos/Show.S01E01.mkv'),
      _video('v2', '/sdcard/MyVideos/Show.S01E02.mkv'),
    ];
    final auto = settings.applyAutoOverrides(seriesGroup(), videos);
    expect(auto.length, 1);
    expect(auto.first.id, 'auto:series:show');
    expect(auto.first.videoIds, ['v1', 'v2']);
    expect(auto.first.isAuto, isTrue);
  });

  test('手动移出的视频不会在重建时长回来', () async {
    final videos = [
      _video('v1', '/sdcard/MyVideos/Show.S01E01.mkv'),
      _video('v2', '/sdcard/MyVideos/Show.S01E02.mkv'),
    ];
    await settings.markAutoRemoved('auto:series:show', 'v2');

    final auto = settings.applyAutoOverrides(seriesGroup(), videos);
    expect(auto.single.videoIds, ['v1']);
  });

  test('手动加入的视频会在重建后保留（即使不在该分组里）', () async {
    final videos = [
      _video('v1', '/sdcard/MyVideos/Show.S01E01.mkv'),
      _video('v2', '/sdcard/MyVideos/Show.S01E02.mkv'),
      _video('extra', '/sdcard/Movies/别的电影.2020.mkv'),
    ];
    await settings.markAutoAdded('auto:series:show', 'extra');

    final auto = settings.applyAutoOverrides(seriesGroup(), videos);
    expect(auto.single.videoIds, containsAll(['v1', 'v2', 'extra']));
  });

  test('手动加入的视频如果库里已经没有（文件删了）就丢弃', () async {
    final videos = [_video('v1', '/sdcard/MyVideos/Show.S01E01.mkv')];
    await settings.markAutoAdded('auto:series:show', 'gone');

    final auto = settings.applyAutoOverrides(seriesGroup(), videos);
    expect(auto.single.videoIds, ['v1']);
  });

  test('手动加入又被移出的视频不会回来', () async {
    final videos = [
      _video('v1', '/sdcard/MyVideos/Show.S01E01.mkv'),
      _video('v2', '/sdcard/MyVideos/Show.S01E02.mkv'),
    ];
    await settings.markAutoAdded('auto:series:show', 'v2');
    await settings.markAutoRemoved('auto:series:show', 'v2');

    final auto = settings.applyAutoOverrides(seriesGroup(), videos);
    expect(auto.single.videoIds, ['v1']);
  });

  test('被删掉的自动列表不再重建', () async {
    final videos = [
      _video('v1', '/sdcard/MyVideos/Show.S01E01.mkv'),
      _video('v2', '/sdcard/MyVideos/Show.S01E02.mkv'),
    ];
    await settings.hideAutoPlaylist('auto:series:show');

    expect(settings.applyAutoOverrides(seriesGroup(), videos), isEmpty);
  });

  test('成员被移空的列表直接消失（重分类后旧剧集组不会留空壳）', () async {
    final videos = [_video('v1', '/sdcard/MyVideos/Show.S01E01.mkv')];
    await settings.markAutoRemoved('auto:series:show', 'v1');

    expect(settings.applyAutoOverrides(seriesGroup(), videos), isEmpty);
  });

  test('电影组用 movie 前缀 id，且与剧集组互不影响', () {
    final videos = [
      _video('m1', '/sdcard/Movies/流浪地球2.2023.mkv'),
      _video('m2', '/sdcard/Movies/Interstellar.2014.mkv'),
    ];
    final groups = [
      const SourceGroup(
        name: VideoSourceService.movieGroupName,
        indices: [0, 1],
        isMovie: true,
      ),
    ];

    final auto = settings.applyAutoOverrides(groups, videos);
    // normalize 会去掉空格：'🎬 电影' → '🎬电影'
    expect(auto.single.id, 'auto:movie:🎬电影');
    expect(auto.single.name, VideoSourceService.movieGroupName);
    expect(auto.single.videoIds, ['m1', 'm2']);
  });
}
