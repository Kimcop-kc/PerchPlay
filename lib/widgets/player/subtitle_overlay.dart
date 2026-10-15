import 'package:flutter/material.dart';
import '../../models/subtitle_model.dart';

/// 字幕覆盖层
///
/// 主字幕由 mpv 绘制（内嵌/外挂都行）；这个浮层用于
/// 「第二字幕」——把外挂字幕解析成条目自己画，从而与主字幕同屏显示。
class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleEntry> entries;
  final int activeIndex;

  /// 字号（第二字幕用小一号）
  final double fontSize;

  /// 紧凑样式：更小的内边距与圆角
  final bool compact;

  const SubtitleOverlay({
    super.key,
    required this.entries,
    required this.activeIndex,
    this.fontSize = 16,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (activeIndex < 0 || activeIndex >= entries.length) {
      return const SizedBox.shrink();
    }

    final entry = entries[activeIndex];

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16, vertical: compact ? 5 : 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: Text(
        entry.text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          shadows: const [
            Shadow(
              color: Colors.black87,
              blurRadius: 4,
              offset: Offset(1, 1),
            ),
          ],
        ),
      ),
    );
  }
}