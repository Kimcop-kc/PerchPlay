import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/app_settings_service.dart';

/// 液态玻璃实时模糊开关（默认开启）
///
/// 单独做成 provider 是为了让开关**即时生效**：导航栏在 shell 里，
/// 设置页改完要立刻重绘，不能等下次切页。
/// 真正的持久化仍在 [AppSettingsService]。
final glassBlurProvider = StateProvider<bool>(
  (ref) => AppSettingsService.instance.glassBlur,
);
