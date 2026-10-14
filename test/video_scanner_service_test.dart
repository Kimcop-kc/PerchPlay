import 'package:flutter_test/flutter_test.dart';
import 'package:vidflow/services/video_scanner_service.dart';

void main() {
  group('VideoScannerService._dedupeDirs', () {
    final scanner = VideoScannerService();

    test('去掉被包含的子目录，保留最外层', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0',
      ]);
      expect(result, ['/storage/emulated/0']);
    });

    test('无父子关系的目录全部保留', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Download',
      ]);
      expect(result, [
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Download',
      ]);
    });

    test('重复目录去重', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Movies',
      ]);
      expect(result, ['/storage/emulated/0/Movies']);
    });
  });
}
