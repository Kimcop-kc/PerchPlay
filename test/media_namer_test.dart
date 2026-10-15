// 文件名识别测试：自动分组（剧集列表 / 电影列表）全靠它，
// 分类错了会直接把片子归错列表，这里把常见写法都钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/services/media_namer_service.dart';

void main() {
  group('剧集识别', () {
    test('S01E02 标准写法', () {
      final info = MediaNamer.parse('/x/Show.S01E02.1080p.WEB-DL.x265.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.season, 1);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'Show');
    });

    test('小写 s01e02', () {
      final info = MediaNamer.parse('/x/my.show.s01e02.mkv');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'my show');
    });

    test('1x02 写法', () {
      final info = MediaNamer.parse('/x/Breaking.Bad.1x02.720p.mkv');
      expect(info.season, 1);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'Breaking Bad');
    });

    test('第2集 中文写法', () {
      final info = MediaNamer.parse('/x/庆余年.第02集.1080p.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 2);
      expect(info.seriesTitle, '庆余年');
    });

    test('第1季第3集', () {
      final info = MediaNamer.parse('/x/权力的游戏 第1季第3集.mp4');
      expect(info.season, 1);
      expect(info.episode, 3);
      expect(info.seriesTitle, '权力的游戏');
    });

    test('EP05 写法', () {
      final info = MediaNamer.parse('/x/Drama.EP05.HDTV.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 5);
      expect(info.seriesTitle, 'Drama');
    });

    test('同剧集不同集数应归到同一个列表名', () {
      final a = MediaNamer.parse('/x/Show.S01E01.1080p.mp4').seriesTitle;
      final b = MediaNamer.parse('/x/Show.S01E07.2160p.WEB-DL.mp4').seriesTitle;
      final c = MediaNamer.parse('/x/show.S02E03.BluRay.mkv').seriesTitle;
      expect(b, a);
      expect(c.toLowerCase(), a.toLowerCase());
    });

    test('季集排序：E02 在 E10 之前', () {
      final e2 = MediaNamer.parse('/x/S01E02.mp4');
      final e10 = MediaNamer.parse('/x/S01E10.mp4');
      expect(e2.orderKey, lessThan(e10.orderKey));
    });
  });

  group('电影识别', () {
    test('带发布标签的电影应清洗出片名', () {
      final info = MediaNamer.parse(
          '/x/Interstellar.2014.1080p.BluRay.x264.DTS-FGT.mp4');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, 'Interstellar');
      expect(info.year, 2014);
    });

    test('中文片名带画质标签', () {
      final info =
          MediaNamer.parse('/x/流浪地球2.2023.2160p.HDR.国语中字.mp4');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, '流浪地球2');
    });

    test('方括号发布组应被去掉', () {
      final info =
          MediaNamer.parse('/x/[字幕组] 让子弹飞 [1080p] [中字].mkv');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, '让子弹飞');
    });

    test('普通文件名不会被误判成剧集', () {
      final info = MediaNamer.parse('/x/test_video.mp4');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, 'test video');
    });
  });
}
