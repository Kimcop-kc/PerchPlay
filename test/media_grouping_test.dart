// 自动分组测试：剧集列表 / 电影列表的划分逻辑
// （文件名识别 + 文件夹回退 + 同类聚集 + 孤立剧集回落）
import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/services/media_grouping_service.dart';

void main() {
  group('明确标记的剧集', () {
    test('同剧集不同写法归成一个列表，并按季集排序', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E03.1080p.mkv',
        '/m/Show.S01E01.1080p.mkv',
        '/m/Show.S01E02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.isMovieBucket, isFalse);
      expect(groups.first.indices, [1, 2, 0]); // E01, E02, E03
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

    test('Show.S01.01 / Show.S01.02（季单独成段）', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01.02.1080p.mkv',
        '/m/Show.S01.01.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show'); // S01 不应残留在名字里
      expect(groups.first.indices, [1, 0]);
    });
  });

  group('文件夹回退（文件名里没有剧集名）', () {
    test('Movies/Show/01,02,03 聚成一个剧集，名字取文件夹名', () {
      final groups = MediaGrouping.group([
        '/storage/emulated/0/Movies/MyShow/01.mp4',
        '/storage/emulated/0/Movies/MyShow/02.mp4',
        '/storage/emulated/0/Movies/MyShow/03.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'MyShow');
      expect(groups.first.indices, [0, 1, 2]);
    });

    test('Show - 01 [1080p] 这类末尾序号也能识别', () {
      final groups = MediaGrouping.group([
        '/m/Series/Show - 02 [1080p].mkv',
        '/m/Series/Show - 01 [1080p].mkv',
      ]);
      expect(groups.length, 1);
      // 文件名里已经能看出剧集名，优先用它（而不是文件夹名 Series）
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [1, 0]);
    });

    test('同一目录下 Show.01 / Show.02 也能聚起来', () {
      final groups = MediaGrouping.group([
        '/m/Movies/Show.01.1080p.mkv',
        '/m/Movies/Show.02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [0, 1]);
    });
  });

  group('电影与误判保护', () {
    test('片名里带数字的电影不会被吞掉（Liuliang.Earth.2.2023）', () {
      final groups = MediaGrouping.group([
        '/m/Movies/Liuliang.Earth.2.2023.2160p.HDR.mp4',
        '/m/Movies/Interstellar.2014.1080p.BluRay.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.isMovieBucket, isTrue);
      expect(groups.first.name, '电影');
      expect(groups.first.indices.length, 2);
    });

    test('孤立的一集不建列表，回落进电影', () {
      final groups = MediaGrouping.group([
        '/m/Movies/Some.Show.S01E05.1080p.mkv', // 只有一集
        '/m/Movies/Movie.2019.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.isMovieBucket, isTrue);
      expect(groups.first.indices.length, 2);
    });

    test('剧集与电影共存时分成两个列表，电影桶排最后', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E01.mkv',
        '/m/Show.S01E02.mkv',
        '/m/MovieA.2019.1080p.mkv',
        '/m/MovieB.2020.1080p.mkv',
      ]);
      expect(groups.length, 2);
      expect(groups[0].name, 'Show');
      expect(groups[0].isMovieBucket, isFalse);
      expect(groups[1].isMovieBucket, isTrue);
      expect(groups[1].indices.length, 2);
    });

    test('只有 1 个视频时不生成任何列表', () {
      expect(MediaGrouping.group(['/m/Movies/Only.Movie.2019.mkv']), isEmpty);
    });

    test('通用目录名不会被当成剧集名', () {
      // /Movies/ 是通用目录：里面两个片子应进电影桶，而不是叫「Movies」的剧集
      final groups = MediaGrouping.group([
        '/storage/emulated/0/Movies/Film.One.2019.1080p.mkv',
        '/storage/emulated/0/Movies/Film.Two.2020.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.isMovieBucket, isTrue);
    });
  });
}
