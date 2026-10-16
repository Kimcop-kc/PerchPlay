// 「自动列表里手动增删要保留」的回归测试
//
// 自动列表每次扫描都会按文件名重建。如果不管用户的增删，
// 手动加进去的会被清掉、手动删掉的会长回来 —— 这正是"锁死、改不动"。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vidflow/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('手动加入 / 移出会被记住，且两者互斥', () async {
    SharedPreferences.setMockInitialValues({});
    final s = AppSettingsService.instance;
    await s.ensureLoaded();

    await s.markAutoAdded('auto:series:show', 'v1');
    await s.markAutoRemoved('auto:series:show', 'v2');

    expect(s.autoAddedFor('auto:series:show'), {'v1'});
    expect(s.autoRemovedFor('auto:series:show'), {'v2'});

    // 另一个列表不受影响
    expect(s.autoAddedFor('auto:series:other'), isEmpty);
    expect(s.autoRemovedFor('auto:series:other'), isEmpty);

    // 把 v1 改成"移出"：应从 added 里消失，进入 removed
    await s.markAutoRemoved('auto:series:show', 'v1');
    expect(s.autoAddedFor('auto:series:show'), isEmpty);
    expect(s.autoRemovedFor('auto:series:show'), {'v1', 'v2'});

    // 再把 v1 加回来：应从 removed 里消失，回到 added
    await s.markAutoAdded('auto:series:show', 'v1');
    expect(s.autoAddedFor('auto:series:show'), {'v1'});
    expect(s.autoRemovedFor('auto:series:show'), {'v2'});
  });

  test('增删记录会写进 SharedPreferences（重启后仍生效）', () async {
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
