import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/services/video_source_service.dart';

void main() {
  group('classify', () {
    test('DCIM/Camera → camera', () {
      expect(VideoSourceService.classify('/sdcard/DCIM/Camera/VID_20250101.mp4'),
          VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/DCIM/100ANDRO/IMG_1234.MOV'),
          VideoSource.camera);
    });

    test('厂商相机目录', () {
      expect(VideoSourceService.classify('/sdcard/DCIM/CameraX/IMG_001.mp4'),
          VideoSource.camera);
      expect(
          VideoSourceService.classify('/sdcard/相机/VID_001.mp4'), VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/Screenshots/IMG.png'),
          VideoSource.camera);
      expect(VideoSourceService.classify('/sdcard/截屏/scr.mp4'),
          VideoSource.camera);
    });

    test('CapCut / 剪映 → capcut', () {
      expect(VideoSourceService.classify('/sdcard/Movies/CapCut/lv-001.mp4'),
          VideoSource.capcut);
      expect(
          VideoSourceService.classify(
              '/sdcard/Android/data/com.lemon.lv/files/video.mp4'),
          VideoSource.capcut);
      expect(VideoSourceService.classify('/sdcard/剪映/output.mp4'),
          VideoSource.capcut);
      expect(VideoSourceService.classify('/sdcard/必剪/export.mp4'),
          VideoSource.capcut);
    });

    test('TikTok / 抖音 → shortVideo', () {
      expect(VideoSourceService.classify('/sdcard/Movies/TikTok/v.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/Download/douyin/abc.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/快手/video.mp4'),
          VideoSource.shortVideo);
      expect(VideoSourceService.classify('/sdcard/Bilibili/av123.mp4'),
          VideoSource.shortVideo);
    });

    test('Screen recorder → screenRecord', () {
      expect(VideoSourceService.classify('/sdcard/Movies/Screen Records/rec.mp4'),
          VideoSource.screenRecord);
      expect(VideoSourceService.classify('/sdcard/录屏/2025-01.mp4'),
          VideoSource.screenRecord);
    });

    test('微信/QQ → social', () {
      expect(VideoSourceService.classify('/sdcard/tencent/MicroMsg/video.mp4'),
          VideoSource.social);
      expect(VideoSourceService.classify('/sdcard/QQ/video/abc.mp4'),
          VideoSource.social);
      expect(
          VideoSourceService.classify('/sdcard/Telegram Video/abc.mp4'),
          VideoSource.social);
    });

    test('Download → download', () {
      expect(VideoSourceService.classify('/sdcard/Download/Show.S01E01.mkv'),
          VideoSource.download);
      expect(VideoSourceService.classify('/sdcard/迅雷下载/movie.mp4'),
          VideoSource.download);
    });

    test('自定义目录 → other', () {
      expect(
          VideoSourceService.classify('/sdcard/MyVideos/进击の巨人.S01E01.mp4'),
          VideoSource.other);
    });

    test('无他相机不被相机误导判', () {
      expect(VideoSourceService.classify('/sdcard/无他相机/output.mp4'),
          VideoSource.capcut);
    });

    test('screenshot 带路径边界', () {
      expect(VideoSourceService.classify('/sdcard/app-screenshots-helper/scr.png'),
          isNot(VideoSource.camera));
    });

    test('rec. 带路径边界', () {
      expect(VideoSourceService.classify('/sdcard/records/meeting.mp4'),
          isNot(VideoSource.screenRecord));
    });
  });

  group('groupAll', () {
    test('个人视频按来源+前缀分组', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/DCIM/Camera/VID_20250101_120000.mp4',
        '/sdcard/DCIM/Camera/VID_20250101_120001.mp4',
        '/sdcard/DCIM/Camera/VID_20250102_090000.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, contains('📷'));
      expect(groups.first.name, contains('VID'));
      expect(groups.first.isSeries, isFalse);
      expect(groups.first.indices.length, 3);
    });

    test('剪辑视频按前缀分开', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Movies/CapCut/lv-001.mp4',
        '/sdcard/Movies/CapCut/lv-002.mp4',
        '/sdcard/Movies/CapCut/mx-001.mp4',
      ]);
      // lv- 和 mx- 两个前缀
      final lv = groups.firstWhere((g) => g.name.contains('lv'));
      final mx = groups.firstWhere((g) => g.name.contains('mx'));
      expect(lv.indices.length, 2);
      expect(mx.indices.length, 1);
    });

    test('不同来源分开', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/DCIM/Camera/VID_001.mp4',
        '/sdcard/Movies/CapCut/lv-001.mp4',
        '/sdcard/录屏/rec-001.mp4',
      ]);
      expect(groups.length, 3);
    });

    test('影视归到 series 分组', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/Show.S01E01.1080p.mkv',
        '/sdcard/MyVideos/Show.S01E02.1080p.mkv',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, 'Show');
      expect(groups.first.isSeries, isTrue);
    });

    test('影视未识别到的走前缀兜底', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/tutorial-python.mp4',
        '/sdcard/MyVideos/tutorial-dart.mp4',
      ]);
      // tutorial 前缀 ≥2 个，兜底成组，带 📂 前缀且 isFallback=true
      final fb = groups.where((g) => g.isFallback).toList();
      expect(fb.length, 1);
      expect(fb.first.name, '📂 tutorial');
    });

    test('大小写不同前缀合并', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Movies/CapCut/LV-001.mp4',
        '/sdcard/Movies/CapCut/lv-002.mp4',
      ]);
      final personal = groups.where((g) => !g.isSeries && !g.isFallback).toList();
      expect(personal.length, 1);
      expect(personal.first.indices.length, 2);
    });

    test('前缀兜底 <2 个不成组', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/random-video.mp4',
      ]);
      // 孤立的 random 前缀，不成组
      expect(groups.where((g) => g.name == 'random'), isEmpty);
    });

    test('无编号的下载目录视频也能按前缀兜底', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/Download/lv-我的vlog.mp4',
        '/sdcard/Download/lv-旅行记录.mp4',
        '/sdcard/Download/lv-美食.mp4',
      ]);
      // download 目录走 MediaGrouping 找不到剧集，前缀兜底 lv ≥2
      expect(groups.any((g) => g.name == '📂 lv'), isTrue);
    });

    test('社交 App 视频归到个人分组', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/tencent/MicroMsg/video1.mp4',
        '/sdcard/tencent/MicroMsg/video2.mp4',
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, contains('💬'));
      expect(groups.first.isSeries, isFalse);
    });

    test('尾部数字剔除后不同编号归一组', () {
      // 4位数字被 MediaNamer 当作年份跳过 → 走兜底 → _groupKey 去尾数
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/myclip-2023-edit.mp4',
        '/sdcard/MyVideos/myclip-2024-edit.mp4',
      ]);
      expect(groups.any((g) => g.name == '📂 myclip'), isTrue);
    });

    test('中文前缀无编号也能兜底归组', () {
      final groups = VideoSourceService.groupAll([
        '/sdcard/MyVideos/进击的巨人-花絮.mp4',
        '/sdcard/MyVideos/进击的巨人-特典.mp4',
      ]);
      // _groupKey: "进击的巨人-花絮" → "进击的巨人"; same for both
      expect(groups.any((g) => g.name == '📂 进击的巨人'), isTrue);
    });
  });

  group('sourceLabel', () {
    test('camera → 📷 相机', () {
      expect(VideoSourceService.sourceLabel(VideoSource.camera), '📷 相机');
    });
    test('screenRecord → 🖥️ 录屏', () {
      expect(VideoSourceService.sourceLabel(VideoSource.screenRecord), '🖥️ 录屏');
    });
    test('social → 💬 社交', () {
      expect(VideoSourceService.sourceLabel(VideoSource.social), '💬 社交');
    });
    test('download/other → 空', () {
      expect(VideoSourceService.sourceLabel(VideoSource.download), '');
      expect(VideoSourceService.sourceLabel(VideoSource.other), '');
    });
  });
}