class AppConstants {
  AppConstants._();

  static const String appName = 'PerchPlay';

  /// 版本号不再硬编码：应用内更新/关于页从系统读真实版本号，
  /// 见 services/app_version.dart（package_info_plus）。
  /// 这里保留注释说明，避免后人又加回一个会脱节的常量。

  // 支持的视频格式
  static const List<String> supportedVideoFormats = [
    'mp4',
    'mkv',
    'avi',
    'mov',
    'wmv',
    'flv',
    'webm',
    'm4v',
    'mpg',
    'mpeg',
    '3gp',
    '3g2',
    'ts',
    'm2ts',
    'vob',
    'ogv',
    'divx',
    'xvid',
    'rmvb',
    'asf',
    'f4v',
  ];

  // 字幕格式
  static const List<String> supportedSubtitleFormats = [
    'srt',
    'ass',
    'ssa',
    'vtt',
    'sub',
  ];

  // 倍速选项
  static const List<double> playbackSpeeds = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  // 手势灵敏度
  static const double brightnessSensitivity = 0.01;
  static const double volumeSensitivity = 0.01;
  static const int seekSeconds = 10;
}
