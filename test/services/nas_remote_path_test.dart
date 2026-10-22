// WebDAV / FTP 远程路径规范化测试。
//
// 用户填的路径格式五花八门：`dav`、`/dav`、`/dav/`、`dav/files/user`…
// 直接拼 `$baseUrl$path` 会得到 `http://host:5005dav` 这种错误 URL，
// 所以必须先规范化。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/nas_client_service.dart';

void main() {
  group('normalizeRemotePath', () {
    test('空路径 → 根目录', () {
      expect(NasClientService.normalizeRemotePath(''), '/');
      expect(NasClientService.normalizeRemotePath('   '), '/');
    });

    test('无前导斜杠时补齐', () {
      expect(NasClientService.normalizeRemotePath('dav'), '/dav');
      expect(NasClientService.normalizeRemotePath('dav/files/user'),
          '/dav/files/user');
    });

    test('去掉末尾多余斜杠', () {
      expect(NasClientService.normalizeRemotePath('/dav/'), '/dav');
      expect(NasClientService.normalizeRemotePath('/dav///'), '/dav');
    });

    test('根目录保留单个斜杠', () {
      expect(NasClientService.normalizeRemotePath('/'), '/');
      expect(NasClientService.normalizeRemotePath('///'), '/');
    });

    test('正常路径原样保留', () {
      expect(NasClientService.normalizeRemotePath('/dav'), '/dav');
      expect(NasClientService.normalizeRemotePath('/remote.php/dav/files/u'),
          '/remote.php/dav/files/u');
    });

    test('首尾空格被清理', () {
      expect(NasClientService.normalizeRemotePath('  /dav  '), '/dav');
    });

    test('群晖 / Nextcloud / 坚果云 典型路径', () {
      expect(NasClientService.normalizeRemotePath('dav'), '/dav');
      expect(
        NasClientService.normalizeRemotePath('remote.php/dav/files/username'),
        '/remote.php/dav/files/username',
      );
      expect(NasClientService.normalizeRemotePath('/dav'), '/dav');
    });
  });
}
