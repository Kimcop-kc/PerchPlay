// 鍒犻櫎鑷姩鍒楄〃鐨勫洖褰掓祴璇?//
// 鑷姩鍒楄〃鏄瘡娆℃壂鎻忓悗閲嶅缓鐨勶細濡傛灉鍙垹鏁版嵁搴撹褰曪紝涓嬫鎵弿灏遍暱鍥炴潵锛?// 鐢ㄦ埛鐪嬪埌鐨勫氨鏄?鍒犱笉鎺?銆傝繖閲岄拤浣忋€岃浣忓垹闄ゆ剰鍥?/ 鍙仮澶嶃€嶇殑琛屼负銆?import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('鍒犳帀鐨勮嚜鍔ㄥ垪琛ㄤ細琚浣忥紙骞跺啓杩?SharedPreferences锛?, () async {
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

  test('鎭㈠鑷姩鍒楄〃浼氭竻绌鸿褰?, () async {
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
