import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/video_source_service.dart';

void main() {
  group('classify', () {
    test('DCIM/Camera 鈫?camera', () {
      expect(VideoSourceService.classify('/sdcard/DCIM/Camera/VID_20250101.mp4'),
          VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/DCIM/100ANDRO/IMG_1234.MOV'),
          VideoSource.camera);
    });

    test('鍘傚晢鐩告満鐩綍', () {
      expect(VideoSourceService.classify('/sdcard/DCIM/CameraX/IMG_001.mp4'),
          VideoSource.camera);
      expect(
          VideoSourceService.classify('/sdcard/鐩告満/VID_001.mp4'), VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/Screenshots/IMG.png'),
          VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/鎴睆/scr.mp4'),
          VideoSource.camera);
    });

    test('CapCut / 鍓槧 鈫?capcut', () {
      expect(VideoSourceService.classify('/sdcard/Movies/CapCut/lv-001.mp4'),
          VideoSource.capcut);
      expect(
          VideoSourceService.classify(
              '/sdcard/Android/data/com.lemon.lv/files/video.mp4'),
          VideoSource.capcut);
      expect(VideoSourceService.classify('/sdcard/鍓槧/output.mp4'),
          VideoSource.capcut);
      expect(VideoSourceService.classify('/sdcard/蹇呭壀/export.mp4'),
          VideoSource.capcut);
    });

    test('TikTok / 鎶栭煶 鈫?shortVideo', () {
      expect(VideoSourceService.classify('/sdcard/Movies/TikTok/v.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/Download/douyin/abc.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/蹇墜/video.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/Bilibili/av123.mp4'),
          VideoSource.shortVideo);
    });

    test('Screen recorder 鈫?screenRecord', () {
      expect(VideoSourceService.classify('/sdcard/Movies/Screen Records/rec.mp4'),
          VideoSource.screenRecord);
      expect(VideoSourceService.classify('/sdcard/褰曞睆/2025-01.mp4'),
          VideoSource.screenRecord);
    });

    test('寰俊/QQ 鈫?social', () {
      expect(VideoSourceService.classify('/sdcard/tencent/MicroMsg/video.mp4'),
          VideoSource.social);
      expect(VideoSourceService.classify('/sdcard/QQ/video/abc.mp4'),
          VideoSource.social);
      expect(
          VideoSourceService.classify('/sdcard/Telegram Video/abc.mp4'),
          VideoSource.social);
    });

    test('Download 鈫?download', () {
      expect(VideoSourceService.classify('/sdcard/Download/Show.S01E01.mkv'),
          VideoSource.download);
      expect(VideoSourceService.classify('/sdcard/杩呴浄涓嬭浇/movie.mp4'),
          VideoSource.download);
    });

    test('鑷畾涔夌洰褰?鈫?other', () {
      expect(
          VideoSourceService.classify('/sdcard/MyVideos/杩涘嚮銇法浜?S01E01.mp4'),
          VideoSource.other);
    });

    test('鏃犱粬鐩告満涓嶈鐩告満璇鍒?, () {
      expect(VideoSourceService.classify('/sdcard/鏃犱粬鐩告満/output.mp4'),
          VideoSource.capcut);
    });

    test('screenshot 甯﹁矾寰勮竟鐣?, () {
      expect(VideoSourceService.classify('/sdcard/app-screenshots-helper/scr.png'),
          isNot(VideoSource.camera));
    });

    test('rec. 甯﹁矾寰勮竟鐣?, () {
      expect(VideoSourceService.classify('/sdcard/records/meeting.mp4'),
          isNot(VideoSource.screenRecord));
    });
  });

  group('groupAll', () {
    test('涓汉瑙嗛鎸夋潵婧?鍓嶇紑鍒嗙粍', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/DCIM/Camera/VID_20250101_120000.mp4',
        '/sdcard/DCIM/Camera/VID_20250101_120001.mp4',
        '/sdcard/DCIM/Camera/VID_20250102_090000.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, contains('馃摲'));
      expect(groups.first.name, contains('VID'));
      expect(groups.first.isSeries, isFalse);
      expect(groups.first.indices.length, 3);
    });

    test('鍓緫瑙嗛鎸夊墠缂€鍒嗗紑', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Movies/CapCut/lv-001.mp4',
        '/sdcard/Movies/CapCut/lv-002.mp4',
        '/sdcard/Movies/CapCut/mx-001.mp4',
      ]);
      // lv- 鍜?mx- 涓や釜鍓嶇紑
      final lv = groups.firstWhere((g) => g.name.contains('lv'));
      final mx = groups.firstWhere((g) => g.name.contains('mx'));
      expect(lv.indices.length, 2);
      expect(mx.indices.length, 1);
    });

    test('涓嶅悓鏉ユ簮鍒嗗紑', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/DCIM/Camera/VID_001.mp4',
        '/sdcard/Movies/CapCut/lv-001.mp4',
        '/sdcard/褰曞睆/rec-001.mp4',
      ]);
      expect(groups.length, 3);
    });

    test('褰辫褰掑埌 series 鍒嗙粍', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/Show.S01E01.1080p.mkv',
        '/sdcard/MyVideos/Show.S01E02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.isSeries, isTrue);
    });

    test('褰辫鏈瘑鍒埌鐨勮蛋鍓嶇紑鍏滃簳', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/tutorial-python.mp4',
        '/sdcard/MyVideos/tutorial-dart.mp4',
      ]);
      // tutorial 鍓嶇紑 鈮? 涓紝鍏滃簳鎴愮粍锛屽甫 馃搨 鍓嶇紑涓?isFallback=true
      final fb = groups.where((g) => g.isFallback).toList();
      expect(fb.length, 1);
      expect(fb.first.name, '馃搨 tutorial');
    });

    test('澶у皬鍐欎笉鍚屽墠缂€鍚堝苟', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Movies/CapCut/LV-001.mp4',
        '/sdcard/Movies/CapCut/lv-002.mp4',
      ]);
      final personal = groups.where((g) => !g.isSeries && !g.isFallback).toList();
      expect(personal.length, 1);
      expect(personal.first.indices.length, 2);
    });

    test('鍓嶇紑鍏滃簳 <2 涓笉鎴愮粍', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/random-video.mp4',
      ]);
      // 瀛ょ珛鐨?random 鍓嶇紑锛屼笉鎴愮粍
      expect(groups.where((g) => g.name == 'random'), isEmpty);
    });

    test('鏃犵紪鍙风殑涓嬭浇鐩綍瑙嗛涔熻兘鎸夊墠缂€鍏滃簳', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Download/lv-鎴戠殑vlog.mp4',
        '/sdcard/Download/lv-鏃呰璁板綍.mp4',
        '/sdcard/Download/lv-缇庨.mp4',
      ]);
      // download 鐩綍璧?MediaGrouping 鎵句笉鍒板墽闆嗭紝鍓嶇紑鍏滃簳 lv 鈮?
      expect(groups.any((g) => g.name == '馃搨 lv'), isTrue);
    });

    test('绀句氦 App 瑙嗛褰掑埌涓汉鍒嗙粍', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/tencent/MicroMsg/video1.mp4',
        '/sdcard/tencent/MicroMsg/video2.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, contains('馃挰'));
      expect(groups.first.isSeries, isFalse);
    });

    test('灏鹃儴鏁板瓧鍓旈櫎鍚庝笉鍚岀紪鍙峰綊涓€缁?, () {
      // 4浣嶆暟瀛楄 MediaNamer 褰撲綔骞翠唤璺宠繃 鈫?璧板厹搴?鈫?_groupKey 鍘诲熬鏁?      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/myclip-2023-edit.mp4',
        '/sdcard/MyVideos/myclip-2024-edit.mp4',
      ]);
      expect(groups.any((g) => g.name == '馃搨 myclip'), isTrue);
    });

    test('涓枃鍓嶇紑鏃犵紪鍙蜂篃鑳藉厹搴曞綊缁?, () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/杩涘嚮鐨勫法浜?鑺辩诞.mp4',
        '/sdcard/MyVideos/杩涘嚮鐨勫法浜?鐗瑰吀.mp4',
      ]);
      // _groupKey: "杩涘嚮鐨勫法浜?鑺辩诞" 鈫?"杩涘嚮鐨勫法浜?; same for both
      expect(groups.any((g) => g.name == '馃搨 杩涘嚮鐨勫法浜?), isTrue);
    });
  });

  group('sourceLabel', () {
    test('camera 鈫?馃摲 鐩告満', () {
      expect(VideoSourceService.sourceLabel(VideoSource.camera), '馃摲 鐩告満');
    });
    test('screenRecord 鈫?馃枼锔?褰曞睆', () {
      expect(VideoSourceService.sourceLabel(VideoSource.screenRecord), '馃枼锔?褰曞睆');
    });
    test('social 鈫?馃挰 绀句氦', () {
      expect(VideoSourceService.sourceLabel(VideoSource.social), '馃挰 绀句氦');
    });
    test('download/other 鈫?绌?, () {
      expect(VideoSourceService.sourceLabel(VideoSource.download), '');
      expect(VideoSourceService.sourceLabel(VideoSource.other), '');
    });
  });
}