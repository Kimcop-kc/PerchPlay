// 鏂囦欢鍚嶈瘑鍒祴璇曪細鑷姩鍒嗙粍锛堝墽闆嗗垪琛?/ 鐢靛奖鍒楄〃锛夊叏闈犲畠锛?// 鍒嗙被閿欎簡浼氱洿鎺ユ妸鐗囧瓙褰掗敊鍒楄〃锛岃繖閲屾妸甯歌鍐欐硶閮介拤浣忋€?import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/media_grouping_service.dart';
import 'package:perchplay/services/media_namer_service.dart';

void main() {
  group('鍓ч泦璇嗗埆', () {
    test('S01E02 鏍囧噯鍐欐硶', () {
      final info = MediaNamer.parse('/x/Show.S01E02.1080p.WEB-DL.x265.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.season, 1);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'Show');
    });

    test('灏忓啓 s01e02', () {
      final info = MediaNamer.parse('/x/my.show.s01e02.mkv');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'my show');
    });

    test('1x02 鍐欐硶', () {
      final info = MediaNamer.parse('/x/Breaking.Bad.1x02.720p.mkv');
      expect(info.season, 1);
      expect(info.episode, 2);
      expect(info.seriesTitle, 'Breaking Bad');
    });

    test('绗?闆?涓枃鍐欐硶', () {
      final info = MediaNamer.parse('/x/搴嗕綑骞?绗?2闆?1080p.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 2);
      expect(info.seriesTitle, '搴嗕綑骞?);
    });

    test('绗?瀛ｇ3闆?, () {
      final info = MediaNamer.parse('/x/鏉冨姏鐨勬父鎴?绗?瀛ｇ3闆?mp4');
      expect(info.season, 1);
      expect(info.episode, 3);
      expect(info.seriesTitle, '鏉冨姏鐨勬父鎴?);
    });

    test('EP05 鍐欐硶', () {
      final info = MediaNamer.parse('/x/Drama.EP05.HDTV.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 5);
      expect(info.seriesTitle, 'Drama');
    });

    test('鍚屽墽闆嗕笉鍚岄泦鏁板簲褰掑埌鍚屼竴涓垪琛ㄥ悕', () {
      final a = MediaNamer.parse('/x/Show.S01E01.1080p.mp4').seriesTitle;
      final b = MediaNamer.parse('/x/Show.S01E07.2160p.WEB-DL.mp4').seriesTitle;
      final c = MediaNamer.parse('/x/show.S02E03.BluRay.mkv').seriesTitle;
      expect(b, a);
      expect(c.toLowerCase(), a.toLowerCase());
    });

    test('瀛ｉ泦鎺掑簭锛欵02 鍦?E10 涔嬪墠', () {
      final e2 = MediaNamer.parse('/x/S01E02.mp4');
      final e10 = MediaNamer.parse('/x/S01E10.mp4');
      expect(e2.orderKey, lessThan(e10.orderKey));
    });
  });

  group('鐢靛奖璇嗗埆', () {
    test('甯﹀彂甯冩爣绛剧殑鐢靛奖搴旀竻娲楀嚭鐗囧悕', () {
      final info = MediaNamer.parse(
          '/x/Interstellar.2014.1080p.BluRay.x264.DTS-FGT.mp4');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, 'Interstellar');
      expect(info.year, 2014);
    });

    test('涓枃鐗囧悕甯︽暟瀛楋細鍙畻"寮辩寽娴?锛屽崟鐙竴涓枃浠朵笉鎴愬墽闆?, () {
      final info =
          MediaNamer.parse('/x/娴佹氮鍦扮悆2.2023.2160p.HDR.鍥借涓瓧.mp4');
      // `娴佹氮鍦扮悆2` 鐗囧悕鑷甫鏁板瓧锛屼細琚急璇嗗埆鎴?绗?2 闆?锛堣繖鏄彲鎺ュ彈鐨勮繃娓℃€侊級锛?      // 鍏抽敭鍦ㄤ簬锛氬急璇嗗埆蹇呴』闈犲悓绫昏仛闆嗕綈璇佹墠鎴愬垪琛紝鍗曠嫭涓€涓枃浠朵笉鎴愬墽闆嗐€?      expect(info.weakEpisode, isTrue);
      expect(
        MediaGrouping.group(['/x/娴佹氮鍦扮悆2.2023.2160p.HDR.鍥借涓瓧.mp4']),
        isEmpty,
      );
      // 浣嗗鏋滅湡鐨勫瓨鍦?娴佹氮鍦扮悆1 / 娴佹氮鍦扮悆2锛屽氨浼氳褰掓垚涓€涓墽闆嗗垪琛?      expect(
        MediaGrouping.group([
          '/x/娴佹氮鍦扮悆1.2023.1080p.mp4',
          '/x/娴佹氮鍦扮悆2.2023.1080p.mp4',
        ]).length,
        1,
      );
    });

    test('鏂规嫭鍙峰彂甯冪粍搴旇鍘绘帀', () {
      final info =
          MediaNamer.parse('/x/[瀛楀箷缁刔 璁╁瓙寮归 [1080p] [涓瓧].mkv');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, '璁╁瓙寮归');
    });

    test('鏅€氭枃浠跺悕涓嶄細琚鍒ゆ垚鍓ч泦', () {
      final info = MediaNamer.parse('/x/test_video.mp4');
      expect(info.isEpisode, isFalse);
      expect(info.seriesTitle, 'test video');
    });
  });

  group('缂栧彿寮€澶存枃浠?, () {
    test('01 璁插骇 / 02 璁插骇 搴旀彁鍙栫浉鍚屽墽鍚?, () {
      final a = MediaNamer.parse('/x/01 璁插骇.mp4');
      final b = MediaNamer.parse('/x/02 璁插骇.mp4');
      expect(a.isEpisode, isTrue);
      expect(b.isEpisode, isTrue);
      expect(a.seriesTitle, '璁插骇');
      expect(b.seriesTitle, '璁插骇');
      // 涓や釜鏂囦欢鐨勭郴鍒楀悕鐩稿悓锛屽簲璇ヨ兘褰掔粍
      expect(MediaGrouping.normalize(a.seriesTitle),
          MediaGrouping.normalize(b.seriesTitle));
    });

    test('EP05 鍦ㄥ紑澶翠粛鑳借瘑鍒墽鍚?, () {
      final info = MediaNamer.parse('/x/EP05 - Great Show [1080p].mkv');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 5);
      expect(info.seriesTitle, contains('Great Show'));
    });

    test('[03] 鍦ㄥ紑澶翠粛鑳借瘑鍒墽鍚?, () {
      final info = MediaNamer.parse('/x/[03] 鏌愬姩鐢?mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 3);
      expect(info.seriesTitle, '鏌愬姩鐢?);
    });

    test('绗?2闆?鍦ㄥ紑澶翠粛鑳借瘑鍒墽鍚?, () {
      final info = MediaNamer.parse('/x/绗?2闆?璁插骇涓婚.mp4');
      expect(info.isEpisode, isTrue);
      expect(info.episode, 2);
      expect(info.seriesTitle, '璁插骇涓婚');
    });

    test('S01E03 鍦ㄥ紑澶翠粛鑳借瘑鍒墽鍚?, () {
      final info = MediaNamer.parse('/x/S01E03 Show Name [1080p].mkv');
      expect(info.season, 1);
      expect(info.episode, 3);
      expect(info.seriesTitle, 'Show Name');
    });

    test('1x05 鍦ㄥ紑澶翠粛鑳借瘑鍒墽鍚?, () {
      final info = MediaNamer.parse('/x/1x05 Series Name.mkv');
      expect(info.season, 1);
      expect(info.episode, 5);
      expect(info.seriesTitle, 'Series Name');
    });
  });
}
