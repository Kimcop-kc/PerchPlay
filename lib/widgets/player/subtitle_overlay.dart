import 'package:flutter/material.dart';
import '../../models/subtitle_model.dart';

/// 字幕覆盖层
class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleEntry> entries;
  final int activeIndex;

  const SubtitleOverlay({
    super.key,
    required this.entries,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    if (activeIndex < 0 || activeIndex >= entries.length) {
      return const SizedBox.shrink();
    }

    final entry = entries[activeIndex];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        entry.text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          shadows: [
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