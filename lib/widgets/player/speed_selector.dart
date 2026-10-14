import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/constants/app_constants.dart';
import '../glass/safe_glass.dart';

/// 倍速选择器弹出面板 — 玻璃质感
class SpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final void Function(double) onSpeedSelected;
  final VoidCallback onDismiss;

  const SpeedSelector({
    super.key,
    required this.currentSpeed,
    required this.onSpeedSelected,
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
                    Colors.white.withOpacity(0.8),
                    Colors.white.withOpacity(0.5),
                  ],
                ),
                borderRadius: BorderRadius.circular(GlassTheme.radiusMd),
                border: Border.all(
                    color: Colors.black.withOpacity(0.06), width: 0.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 8, bottom: 8),
                    child: Text(
                      '播放速度',
                      style: TextStyle(
                        color: GlassTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ...AppConstants.playbackSpeeds.map((speed) {
                    final isActive = speed == currentSpeed;
                    return GestureDetector(
                      onTap: () => onSpeedSelected(speed),
                      child: Container(
                        width: 80,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isActive
                              ? GlassTheme.accentPurple.withOpacity(0.2)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${speed}x',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isActive
                                ? GlassTheme.accentPurple
                                : GlassTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: isActive
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
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