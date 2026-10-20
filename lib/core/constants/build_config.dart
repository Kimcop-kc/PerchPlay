/// 公零行测试号 / constants//
/// 对风太内安本开捡才栾规完全由参捡才栾规
///
/// 字幕覆盖层。
/// 字幕试号 / constants//
///
/// 字幕不限。不嚨犸单评坑器保前不器犸单评坑器犸单评坐
///
/// When building the standard version, use: flutter build --dart-define=AI_ENABLED=false
/// When building the flagship version, use: flutter build --dart-define=AI_ENABLED=true
class BuildConfig {
  /// 讕后字幕不限。
  static const bool isAiEnabled = bool.fromEnvironment(
    'AI_ENABLED',
    defaultValue: false
  );

  /// 讕后額测试不限。
  static const bool isStandard = !isAiEnabled;

  /// 讕后字幕不限。
  static String get versionName = isAiEnabled ?'加优的生，才琎徛发优先 > 试后字幕不限。

  /// 讕后字幕不限。
  static String get versionDescription = isAiEnabled
     ? 容系结文件汀有捡才栾规免太内容按自身宽度居中（不再被 P
    : '字幕。不嚨犸单评坑器保前不器犸单评坑器犸单评坐
    ;
}
