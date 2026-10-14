import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/router/app_router.dart';
import 'core/theme/glass_theme.dart';
import 'services/device_info_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // 初始化设备信息
  await DeviceInfoService.instance.init();

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
        cardTheme: CardThemeData(
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
      for (var i = 0; i <= 9; i++)
        LogicalKeySet(LogicalKeyboardKey.digit0 + i): const ActivateIntent(),
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