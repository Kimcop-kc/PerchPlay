// 銆岃嚜鍔ㄥ垪琛ㄩ噷鎵嬪姩澧炲垹瑕佷繚鐣欍€嶇殑鍥炲綊娴嬭瘯
//
// 鑷姩鍒楄〃姣忔鎵弿閮戒細鎸夋枃浠跺悕閲嶅缓銆傚鏋滀笉绠＄敤鎴风殑澧炲垹锛?// 鎵嬪姩鍔犺繘鍘荤殑浼氳娓呮帀銆佹墜鍔ㄥ垹鎺夌殑浼氶暱鍥炴潵 鈥斺€?杩欐鏄?閿佹銆佹敼涓嶅姩"銆?import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('鎵嬪姩鍔犲叆 / 绉诲嚭浼氳璁颁綇锛屼笖涓よ€呬簰鏂?, () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppSettingsService.instance;
    await s.ensureLoaded();

    await s.markAutoAdded('auto:series:show', 'v1');
    await s.markAutoRemoved('auto:series:show', 'v2');

    expect(s.autoAddedFor('auto:series:show'), {'v1'});
    expect(s.autoRemovedFor('auto:series:show'), {'v2'});

    // 鍙︿竴涓垪琛ㄤ笉鍙楀奖鍝?    expect(s.autoAddedFor('auto:series:other'), isEmpty);
    expect(s.autoRemovedFor('auto:series:other'), isEmpty);

    // 鎶?v1 鏀规垚"绉诲嚭"锛氬簲浠?added 閲屾秷澶憋紝杩涘叆 removed
    await s.markAutoRemoved('auto:series:show', 'v1');
    expect(s.autoAddedFor('auto:series:show'), isEmpty);
    expect(s.autoRemovedFor('auto:series:show'), {'v1', 'v2'});

    // 鍐嶆妸 v1 鍔犲洖鏉ワ細搴斾粠 removed 閲屾秷澶憋紝鍥炲埌 added
    await s.markAutoAdded('auto:series:show', 'v1');
    expect(s.autoAddedFor('auto:series:show'), {'v1'});
    expect(s.autoRemovedFor('auto:series:show'), {'v2'});
  });

  test('澧炲垹璁板綍浼氬啓杩?SharedPreferences锛堥噸鍚悗浠嶇敓鏁堬級', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppSettingsService.instance;
    await s.ensureLoaded();

    await s.markAutoAdded('auto:series:show', 'addedA');
    await s.markAutoRemoved('auto:series:show', 'removedB');

    final prefs = await SharedPreferences.getInstance();
    final added = prefs.getStringList('settings.autoPlaylistAdded')!;
    final removed = prefs.getStringList('settings.autoPlaylistRemoved')!;
    expect(added.any((e) => e.endsWith('addedA')), isTrue);
    expect(removed.any((e) => e.endsWith('removedB')), isTrue);
  });
}
