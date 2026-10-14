import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../providers/library_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: library.when(
          data: (videos) {
            final watched = videos
                .where((v) => v.lastPosition > 0)
                .toList()
              ..sort((a, b) {
                final aTime = a.lastPlayed;
                final bTime = b.lastPlayed;
                if (aTime == null) return bTime == null ? 0 : 1;
                if (bTime == null) return -1;
                return bTime.compareTo(aTime);
              });

            if (watched.isEmpty) return _buildEmpty();
            return CustomScrollView(
              slivers: [
                _buildHeader(watched.length),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final video = watched[index];
                        final progress =
                            video.durationMs > 0
                                ? video.lastPosition / video.durationMs
                                : 0.0;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassCard(
                            radius: GlassTheme.radiusMd,
                            tint: GlassTheme.tintPurple,
                            padding: const EdgeInsets.all(12),
                            onTap: () => context.pushNamed('player', extra: {
                              'videoPath': video.path,
                              'videoTitle': video.name,
                            }),
                            child: Row(
                              children: [
                                // 缩略图
                                Container(
                                  width: 88,
                                  height: 56,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                        GlassTheme.radiusXs),
                                    color: Colors.white.withOpacity(0.04),
                                  ),
                                  child: const Icon(Icons.play_circle_rounded,
                                      size: 28, color: Colors.white24),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(video.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Icon(Icons.schedule_rounded,
                                              size: 12,
                                              color: Colors.white30),
                                          const SizedBox(width: 4),
                                          Text(
                                            _formatDate(video.lastPlayed),
                                            style: const TextStyle(
                                                color: Colors.white38,
                                                fontSize: 11),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      // mini 进度条
                                      if (progress > 0 && progress < 1)
                                        Container(
                                          height: 3,
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(2),
                                            color: Colors.white.withOpacity(0.06),
                                          ),
                                          child: FractionallySizedBox(
                                            alignment: Alignment.centerLeft,
                                            widthFactor: progress,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(2),
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    GlassTheme.accentPurple,
                                                    GlassTheme.accentTeal,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                // 继续播放
                                GlassButton.outlined(
                                  label: '继续',
                                  height: 32,
                                  radius: GlassTheme.radiusXs,
                                  foregroundColor: GlassTheme.accentPurple,
                                  onTap: () =>
                                      context.pushNamed('player', extra: {
                                    'videoPath': video.path,
                                    'videoTitle': video.name,
                                  }),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      childCount: watched.length,
                    ),
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: GlassTheme.accentPurple),
          ),
          error: (e, _) => Center(
            child: Text('⚠ $e', style: const TextStyle(color: Colors.white54)),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(int count) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Row(
          children: [
            const Text('观看历史',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800)),
            const SizedBox(width: 10),
            GlassPanel(
              radius: GlassTheme.radiusXs,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text('$count',
                  style: const TextStyle(
                      color: GlassTheme.accentPurple,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 48, color: Colors.grey[700]),
            const SizedBox(height: 12),
            const Text('暂无观看记录',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '未知时间';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}
