import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'core/router/app_router.dart';
import 'core/system/orientation_policy.dart';
import 'core/system/system_ui_policy.dart';
import 'core/theme/glass_theme.dart';
import 'services/device_info_service.dart';
import 'services/app_settings_service.dart';
import 'services/native_bridge_service.dart';
import 'services/app_version.dart';

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

  // 读取真实版本号（应用内更新/关于页展示用）
  try {
    await AppVersion.ensureLoaded();
  } catch (e) {
    debugPrint('[PerchPlay] Version load failed: $e');
  }

  // 方向策略：手机锁竖屏，平板跟随物理方向。
  // 不能无脑锁竖屏 —— 平板横放时会被系统加黑边，画面缩成竖条、
  // 导航栏挤到侧边（见 OrientationPolicy 注释）。
  await OrientationPolicy.applyIdle();

  // 系统栏策略：Android 10+ 用 edgeToEdge，Android 9 及以下用 manual。
  // edgeToEdge 在低版本不受支持，会让导航栏变成不透明黑条遮住页面底部。
  await SystemUiPolicy.init();
  // 读一次导航栏真实高度（原生实测）。
  // 必须在 runApp 之前完成：bottomSheetInset 在 build 里同步调用，
  // 晚于首帧就会有一段「还没测到」的窗口期，二级菜单仍会被挡。
  await SystemUiPolicy.refreshNavBarHeight();
  await SystemUiPolicy.applyIdle(
    navigationBarColor: GlassTheme.bg,
    navigationIconBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.dark,
  );

  // ── 外部 App「用其他应用打开」进来的视频 ──
  //
  // 必须在 runApp 之前注册热启动回调，否则 App 在后台时被再次唤起会丢 URI。
  // 冷启动的 URI 也要尽早取走（原生侧只给一次）。
  await _setupExternalVideoOpen();

  runApp(
    const ProviderScope(
      child: VideoPlayerApp(),
    ),
  );
}

/// 待处理的「外部打开视频」URI（等路由就绪后再跳转）。
String? _pendingExternalUri;

/// 冷启动时取走 URI，并注册热启动回调。
Future<void> _setupExternalVideoOpen() async {
  final bridge = NativeBridgeService.instance;

  // 热启动：App 已在后台，被文件管理器再次唤起
  try {
    await bridge.registerLaunchUriHandler((uri) {
      debugPrint('[PerchPlay] 外部打开视频(热启动): $uri');
      _openExternalVideo(uri);
    });
  } catch (e) {
    debugPrint('[PerchPlay] 注册外部打开回调失败: $e');
  }

  // 冷启动：从桌面/文件管理器拉起的那一刻就带着视频
  try {
    final uri = await bridge.takeLaunchVideoUri();
    if (uri != null && uri.isNotEmpty) {
      debugPrint('[PerchPlay] 外部打开视频(冷启动): $uri');
      _pendingExternalUri = uri;
      // 等第一帧后再跳，确保 router 已挂载
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final u = _pendingExternalUri;
        if (u != null) {
          _pendingExternalUri = null;
          _openExternalVideo(u);
        }
      });
    }
  } catch (e) {
    debugPrint('[PerchPlay] 读取启动 URI 失败: $e');
  }
}

/// 把外部 URI 解析成本地路径并直接进播放页。
Future<void> _openExternalVideo(String uri) async {
  try {
    final path = await NativeBridgeService.instance.resolveVideoUri(uri);
    if (path == null || path.isEmpty) {
      debugPrint('[PerchPlay] 无法解析视频 URI: $uri');
      return;
    }
    final name = path.split(Platform.pathSeparator).last;
    AppRouter.router.pushNamed(
      'player',
      extra: <String, dynamic>{
        'videoPath': path,
        'videoTitle': name,
      },
    );
  } catch (e) {
    debugPrint('[PerchPlay] 打开外部视频失败: $e');
  }
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
        cardTheme: CardThemeData(
          color: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
          ),
        ),
        iconTheme: const IconThemeData(color: GlassTheme.textSecondary),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 32,
              fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w600),
          titleLarge: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600),
          titleMedium: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w500),
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
                const Icon(Icons.error_outline,
                    color: Color(0xFFFF4D6D), size: 48),
                const SizedBox(height: 16),
                const Text('PerchPlay 启动失败',
                    style: TextStyle(
                        color: Color(0xFF1C1C1E),
                        fontSize: 22,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('请重启应用，如仍失败请联系开发者',
                    style: TextStyle(color: Color(0xFF3C3C43), fontSize: 14)),
                const SizedBox(height: 24),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      details.exceptionAsString(),
                      style: const TextStyle(
                          color: Color(0xFF8E8E93),
                          fontSize: 12,
                          fontFamily: 'monospace'),
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
