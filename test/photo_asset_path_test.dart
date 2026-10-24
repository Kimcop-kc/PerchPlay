import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/library_prune_service.dart';
import 'package:perchplay/services/local_media_import_service.dart';
import 'package:perchplay/services/video_source_service.dart';

/// 照片库「虚拟路径」方案的回归测试。
///
/// 背景：早期实现把整个相册的视频都 copy 进 Documents/Imported/PhotoLibrary，
/// 等于把用户视频库翻倍、存储直接爆炸。现在影库里只存 `phasset://<id>`，
/// 播放时才按需导出到临时缓存。
///
/// 这些用例覆盖各模块对虚拟路径的识别，避免以后某个环节又把它当成本地文件。
void main() {
  group('phasset 虚拟路径编解码', () {
    test('构造与识别', () {
      final p = LocalMediaImportService.photoAssetPath('ABC-123');
      expect(p, 'phasset://ABC-123');
      expect(LocalMediaImportService.isPhotoAssetPath(p), isTrue);
      expect(LocalMediaImportService.assetIdFromPath(p), 'ABC-123');
    });

    test('普通路径不会被误判', () {
      expect(
        LocalMediaImportService.isPhotoAssetPath('/var/mobile/a.mp4'),
        isFalse,
      );
      expect(LocalMediaImportService.assetIdFromPath('/var/mobile/a.mp4'),
          isNull);
    });

    test('空 ID 返回 null', () {
      expect(LocalMediaImportService.assetIdFromPath('phasset://'), isNull);
    });
  });

  group('虚拟路径不能被当成真实文件', () {
    test('isRemotePath 认为 phasset 是远程/托管来源', () {
      // 关键：pruneMissingFiles 靠这个判断跳过「文件不存在」检查，
      // 否则一扫描就会把整个相册记录全删掉。
      expect(
        LibraryPruneService.isRemotePath('phasset://ABC-123'),
        isTrue,
      );
    });

    test('普通本地路径仍然按本地处理', () {
      expect(
        LibraryPruneService.isRemotePath('/var/mobile/Documents/a.mp4'),
        isFalse,
      );
    });
  });

  group('来源分类', () {
    test('相册视频归为「相机/个人视频」，不会掉进「其他」', () {
      expect(
        VideoSourceService.classify('phasset://ABC-123'),
        VideoSource.camera,
      );
    });
  });
}
