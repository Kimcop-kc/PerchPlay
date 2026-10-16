// 鑷姩鍒嗙粍娴嬭瘯锛堟寜**鏂囦欢鍚?*鍒嗗埌鍓ч泦鍒楄〃锛?//
// 闇€姹傝鐐癸細
//  - 鍒嗙粍鍙湅鏂囦欢鍚嶏紝涓嶇湅鏂囦欢澶瑰悕锛堜笉鍐嶇敤鏂囦欢澶瑰悕鍏滃簳鍛藉悕锛?//  - 涓嶅啀鏈夈€岀數褰便€嶅垪琛細娌℃湁闆嗘暟淇℃伅鐨勮棰戜笉杩涗换浣曡嚜鍔ㄥ垪琛?//  - 鏄庣‘瀛ｉ泦鏍囪 鈫?涓€闆嗕篃鎴愬垪琛紱鍙湁鏈熬搴忓彿 鈫?闇€瑕佸悓绫昏仛闆嗘墠璁?import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/media_grouping_service.dart';

void main() {
  group('鏄庣‘瀛ｉ泦鏍囪', () {
    test('S01E01/02/03 褰掓垚涓€涓垪琛ㄥ苟鎸夊闆嗘帓搴?, () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E03.1080p.mkv',
        '/m/Show.S01E01.1080p.mkv',
        '/m/Show.S01E02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [1, 2, 0]);
    });

    test('涓枃 绗琋闆?, () {
      final groups = MediaGrouping.group([
        '/m/搴嗕綑骞?绗?2闆?mp4',
        '/m/搴嗕綑骞?绗?1闆?mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '搴嗕綑骞?);
      expect(groups.first.indices, [1, 0]);
    });

    test('鏄庣‘鏍囪鏃朵竴闆嗕篃鎴愬垪琛?, () {
      final groups = MediaGrouping.group(['/m/Show.S01E05.1080p.mkv']);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [0]);
    });

    test('Show.S01.01 / Show.S01.02锛堝鍗曠嫭鎴愭锛?, () {
      final groups = MediaGrouping.group([
        '/m/Show.S01.02.1080p.mkv',
        '/m/Show.S01.01.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show'); // S01 涓嶆畫鐣欏湪鍚嶅瓧閲?      expect(groups.first.indices, [1, 0]);
    });

    test('璺ㄦ枃浠跺す鐨勫悓鍚嶅墽闆嗗悎鎴愪竴涓垪琛紙鍙湅鏂囦欢鍚嶏級', () {
      final groups = MediaGrouping.group([
        '/m/Season1/Show.S01E01.mkv',
        '/m/Season2/Show.S02E01.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices.length, 2);
    });

    test('澶у皬鍐欎笉鍚屼篃绠楀悓涓€涓墽闆?, () {
      final groups = MediaGrouping.group([
        '/m/show.S01E01.mkv',
        '/m/SHOW.S01E02.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.indices.length, 2);
    });
  });

  group('鏈熬搴忓彿锛堝急鏍囪锛?, () {
    test('Show - 01 / Show - 02 鏈夎仛闆?鈫?鎴愬垪琛?, () {
      final groups = MediaGrouping.group([
        '/m/Show - 02 [1080p].mkv',
        '/m/Show - 01 [1080p].mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.indices, [1, 0]);
    });

    test('Show.02.1080p / Show.03.1080p 鏈夎仛闆?鈫?鎴愬垪琛?, () {
      final groups = MediaGrouping.group([
        '/m/Show.02.1080p.mkv',
        '/m/Show.03.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('瀛ょ珛鐨?Rocky 2.mkv 涓嶆垚鍒楄〃锛堥伩鍏嶆妸鐢靛奖褰撳墽闆嗭級', () {
      final groups = MediaGrouping.group(['/m/Rocky 2.mkv']);
      expect(groups, isEmpty);
    });
  });

  group('涓嶅簲杩涘叆浠讳綍鍒楄〃', () {
    test('鍙湁缂栧彿銆佹病鏈夊墽鍚嶇殑鏂囦欢锛堜笉鐪嬫枃浠跺す鍚嶏級', () {
      final groups = MediaGrouping.group([
        '/m/MyShow/01.mp4',
        '/m/MyShow/02.mp4',
        '/m/MyShow/03.mp4',
      ]);
      expect(groups, isEmpty, reason: '鏂囦欢鍚嶉噷娌℃湁鍓у悕锛屾寜闇€姹備笉鍒嗙粍');
    });

    test('鐢靛奖锛堝甫骞翠唤/鐢昏川鏍囩锛?, () {
      final groups = MediaGrouping.group([
        '/m/Interstellar.2014.1080p.BluRay.x264.mp4',
        '/m/Liuliang.Earth.2.2023.2160p.HDR.mp4',
        '/m/1917.2019.1080p.mkv',
        '/m/Se7en.mkv',
      ]);
      expect(groups, isEmpty);
    });

    test('鍓ч泦涓庣數褰辨贩鍦ㄤ竴璧锋椂鍙嚭鍓ч泦鍒楄〃', () {
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

    test('鍗曚釜鏅€氳棰?, () {
      expect(MediaGrouping.group(['/m/test_video.mp4']), isEmpty);
    });
  });

  group('鍓嶇紑璇嗗埆锛堜笉渚濊禆鏌愮鍛藉悕涔犳儻锛?, () {
    test('宸ㄤ汉01 / 宸ㄤ汉02锛堢紪鍙风揣璐达紝鏃犲垎闅旂锛?, () {
      final groups = MediaGrouping.group([
        '/m/杩涘嚮鐨勫法浜?1.mp4',
        '/m/杩涘嚮鐨勫法浜?2.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '杩涘嚮鐨勫法浜?);
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

    test('涓枃鏁板瓧锛氱涓€闆?/ 绗簩闆?/ 绗笁闆?, () {
      final groups = MediaGrouping.group([
        '/m/搴嗕綑骞?绗笁闆?mp4',
        '/m/搴嗕綑骞?绗竴闆?mp4',
        '/m/搴嗕綑骞?绗簩闆?mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '搴嗕綑骞?);
      expect(groups.first.indices, [1, 2, 0]);
    });

    test('鍓嶇紑閲岀殑瀛ｆ爣璁颁笉浼氭薄鏌撳垪琛ㄥ悕', () {
      final groups = MediaGrouping.group([
        '/m/Show.S01E01.mkv',
        '/m/Show.S02E01.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('鍙戝竷缁勫墠缂€琚竻鎺夛細[Group] Show - 01 / 02', () {
      final groups = MediaGrouping.group([
        '/m/[Group] Show - 01 [1080p].mkv',
        '/m/[Group] Show - 02 [1080p].mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
    });

    test('鐗囧悕甯﹀勾浠界殑鐢靛奖涓嶄細鍥犲墠缂€鐩稿悓鑰岃褰撳墽闆?, () {
      final groups = MediaGrouping.group([
        '/m/Liuliang.Earth.2.2023.2160p.HDR.mp4',
      ]);
      expect(groups, isEmpty);
    });

    test('缂栧彿寮€澶存枃浠?01 璁插骇 / 02 璁插骇 鑳藉綊鍒板悓涓€缁?, () {
      final groups = MediaGrouping.group([
        '/m/01 璁插骇.mp4',
        '/m/02 璁插骇.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.indices.length, 2);
    });

    test('EP05 - Show 鍜?EP06 - Show 鑳藉綊鍒板悓涓€缁?, () {
      final groups = MediaGrouping.group([
        '/m/EP05 - Great Show.mkv',
        '/m/EP06 - Great Show.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Great Show');
    });
  });
}
