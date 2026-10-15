// 删除自动列表的回归测试
//
// 自动列表是每次扫描后重建的：如果只删数据库记录，下次扫描就长回来，
// 用户看到的就是"删不掉"。这里钉住「记住删除意图 / 可恢复」的行为。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vidflow/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('删掉的自动列表会被记住（并写进 SharedPreferences）', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettingsService.instance;
    await settings.ensureLoaded();

    expect(settings.isAutoPlaylistHidden('auto:series:Show'), isFalse);

    await settings.hideAutoPlaylist('auto:series:Show');
    await settings.hideAutoPlaylist('auto:movies');

    expect(settings.isAutoPlaylistHidden('auto:series:Show'), isTrue);
    expect(settings.isAutoPlaylistHidden('auto:movies'), isTrue);
    expect(settings.isAutoPlaylistHidden('auto:series:Other'), isFalse);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('settings.hiddenAutoPlaylists');
    expect(saved, contains('auto:series:Show'));
    expect(saved, contains('auto:movies'));
  });

  test('恢复自动列表会清空记录', () async {
    SharedPreferences.setMockInitialValues({
      'settings.hiddenAutoPlaylists': ['auto:movies', 'auto:series:Show'],
    });
    final settings = AppSettingsService.instance;
    await settings.ensureLoaded();

    expect(settings.hiddenAutoPlaylists.length, 2);

    await settings.restoreAutoPlaylists();

    expect(settings.hiddenAutoPlaylists, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('settings.hiddenAutoPlaylists'), isNull);
  });
}
