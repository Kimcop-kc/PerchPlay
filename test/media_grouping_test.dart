// 自动分组测试（按**文件名**分到剧集列表）
//
// 需求要点：
//  - 分组只看文件名，不看文件夹名（不再用文件夹名兜底命名）
//  - 不再有「电影」列表：没有集数信息的视频不进任何自动列表
//  - 明确季集标记 → 一集也成列表；只有末尾序号 → 需要同类聚集才认
import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/services/media_grouping_service.dart';

void main() {
  group('明确季集标记', () {
    test('S01E01/02/03 归成一个列表并按季集排序', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E03.1080p.mkv',
        '/m/Show.S01E01.1080p.mkv',
        '/m/Show.S01E02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [1, 2, 0]);
    });

    test('中文 第N集', () {
      final groups = MediaGrouping.group([
        '/m/庆余年.第02集.mp4',
        '/m/庆余年.第01集.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '庆余年');
      expect(groups.first.indices, [1, 0]);
    });

    test('明确标记时一集也成列表', () {
      final groups = MediaGrouping.group(['/m/Show.S01E05.1080p.mkv']);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [0]);
    });

    test('Show.S01.01 / Show.S01.02（季单独成段）', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01.02.1080p.mkv',
        '/m/Show.S01.01.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show'); // S01 不残留在名字里
      expect(groups.first.indices, [1, 0]);
    });

    test('跨文件夹的同名剧集合成一个列表（只看文件名）', () {
      final groups = MediaGrouping.group([
        '/m/Season1/Show.S01E01.mkv',
        '/m/Season2/Show.S02E01.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices.length, 2);
    });

    test('大小写不同也算同一个剧集', () {
      final groups = MediaGrouping.group([
        '/m/show.S01E01.mkv',
        '/m/SHOW.S01E02.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.indices.length, 2);
    });
  });

  group('末尾序号（弱标记）', () {
    test('Show - 01 / Show - 02 有聚集 → 成列表', () {
      final groups = MediaGrouping.group([
        '/m/Show - 02 [1080p].mkv',
        '/m/Show - 01 [1080p].mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [1, 0]);
    });

    test('Show.02.1080p / Show.03.1080p 有聚集 → 成列表', () {
      final groups = MediaGrouping.group([
        '/m/Show.02.1080p.mkv',
        '/m/Show.03.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('孤立的 Rocky 2.mkv 不成列表（避免把电影当剧集）', () {
      final groups = MediaGrouping.group(['/m/Rocky 2.mkv']);
      expect(groups, isEmpty);
    });
  });

  group('不应进入任何列表', () {
    test('只有编号、没有剧名的文件（不看文件夹名）', () {
      final groups = MediaGrouping.group([
        '/m/MyShow/01.mp4',
        '/m/MyShow/02.mp4',
        '/m/MyShow/03.mp4',
      ]);
      expect(groups, isEmpty, reason: '文件名里没有剧名，按需求不分组');
    });

    test('电影（带年份/画质标签）', () {
      final groups = MediaGrouping.group([
        '/m/Interstellar.2014.1080p.BluRay.x264.mp4',
        '/m/Liuliang.Earth.2.2023.2160p.HDR.mp4',
        '/m/1917.2019.1080p.mkv',
        '/m/Se7en.mkv',
      ]);
      expect(groups, isEmpty);
    });

    test('剧集与电影混在一起时只出剧集列表', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E01.mkv',
        '/m/Show.S01E02.mkv',
        '/m/MovieA.2019.1080p.mkv',
        '/m/MovieB.2020.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [0, 1]);
    });

    test('单个普通视频', () {
      expect(MediaGrouping.group(['/m/test_video.mp4']), isEmpty);
    });
  });

  group('前缀识别（不依赖某种命名习惯）', () {
    test('巨人01 / 巨人02（编号紧贴，无分隔符）', () {
      final groups = MediaGrouping.group([
        '/m/进击的巨人01.mp4',
        '/m/进击的巨人02.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '进击的巨人');
      expect(groups.first.indices, [0, 1]);
    });

    test('Show01 / Show02', () {
      final groups = MediaGrouping.group([
        '/m/Show01.mkv',
        '/m/Show02.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('中文数字：第一集 / 第二集 / 第三集', () {
      final groups = MediaGrouping.group([
        '/m/庆余年 第三集.mp4',
        '/m/庆余年 第一集.mp4',
        '/m/庆余年 第二集.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '庆余年');
      expect(groups.first.indices, [1, 2, 0]);
    });

    test('前缀里的季标记不会污染列表名', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E01.mkv',
        '/m/Show.S02E01.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('发布组前缀被清掉：[Group] Show - 01 / 02', () {
      final groups = MediaGrouping.group([
        '/m/[Group] Show - 01 [1080p].mkv',
        '/m/[Group] Show - 02 [1080p].mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('片名带年份的电影不会因前缀相同而被当剧集', () {
      final groups = MediaGrouping.group([
        '/m/Liuliang.Earth.2.2023.2160p.HDR.mp4',
      ]);
      expect(groups, isEmpty);
    });

    test('编号开头文件 01 讲座 / 02 讲座 能归到同一组', () {
      final groups = MediaGrouping.group([
        '/m/01 讲座.mp4',
        '/m/02 讲座.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.indices.length, 2);
    });

    test('EP05 - Show 和 EP06 - Show 能归到同一组', () {
      final groups = MediaGrouping.group([
        '/m/EP05 - Great Show.mkv',
        '/m/EP06 - Great Show.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Great Show');
    });
  });
}
