import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/router/app_router.dart';
import 'core/theme/glass_theme.dart';
import 'services/device_info_service.dart';
import 'services/app_settings_service.dart';
import 'services/native_bridge_service.dart';
import 'services/scrape_cache_service.dart';

/// 应用根组件是否已成功挂载。
/// 挂载后出现的局部 FlutterError 不再整屏替换崩溃页，
/// 避免一次可恢复的 UI 错误把整个应用覆盖掉。
bool _appMounted = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 兜底错误处理：仅记录，不在启动后重复替换根应用。
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (!_appMounted && details.silent != true) {
      runApp(_CrashScreen(details: details));
    }
  };

  // media_kit native 初始化可能在某些设备上失败
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('[PerchPlay] MediaKit init failed: $e');
  }

  // 初始化设备信息（型号/系统名从原生取，否则 Android 品牌识别
  // 恒为 other，「系统优化」整块功能不会显示）
  try {
    String? model;
    String? system;
    try {
      model = await NativeBridgeService.instance.getDeviceModel();
      system = await NativeBridgeService.instance.getSystemName();
    } catch (_) {}
    await DeviceInfoService.instance.init(
      deviceModel: model,
      systemName: system,
    );
  } catch (e) {
    debugPrint('[PerchPlay] DeviceInfo init failed: $e');
  }

  // 预加载持久化设置，使播放器读取到正确默认值
  try {
    await AppSettingsService.instance.ensureLoaded();
  } catch (e) {
    debugPrint('[PerchPlay] Settings load failed: $e');
  }

  // 如果已设置过 TMDB API key，启用刮削
  final apiKey = AppSettingsService.instance.tmdbApiKey;
  if (apiKey.isNotEmpty) {
    try {
      ScrapeCacheService.instance.init(apiKey: apiKey);
    } catch (e) {
      debugPrint('[PerchPlay] Scrape init failed: $e');
    }
  }

  // 首页/列表/设置固定竖屏；只有播放器全屏时临时切横屏
  // （之前放开 4 个方向，导致横屏看视频退出后停在横屏）
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 浸入式状态栏（浅色主题：深色图标）
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: GlassTheme.bg,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  // 启用边缘到边缘渲染（iOS 27 风格）
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(
    const ProviderScope(
      child: VideoPlayerApp(),
    ),
  );
}

class VideoPlayerApp extends StatelessWidget {
  const VideoPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    _appMounted = true;
    return MaterialApp.router(
      title: 'PerchPlay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: GlassTheme.bg,
        colorScheme: const ColorScheme.light(
          primary: GlassTheme.accentPurple,
          secondary: GlassTheme.accentTeal,
          surface: Colors.white,
          error: GlassTheme.accentPink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: GlassTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        cardTheme: CardTheme(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
          ),
        ),
        iconTheme: const IconThemeData(color: GlassTheme.textSecondary),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: GlassTheme.textPrimary, fontSize: 32, fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(
            color: GlassTheme.textPrimary, fontSize: 24, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(
            color: GlassTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
            color: GlassTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(color: GlassTheme.textSecondary, fontSize: 16),
          bodyMedium: TextStyle(color: GlassTheme.textSecondary, fontSize: 14),
          bodySmall: TextStyle(color: GlassTheme.textTertiary, fontSize: 12),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),

      routerConfig: AppRouter.router,

      // 说明：这里原来注册了 21 个 Shortcuts → ActivateIntent 映射，
      // 但没有任何 Actions 消费它，等于把空格/方向键等按键吞掉却不做事，
      // 还会和播放器里真正的键盘处理（KeyboardShortcutHandler）抢事件。
      // 已移除；快捷键统一由 KeyboardShortcutHandler 处理。
      scrollBehavior: DeviceInfoService.instance.isIPad
          ? const MaterialScrollBehavior().copyWith(dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            })
          : null,
    );
  }
}

/// 致命错误时的简易崩溃界面，避免用户看到纯黑屏
class _CrashScreen extends StatelessWidget {
  final FlutterErrorDetails details;
  const _CrashScreen({required this.details});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      home: Scaffold(
        backgroundColor: const Color(0xFFF2F2F7),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),
                const Icon(Icons.error_outline, color: Color(0xFFFF4D6D), size: 48),
                const SizedBox(height: 16),
                const Text('PerchPlay 启动失败',
                    style: TextStyle(color: Color(0xFF1C1C1E), fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('请重启应用，如仍失败请联系开发者',
                    style: TextStyle(color: Color(0xFF3C3C43), fontSize: 14)),
                const SizedBox(height: 24),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      details.exceptionAsString(),
                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}