import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/router/app_router.dart';
import 'core/theme/glass_theme.dart';
import 'services/device_info_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Release mode ?? ? ???????????
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // ???? ? ?????????
    if (details.silent != true) {
      runApp(_CrashScreen(details: details));
    }
  };

  // media_kit native ?????????????
  try {
    MediaKit.ensureInitialized();
  } catch (e) {
    debugPrint('[VidFlow] MediaKit init failed: $e');
  }

  // ???????
  try {
    await DeviceInfoService.instance.init();
  } catch (e) {
    debugPrint('[VidFlow] DeviceInfo init failed: $e');
  }

  // iPad Pro ?? 120Hz
  if (DeviceInfoService.instance.has120Hz) {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  // ??????
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: GlassTheme.bg,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  // ?????????(iOS 27 ??)
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

      // iPad ?????
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

/// ????????????,?????????
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
                const Text('VidFlow ????',
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('?????,??????????',
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