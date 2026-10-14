import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import '../../models/subtitle_model.dart';
import '../glass/safe_glass.dart';

/// 字幕选择器弹出面板 — 玻璃质感
class SubtitleSelector extends StatelessWidget {
  final List<SubtitleModel> subtitles;
  final SubtitleModel? activeSubtitle;
  final void Function(SubtitleModel) onSubtitleSelected;
  final VoidCallback onDisable;
  final VoidCallback onDismiss;

  const SubtitleSelector({
    super.key,
    required this.subtitles,
    this.activeSubtitle,
    required this.onSubtitleSelected,
    required this.onDisable,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: Material(
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
          child: SafeBackdropFilter(
            blurSigma: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.08),
                    Colors.white.withOpacity(0.03),
                  ],
                ),
                borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
                border: Border.all(
                    color: Colors.white.withOpacity(0.08), width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 8),
                    child: Text(
                      '字幕选择',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 关闭字幕
                  GestureDetector(
                    onTap: onDisable,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: activeSubtitle == null
                            ? GlassTheme.accentPurple.withOpacity(0.2)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.closed_caption_off_rounded,
                              size: 16,
                              color: activeSubtitle == null
                                  ? GlassTheme.accentPurple
                                  : Colors.white54),
                          const SizedBox(width: 6),
                          Text(
                            '关闭',
                            style: TextStyle(
                              color: activeSubtitle == null
                                  ? GlassTheme.accentPurple
                                  : Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 字幕列表
                  if (subtitles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('未找到外挂字幕',
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12)),
                    )
                  else
                    ...subtitles.map((sub) {
                      final isActive = activeSubtitle?.path == sub.path;
                      return GestureDetector(
                        onTap: () => onSubtitleSelected(sub),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isActive
                                ? GlassTheme.accentPurple.withOpacity(0.2)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                sub.isEmbedded
                                    ? Icons.video_file_rounded
                                    : Icons.insert_drive_file_rounded,
                                size: 14,
                                color: isActive
                                    ? GlassTheme.accentPurple
                                    : Colors.white54,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                sub.title,
                                style: TextStyle(
                                  color: isActive
                                      ? GlassTheme.accentPurple
                                      : Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}