import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/router/app_router.dart';
import 'core/theme/glass_theme.dart';
import 'services/device_info_service.dart';
import 'services/app_settings_service.dart';

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
    debugPrint('[VidFlow] MediaKit init failed: $e');
  }

  // 初始化设备信息
  try {
    await DeviceInfoService.instance.init();
  } catch (e) {
    debugPrint('[VidFlow] DeviceInfo init failed: $e');
  }

  // 预加载持久化设置，使播放器读取到正确默认值
  try {
    await AppSettingsService.instance.ensureLoaded();
  } catch (e) {
    debugPrint('[VidFlow] Settings load failed: $e');
  }

  // iPad Pro 锁定 120Hz
  if (DeviceInfoService.instance.has120Hz) {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  // 浸入式状态栏
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: GlassTheme.bg,
    systemNavigationBarIconBrightness: Brightness.light,
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
      title: 'VidFlow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: GlassTheme.bg,
        colorScheme: const ColorScheme.dark(
          primary: GlassTheme.accentPurple,
          secondary: GlassTheme.accentTeal,
          surface: GlassTheme.bgRaised,
          error: GlassTheme.accentPink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
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
        iconTheme: const IconThemeData(color: Colors.white70),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(
            color: Colors.white, fontSize: 24, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(
            color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
            color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(color: Colors.white70, fontSize: 16),
          bodyMedium: TextStyle(color: Colors.white60, fontSize: 14),
          bodySmall: TextStyle(color: Colors.white38, fontSize: 12),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),

      routerConfig: AppRouter.router,

      // iPad 键盘快捷键
      shortcuts: _buildShortcuts(),
      scrollBehavior: DeviceInfoService.instance.isIPad
          ? const MaterialScrollBehavior().copyWith(dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            })
          : null,
    );
  }

  Map<ShortcutActivator, Intent> _buildShortcuts() {
    return {
      LogicalKeySet(LogicalKeyboardKey.space): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit0): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit1): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit2): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit3): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit4): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit5): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit6): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit7): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit8): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.digit9): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyF): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyS): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyR): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyP): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.keyM): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.escape): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowLeft): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowRight): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowUp): const ActivateIntent(),
      LogicalKeySet(LogicalKeyboardKey.arrowDown): const ActivateIntent(),
    };
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
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),
                const Icon(Icons.error_outline, color: Color(0xFFFF6B9D), size: 48),
                const SizedBox(height: 16),
                const Text('VidFlow 启动失败',
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('请重启应用，如仍失败请联系开发者',
                    style: TextStyle(color: Colors.white54, fontSize: 14)),
                const SizedBox(height: 24),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      details.exceptionAsString(),
                      style: const TextStyle(color: Colors.white30, fontSize: 12, fontFamily: 'monospace'),
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