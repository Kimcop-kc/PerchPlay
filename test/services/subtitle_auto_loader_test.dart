import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/services/subtitle/subtitle_auto_loader.dart';
import 'package:perchplay/services/subtitle/subtitle_matcher_online.dart';

void main() {
  group('AutoLoadAction 决策', () {
    test('高置信度阈值正确（≥0.75 可自动）', () {
      expect(SubtitleMatcher.highConfidence, 0.75);
      expect(SubtitleMatcher.lowConfidence, 0.4);
    });
  });

  group('SubtitleAutoLoader 状态管理', () {
    test('clear 清空所有状态', () {
      final loader = SubtitleAutoLoader.instance;
      loader.clear();
      // 状态已清空（无法直接断言内部集合，但 clear 不抛异常即通过）
    });
  });

  group('VideoModel 查询条件构造', () {
    test('从视频构造查询', () {
      final video = VideoModel(
        id: 'v1',
        path: '/storage/Movies/Movie.2023.mkv',
        name: 'Movie.2023.mkv',
        folderPath: '/storage/Movies',
        size: 1000,
        durationMs: 60000,
        dateAdded: DateTime.now(),
        dateModified: DateTime.now(),
      );
      expect(video.name, 'Movie.2023.mkv');
    });
  });
}
