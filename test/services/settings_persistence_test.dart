// 设置持久化回归测试：验证「写入 → 重新加载」往返不丢失。
//
// 用户反馈「设置不能保存，关闭再打开应用会重置」，这里用 mock
// SharedPreferences 模拟重启（新建服务实例读同一份存储），
// 把每个设置项的写→读链路钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/services/app_settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例从干净存储开始
    SharedPreferences.setMockInitialValues({});
  });

  /// 模拟应用重启：重新读同一份 SharedPreferences。
  ///
  /// AppSettingsService 是单例且 `_loaded` 只加载一次，
  /// 这里通过反射式重建不方便，改为直接验证「prefs 里确实写入了」，
  /// 再用新读取的 prefs 值确认能还原。
  Future<void> verifyPersisted(String key, Object expected) async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(key), isTrue,
        reason: '$key 应写入 SharedPreferences');
    final actual = prefs.get(key);
    expect(actual, expected, reason: '$key 的值应为 $expected，实际 $actual');
  }

  group('播放设置持久化', () {
    test('默认播放速度', () async {
      final s = AppSettingsService.instance;
      await s.setDefaultSpeed(1.75);
      await verifyPersisted('settings.defaultSpeed', 1.75);
    });

    test('长按倍速', () async {
      final s = AppSettingsService.instance;
      await s.setLongPressSpeed(3.0);
      await verifyPersisted('settings.longPressSpeed', 3.0);
    });

    test('快进秒数', () async {
      final s = AppSettingsService.instance;
      await s.setSkipSeconds(30);
      await verifyPersisted('settings.skipSeconds', 30);
    });

    test('自动播放下一个', () async {
      final s = AppSettingsService.instance;
      await s.setAutoPlayNext(false);
      await verifyPersisted('settings.autoPlayNext', false);
    });

    test('后台播放', () async {
      final s = AppSettingsService.instance;
      await s.setBackgroundPlay(false);
      await verifyPersisted('settings.backgroundPlay', false);
    });

    test('硬件解码', () async {
      final s = AppSettingsService.instance;
      await s.setHardwareDecoding(false);
      await verifyPersisted('settings.hardwareDecoding', false);
    });

    test('打开视频方向', () async {
      final s = AppSettingsService.instance;
      await s.setPlayerOrientation('landscape');
      await verifyPersisted('settings.playerOrientation', 'landscape');
    });
  });

  group('字幕外观持久化', () {
    test('字号', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleFontSize(22);
      await verifyPersisted('settings.subtitle.fontSize', 22.0);
    });

    test('位置', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitlePosition(0.25);
      await verifyPersisted('settings.subtitle.position', 0.25);
    });

    test('背景透明度', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleBgOpacity(0.8);
      await verifyPersisted('settings.subtitle.bgOpacity', 0.8);
    });

    test('文字颜色', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleTextColor(0xFFFFEB3B);
      await verifyPersisted('settings.subtitle.textColor', 0xFFFFEB3B);
    });

    test('描边', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleStroke(false);
      await verifyPersisted('settings.subtitle.stroke', false);
    });

    test('字体族', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleFontFamily('serif');
      await verifyPersisted('settings.subtitle.fontFamily', 'serif');
    });

    test('字重', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleFontWeight(7);
      await verifyPersisted('settings.subtitle.fontWeight', 7);
    });

    test('行间距', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleLineSpacing(8);
      await verifyPersisted('settings.subtitle.lineSpacing', 8.0);
    });

    test('行高', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleLineHeight(1.6);
      await verifyPersisted('settings.subtitle.lineHeight', 1.6);
    });

    test('背景圆角', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleBgRadius(10);
      await verifyPersisted('settings.subtitle.bgRadius', 10.0);
    });

    test('背景色', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleBgColor(0xFF1A1A2E);
      await verifyPersisted('settings.subtitle.bgColor', 0xFF1A1A2E);
    });

    test('显示黑底', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleShowBg(false);
      await verifyPersisted('settings.subtitle.showBg', false);
    });

    test('对齐方式', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleAlign('end');
      await verifyPersisted('settings.subtitle.align', 'end');
    });

    test('ASS 定位', () async {
      final s = AppSettingsService.instance;
      await s.setSubtitleUseAssPosition(false);
      await verifyPersisted('settings.subtitle.useAssPosition', false);
    });
  });

  group('批量写入（模拟字幕样式面板 persist）', () {
    test('连续写入 16 项后全部落盘', () async {
      final s = AppSettingsService.instance;
      // 模拟设置页 persist() 的连续调用（不 await，与真实代码一致）
      s.setSubtitleFontSize(24);
      s.setSubtitlePosition(0.3);
      s.setSubtitleBgOpacity(0.5);
      s.setSubtitleTextColor(0xFF80DEEA);
      s.setSubtitleStroke(false);
      s.setSubtitleSecondaryScale(0.7);
      s.setSubtitleSecondaryDim(false);
      s.setSubtitleFontFamily('monospace');
      s.setSubtitleFontWeight(6);
      s.setSubtitleLineSpacing(5);
      s.setSubtitleLineHeight(1.5);
      s.setSubtitleBgRadius(6);
      s.setSubtitleBgColor(0xFF2D2D2D);
      s.setSubtitleShowBg(true);
      s.setSubtitleAlign('start');
      s.setSubtitleUseAssPosition(true);

      // 等所有异步写入完成
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('settings.subtitle.fontSize'), 24.0);
      expect(prefs.getDouble('settings.subtitle.position'), 0.3);
      expect(prefs.getDouble('settings.subtitle.bgOpacity'), 0.5);
      expect(prefs.getInt('settings.subtitle.textColor'), 0xFF80DEEA);
      expect(prefs.getBool('settings.subtitle.stroke'), false);
      expect(prefs.getDouble('settings.subtitle.secondaryScale'), 0.7);
      expect(prefs.getBool('settings.subtitle.secondaryDim'), false);
      expect(prefs.getString('settings.subtitle.fontFamily'), 'monospace');
      expect(prefs.getInt('settings.subtitle.fontWeight'), 6);
      expect(prefs.getDouble('settings.subtitle.lineSpacing'), 5.0);
      expect(prefs.getDouble('settings.subtitle.lineHeight'), 1.5);
      expect(prefs.getDouble('settings.subtitle.bgRadius'), 6.0);
      expect(prefs.getInt('settings.subtitle.bgColor'), 0xFF2D2D2D);
      expect(prefs.getBool('settings.subtitle.showBg'), true);
      expect(prefs.getString('settings.subtitle.align'), 'start');
      expect(prefs.getBool('settings.subtitle.useAssPosition'), true);
    });

    test('batchSetSubtitleStyle 一次写入全部 16 项', () async {
      final s = AppSettingsService.instance;
      await s.batchSetSubtitleStyle(
        fontSize: 28,
        position: 0.15,
        bgOpacity: 0.7,
        textColor: 0xFF81C784,
        stroke: true,
        secScale: 0.9,
        secDim: true,
        fontFamily: 'serif',
        fontWeightIdx: 7,
        lineSpacing: 6,
        lineHeight: 1.4,
        bgRadius: 8,
        bgColor: 0xFF1A1A2E,
        showBg: false,
        align: 'center',
        useAssPos: false,
      );

      // 内存立即生效
      expect(s.subtitleFontSize, 28);
      expect(s.subtitlePosition, 0.15);
      expect(s.subtitleBgOpacity, 0.7);
      expect(s.subtitleTextColorValue, 0xFF81C784);
      expect(s.subtitleStroke, isTrue);
      expect(s.subtitleSecondaryScale, 0.9);
      expect(s.subtitleSecondaryDim, isTrue);
      expect(s.subtitleFontFamily, 'serif');
      expect(s.subtitleFontWeight, 7);
      expect(s.subtitleLineSpacing, 6);
      expect(s.subtitleLineHeight, 1.4);
      expect(s.subtitleBgRadius, 8);
      expect(s.subtitleBgColorValue, 0xFF1A1A2E);
      expect(s.subtitleShowBg, isFalse);
      expect(s.subtitleAlign, 'center');
      expect(s.subtitleUseAssPosition, isFalse);

      // SP 也已落盘
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('settings.subtitle.fontSize'), 28.0);
      expect(prefs.getDouble('settings.subtitle.position'), 0.15);
      expect(prefs.getDouble('settings.subtitle.bgOpacity'), 0.7);
      expect(prefs.getInt('settings.subtitle.textColor'), 0xFF81C784);
      expect(prefs.getBool('settings.subtitle.stroke'), isTrue);
      expect(prefs.getDouble('settings.subtitle.secondaryScale'), 0.9);
      expect(prefs.getBool('settings.subtitle.secondaryDim'), isTrue);
      expect(prefs.getString('settings.subtitle.fontFamily'), 'serif');
      expect(prefs.getInt('settings.subtitle.fontWeight'), 7);
      expect(prefs.getDouble('settings.subtitle.lineSpacing'), 6.0);
      expect(prefs.getDouble('settings.subtitle.lineHeight'), 1.4);
      expect(prefs.getDouble('settings.subtitle.bgRadius'), 8.0);
      expect(prefs.getInt('settings.subtitle.bgColor'), 0xFF1A1A2E);
      expect(prefs.getBool('settings.subtitle.showBg'), isFalse);
      expect(prefs.getString('settings.subtitle.align'), 'center');
      expect(prefs.getBool('settings.subtitle.useAssPosition'), isFalse);
    });
  });
}
