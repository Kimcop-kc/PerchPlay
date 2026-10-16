// 回归测试：液态玻璃实时模糊开关为什么"看起来没用 / 默认是关闭的"
//
// 真实原因有两个，都在这里钉死：
// 1. 早期版本 Android 默认关闭，用户一按开关就写入了 settings.glassBlur=false；
//    新版本改用 v2 键 + 默认 true，必须**忽略旧键**，否则永远显示关闭。
// 2. 关闭态的白色叠加原来跟开启态太接近（0.72 vs 0.55），在纯色背景上
//    开关前后肉眼无差别，被当成"开关无效"（现已改成明显更实的磨砂板）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('旧键的 false 不会盖掉新默认值（默认开启）+ 旧键被清理', () async {
    // 模拟老版本留下的残留（Android 默认关闭时写进去的）
    SharedPreferences.setMockInitialValues({
      'settings.glassBlur': false,
      'settings.hardwareDecoding': true,
    });

    final settings = AppSettingsService.instance;
    await settings.ensureLoaded();

    expect(settings.glassBlur, isTrue,
        reason: '默认必须是开启；旧键的 false 不应该生效');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('settings.glassBlur'), isFalse,
        reason: '旧键应被清理，避免继续误导');
  });

  test('开关写入的是新键，且读回一致', () async {
    final settings = AppSettingsService.instance;

    await settings.setGlassBlur(false);
    expect(settings.glassBlur, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.glassBlurV2'), isFalse,
        reason: '持久化到 v2 键');

    await settings.setGlassBlur(true);
    expect(settings.glassBlur, isTrue);
    expect(prefs.getBool('settings.glassBlurV2'), isTrue);
  });
}
