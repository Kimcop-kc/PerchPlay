/// 字幕文件名安全工具。
///
/// 下载的字幕文件名来自外部服务，可能含非法字符、路径分隔符、
/// 路径穿越（`../`）等。保存前必须清理。
class SubtitleFileName {
  SubtitleFileName._();

  /// 清理文件名：去掉路径分隔符、路径穿越、控制字符和非法字符。
  ///
  /// 只保留字母、数字、中文、下划线、连字符、点、空格。
  /// 空结果返回 `subtitle` 兜底。
  static String sanitize(String raw) {
    var name = raw.trim();

    // 去掉路径分隔符（Windows/Unix）
    name = name.replaceAll(RegExp(r'[\\/]'), '_');
    // 去掉路径穿越
    name = name.replaceAll('..', '_');
    // 去掉控制字符和非法字符（保留字母数字中文下划线连字符点空格括号）
    name = name.replaceAll(
      RegExp(r'[^\w\-. ()（）\[\]【】\u4e00-\u9fff]', unicode: true),
      '_',
    );
    // 折叠连续下划线/空格
    name = name.replaceAll(RegExp(r'_+'), '_');
    // 去掉首尾下划线和空格
    name = name.replaceAll(RegExp(r'^[_ ]+|[_ ]+$'), '');
    // 限制长度（文件名过长会超出文件系统限制）
    if (name.length > 120) {
      final ext = _extension(name);
      final base = name.substring(0, 120 - ext.length);
      name = '$base$ext';
    }
    // 空结果或只剩点/下划线 → 兜底
    if (name.isEmpty || name == '.' || name == '..') return 'subtitle';
    return name;
  }

  /// 提取扩展名（含点，小写）。无扩展名返回空串。
  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot);
  }

  /// 判断扩展名是否为受支持的字幕格式。
  static bool isSupportedFormat(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.srt') ||
        lower.endsWith('.ass') ||
        lower.endsWith('.ssa') ||
        lower.endsWith('.vtt') ||
        lower.endsWith('.sub') ||
        lower.endsWith('.zip');
  }
}
