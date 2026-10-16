// 鍥炲綊娴嬭瘯锛氭恫鎬佺幓鐠冨疄鏃舵ā绯婂紑鍏充负浠€涔?鐪嬭捣鏉ユ病鐢?/ 榛樿鏄叧闂殑"
//
// 鐪熷疄鍘熷洜鏈変袱涓紝閮藉湪杩欓噷閽夋锛?// 1. 鏃╂湡鐗堟湰 Android 榛樿鍏抽棴锛岀敤鎴蜂竴鎸夊紑鍏冲氨鍐欏叆浜?settings.glassBlur=false锛?//    鏂扮増鏈敼鐢?v2 閿?+ 榛樿 true锛屽繀椤?*蹇界暐鏃ч敭**锛屽惁鍒欐案杩滄樉绀哄叧闂€?// 2. 鍏抽棴鎬佺殑鐧借壊鍙犲姞鍘熸潵璺熷紑鍚€佸お鎺ヨ繎锛?.72 vs 0.55锛夛紝鍦ㄧ函鑹茶儗鏅笂
//    寮€鍏冲墠鍚庤倝鐪兼棤宸埆锛岃褰撴垚"寮€鍏虫棤鏁?锛堢幇宸叉敼鎴愭槑鏄炬洿瀹炵殑纾ㄧ爞鏉匡級銆?import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:perchplay/services/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('鏃ч敭鐨?false 涓嶄細鐩栨帀鏂伴粯璁ゅ€硷紙榛樿寮€鍚級+ 鏃ч敭琚竻鐞?, () async {
    // 妯℃嫙鑰佺増鏈暀涓嬬殑娈嬬暀锛圓ndroid 榛樿鍏抽棴鏃跺啓杩涘幓鐨勶級
    SharedPreferences.setMockInitialValues({
      'settings.glassBlur': false,
      'settings.hardwareDecoding': true,
    });

    final settings = AppSettingsService.instance;
    await settings.ensureLoaded();

    expect(settings.glassBlur, isTrue,
        reason: '榛樿蹇呴』鏄紑鍚紱鏃ч敭鐨?false 涓嶅簲璇ョ敓鏁?);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('settings.glassBlur'), isFalse,
        reason: '鏃ч敭搴旇娓呯悊锛岄伩鍏嶇户缁瀵?);
  });

  test('寮€鍏冲啓鍏ョ殑鏄柊閿紝涓旇鍥炰竴鑷?, () async {
    final settings = AppSettingsService.instance;

    await settings.setGlassBlur(false);
    expect(settings.glassBlur, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('settings.glassBlurV2'), isFalse,
        reason: '鎸佷箙鍖栧埌 v2 閿?);

    await settings.setGlassBlur(true);
    expect(settings.glassBlur, isTrue);
    expect(prefs.getBool('settings.glassBlurV2'), isTrue);
  });
}
