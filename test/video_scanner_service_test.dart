import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/video_scanner_service.dart';

void main() {
  group('VideoScannerService._dedupeDirs', () {
    final scanner = VideoScannerService();

    test('鍘绘帀琚寘鍚殑瀛愮洰褰曪紝淇濈暀鏈€澶栧眰', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0',
      ]);
      expect(result, ['/storage/emulated/0']);
    });

    test('鏃犵埗瀛愬叧绯荤殑鐩綍鍏ㄩ儴淇濈暀', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Download',
      ]);
      expect(result, [
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Download',
      ]);
    });

    test('閲嶅鐩綍鍘婚噸', () {
      final result = scanner.dedupeDirsForTest([
        '/storage/emulated/0/Movies',
        '/storage/emulated/0/Movies',
      ]);
      expect(result, ['/storage/emulated/0/Movies']);
    });
  });
}
