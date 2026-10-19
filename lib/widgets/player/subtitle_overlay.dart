import 'package:flutter/material.dart';

import '../../models/subtitle_model.dart';

/// 字幕覆盖层。
///
/// 两种用法：
/// - [entries] + [activeIndex]：旧的自绘浮层（第二字幕用，按条目命中显示）
/// - [lines]：统一字幕渲染（主字幕用，直接渲染 mpv 吐出的多行文本）
class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleEntry> entries;
  final int activeIndex;

  /// 多行字幕文本（统一渲染用，优先于 entries）。
  final List<String> lines;

  /// 字号。
  final double fontSize;

  /// 紧凑样式：更小的内边距与圆角。
  final bool compact;

  const SubtitleOverlay({
    super.key,
    this.entries = const [],
    this.activeIndex = -1,
    this.lines = const [],
    this.fontSize = 16,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    String? text;
    if (lines.isNotEmpty) {
      text = lines.where((l) => l.trim().isNotEmpty).join('\n');
    } else if (activeIndex >= 0 && activeIndex < entries.length) {
      text = entries[activeIndex].text;
    }

    if (text == null || text.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 5 : 8,
      ),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          height: 1.4,
          shadows: const [
            Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(1, 1)),
          ],
        ),
      ),
    );
  }
}
