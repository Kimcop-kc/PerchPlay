import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 原生平台桥接服务
/// 调用 Android/iOS 原生方法处理 ROM 特定需求
class NativeBridgeService {
  NativeBridgeService._();
  static final instance = NativeBridgeService._();

  static const _channel = MethodChannel('com.vidflow/native');
  static const _pipChannel = MethodChannel('com.vidflow/pip');

  // ──────────── ROM 检测 ────────────

  /// 外部 App「用其他应用打开」进来的视频 URI（冷启动时有效）。
  ///
  /// 调用一次即清空（原生侧不会重复给同一个 URI）。
  /// 返回 `content://...` 或 `file://...`，null = 正常启动。
  Future<String?> takeLaunchVideoUri() async {
    try {
      return await _channel.invokeMethod<String>('getLaunchVideoUri');
    } catch (_) {
      return null;
    }
  }

  /// 远程控制（锁屏 / 控制中心）事件回调。
  static void Function(String command, Object? argument)? _onRemoteCommand;

  /// 注册远程控制事件回调（iOS 锁屏界面 / 控制中心的播放、暂停、快进等）。
  ///
  /// 原生侧 AppDelegate 的 MPRemoteCommandCenter 会把事件通过
  /// `remoteCommand` 方法发过来。之前 iOS 只往 NotificationCenter 发通知、
  /// Dart 侧无人监听，导致**锁屏和控制中心的按钮点了完全没反应**。
  void registerRemoteCommandHandler(
    void Function(String command, Object? argument) onCommand,
  ) {
    _onRemoteCommand = onCommand;
    _installChannelHandler();
  }

  /// 统一安装通道方法处理器（openVideoUri / remoteCommand）。
  ///
  /// 之前 registerLaunchUriHandler 里直接 setMethodCallHandler，会覆盖掉
  /// 其它监听者。现在收敛成一个分发入口。
  void _installChannelHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'openVideoUri':
          final uri = call.arguments as String?;
          if (uri != null && uri.isNotEmpty) {
            _onLaunchUri?.call(uri);
          }
        case 'remoteCommand':
          final args = call.arguments;
          if (args is Map) {
            final cmd = args['command']?.toString() ?? '';
            if (cmd.isNotEmpty) {
              _onRemoteCommand?.call(cmd, args['argument']);
            }
          }
      }
      return null;
    });
  }

  static void Function(String uri)? _onLaunchUri;

  /// 注册热启动回调：App 在后台时被外部 App 再次唤起。
  ///
  /// 必须在 Dart 侧尽早调用（main() 里），否则热启动的 URI 会丢。
  Future<void> registerLaunchUriHandler(
    void Function(String uri) onOpen,
  ) async {
    _onLaunchUri = onOpen;
    _installChannelHandler();
    try {
      await _channel.invokeMethod('readyForLaunchUri');
    } catch (_) {}
  }

  /// 更新 iOS 锁屏 / 控制中心的「正在播放」信息。
  ///
  /// 不设置的话锁屏不显示标题和进度，控制中心的播放控制也可能不出现。
  /// 非 iOS 平台直接跳过。
  Future<void> updateNowPlaying({
    required String title,
    String? artist,
    required Duration duration,
    required Duration position,
    required bool isPlaying,
  }) async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('updateNowPlaying', {
        'title': title,
        'artist': artist ?? '',
        'durationSec': duration.inMilliseconds / 1000.0,
        'positionSec': position.inMilliseconds / 1000.0,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  /// 把 content:// URI 解析成可播放的本地路径。
  ///
  /// 原生侧会先尝试 MediaStore 的 _DATA 列（零拷贝），拿不到才复制到
  /// 应用缓存目录。返回 null 表示无法解析。
  Future<String?> resolveVideoUri(String uri) async {
    try {
      return await _channel.invokeMethod<String>('resolveVideoUri', {
        'uri': uri,
      });
    } catch (_) {
      return null;
    }
  }

  Future<String> getRomBrand() async {
    try {
      return await _channel.invokeMethod('getRomBrand') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<bool> isMiui() async {
    try {
      return await _channel.invokeMethod('isMiui') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEmui() async {
    try {
      return await _channel.invokeMethod('isEmui') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isColorOS() async {
    try {
      return await _channel.invokeMethod('isColorOS') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 权限请求 ────────────

  /// 请求忽略电池优化（小米/华为/OPPO/vivo 需要）
  Future<bool> requestBatteryOptimization() async {
    try {
      return await _channel.invokeMethod('requestBatteryOptimization') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求悬浮窗权限（中国 ROM 默认禁止）
  Future<bool> requestOverlayPermission() async {
    try {
      return await _channel.invokeMethod('requestOverlayPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开自启动设置
  Future<bool> requestAutoStart() async {
    try {
      return await _channel.invokeMethod('requestAutoStart') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开应用设置
  Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod('openAppSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 检查悬浮窗权限状态
  Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod('canDrawOverlays') ?? false;
    } catch (_) {
      return true; // iOS 默认 true
    }
  }

  /// 检查电池优化豁免状态
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return true; // iOS 默认 true
    }
  }

  // ──────────── 所有文件访问权限 / MediaStore ────────────

  /// 是否已获得「所有文件访问权限」（Android 11+ 的 MANAGE_EXTERNAL_STORAGE）
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod('hasAllFilesAccess') ?? false;
    } catch (_) {
      return true; // iOS 无需该权限
    }
  }

  /// 直接跳到系统「所有文件访问」授权开关页
  Future<void> requestAllFilesAccess() async {
    try {
      await _channel.invokeMethod('requestAllFilesAccess');
    } catch (_) {}
  }

  /// 用系统媒体库索引查询全部视频（快，且带时长/分辨率）
  Future<List<Map<String, dynamic>>> queryMediaStoreVideos() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'queryMediaStoreVideos',
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 告诉系统媒体库：这个路径的文件已经被删除了
  ///
  /// 为什么需要：直接 `File.delete()` 不会更新 MediaStore 索引，相册和其它
  /// 播放器还能看到一条指向不存在文件的记录（点开就是黑屏/报错）。
  /// 原生侧用 MediaScannerConnection 重新扫这个路径，文件不存在时系统会
  /// 自己把索引记录收敛掉 —— 这是系统给的标准通道，不需要额外依赖/权限。
  ///
  /// 失败（非 Android、通道异常、ROM 不响应）时返回 false 并忽略：
  /// 文件已经删掉了，这里只是"顺手通知"，不该让删除操作报错。
  Future<bool> notifyMediaDeleted(String path) async {
    if (kIsWeb) return false;
    if (path.trim().isEmpty) return false;
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('notifyMediaDeleted', {
        'path': path,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 应用内更新 ────────────

  /// 用系统安装器安装已下载的 APK（路径在应用缓存目录内）。
  Future<bool> installApk(String path) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('installApk', {
        'path': path,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 设备信息 ────────────

  Future<String> getDeviceModel() async {
    try {
      return await _channel.invokeMethod('getDeviceModel') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  Future<String> getSystemName() async {
    try {
      return await _channel.invokeMethod('getSystemName') ?? 'Unknown';
    } catch (_) {
      return 'Unknown';
    }
  }

  /// Android API 等级（26 = Android 8.0，29 = Android 10）。
  ///
  /// 非 Android 平台返回 0。用于决定系统栏模式：
  /// `edgeToEdge` 只有 Android 10(29)+ 支持，低版本必须用 `manual`，
  /// 否则导航栏会变成不透明黑条遮住页面底部。
  Future<int> getAndroidSdkInt() async {
    if (kIsWeb || !Platform.isAndroid) return 0;
    try {
      return await _channel.invokeMethod<int>('getAndroidSdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 系统导航栏的真实像素高度（0 = 无导航栏 / 非 Android）。
  ///
  /// 为什么必须问原生，而不能靠 `MediaQuery`：
  ///
  /// 我们的 `styles.xml` 把 `navigationBarColor` 设成 transparent，
  /// 内容实际是画到导航栏底下的。但 Flutter 在 Android 8/9 上走 `manual`
  /// 模式时，`MediaQuery.padding.bottom` 会被算成 0（系统认为「内容不延伸」），
  /// `viewPadding.bottom` 在部分 ROM 上同样给 0。
  ///
  /// 两个值都不可信，就只能直接问窗口真实配置：
  /// 用 `WindowInsets` / `getRealMetrics` 拿系统栏实际占位。
  Future<double> getNavigationBarHeightDp() async {
    if (kIsWeb || !Platform.isAndroid) return 0;
    try {
      final v = await _channel.invokeMethod<num>('getNavigationBarHeightDp');
      return v?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 查询设备真实 HDR 显示能力（仅 Android 24+）。
  ///
  /// 返回 null 表示拿不到（非 Android / API < 24 / 异常）。
  /// 拿到时含：
  ///  - `hdr10` / `hdr10Plus` / `dolbyVision` / `hlg`：各自是否支持
  ///  - `maxLuminance`：峰值亮度 nit（拿不到为 -1）
  Future<Map<String, dynamic>?> getHdrCapabilities() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final v = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'getHdrCapabilities');
      if (v == null) return null;
      return v.map((k, val) => MapEntry(k.toString(), val));
    } catch (_) {
      return null;
    }
  }

  Future<bool> isIPad() async {
    try {
      return await _channel.invokeMethod('isIPad') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isIPadPro() async {
    try {
      return await _channel.invokeMethod('isIPadPro') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> supportStageManager() async {
    try {
      return await _channel.invokeMethod('supportStageManager') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> support120Hz() async {
    try {
      return await _channel.invokeMethod('support120Hz') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 后台播放前台服务 ────────────

  /// 启动前台服务（息屏/内存回收下继续播放，并显示通知）
  Future<bool> startBackgroundService() async {
    try {
      return await _channel.invokeMethod('startBackgroundService') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopBackgroundService() async {
    try {
      return await _channel.invokeMethod('stopBackgroundService') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── SSDP 组播锁 ────────────

  /// 获取 Wi-Fi 组播锁（Android 不持锁会丢弃组播包，投屏搜不到设备）
  Future<bool> acquireMulticastLock() async {
    try {
      return await _channel.invokeMethod('acquireMulticastLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> releaseMulticastLock() async {
    try {
      await _channel.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }

  // ──────────── 画中画 ────────────

  Future<bool> enterPiP() async {
    try {
      return await _pipChannel.invokeMethod('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isPipSupported() async {
    try {
      return await _pipChannel.invokeMethod('isPipSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ──────────── 一键优化（批量请求权限） ────────────

  /// 针对中国品牌 ROM 的一键优化：
  /// 1. 电池优化白名单
  /// 2. 悬浮窗权限
  /// 3. 自启动（华为/OPPO/vivo）
  Future<void> oneClickOptimize() async {
    await requestBatteryOptimization();
    // 延迟以便上一个设置页面打开
    await Future.delayed(const Duration(milliseconds: 500));
    await requestOverlayPermission();
    await Future.delayed(const Duration(milliseconds: 500));
    await requestAutoStart();
  }
}
