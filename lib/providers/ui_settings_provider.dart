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

/// 字幕外观/渲染模式的变更信号。
///
/// 字幕浮层读的是 [AppSettingsService]（同步 getter），改完设置不会自动
/// 触发播放页重建 —— 表现得就像「设置不生效，得重新打开视频才行」。
/// 用一个自增计数当信号，设置面板改完 → 计数 +1 → 播放页 watch 到就重建。
final subtitleSettingsTickProvider = StateProvider<int>((ref) => 0);

/// 兼容旧名（只用于 ASS 原生渲染的语义）。实际语义已泛化为「字幕设置变更」。
final subtitleNativeAssTickProvider = subtitleSettingsTickProvider;

/// 翻译设置（后端/LLM Key/目标语言）变更信号。
///
/// 翻译设置改了之后需要让正在运行的翻译器重新读配置，否则改完得重启视频才生效。
final translateSettingsTickProvider = StateProvider<int>((ref) => 0);
