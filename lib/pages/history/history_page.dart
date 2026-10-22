import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/glass_theme.dart';
import '../../providers/library_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/common/app_page_header.dart';
import '../../widgets/video/cover_thumb.dart';

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    /// 使用 [playHistoryProvider]（直接查 playback_history JOIN videos），
    /// 而不是 [libraryProvider]。后者是 AsyncNotifier，只在 scan() 时从 DB
    /// 读一次之后不进 refresh()——播放结束写库的进度/时间永远不会反应到 UI。
    final history = ref.watch(playHistoryProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        bottom: false,
        child: history.when(
          data: (videos) {
            if (videos.isEmpty) return _buildEmpty();
            return CustomScrollView(
              slivers: [
                _buildHeader(context, videos.length),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                      AppBreakpoints.horizontalPadding(context),
                      0,
                      AppBreakpoints.horizontalPadding(context),
                      GlassTheme.navBarOverlay),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final video = videos[index];
                        final progress = video.durationMs > 0
                            ? video.lastPosition / video.durationMs
                            : 0.0;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 720),
                              child: GlassCard(
                                radius: GlassTheme.radiusMd,
                                tint: GlassTheme.tintPurple,
                                padding: const EdgeInsets.all(12),
                                onTap: () async {
                                    if (!await _checkFile(context, video.path)) return;
                                    if (!context.mounted) return;
                                    context.pushNamed('player', extra: {
                                      'videoPath': video.path,
                                      'videoTitle': video.name,
                                    });
                                  },
                                child: Row(
                                  children: [
                                    // 缩略图：与首页一致用真实封面（没有则回退图标）
                                    CoverThumb(
                                      video: video,
                                      width: 88,
                                      height: 56,
                                      radius: GlassTheme.radiusXs,
                                      iconSize: 28,
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
                                                  color: GlassTheme.textPrimary,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Icon(Icons.schedule_rounded,
                                                  size: 12,
                                                  color:
                                                      GlassTheme.textTertiary),
                                              const SizedBox(width: 4),
                                              Text(
                                                _formatDate(video.lastPlayed),
                                                style: const TextStyle(
                                                    color:
                                                        GlassTheme.textTertiary,
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
                                                color: Colors.black
                                                    .withValues(alpha: 0.06),
                                              ),
                                              child: FractionallySizedBox(
                                                alignment: Alignment.centerLeft,
                                                widthFactor: progress,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            2),
                                                    gradient:
                                                        const LinearGradient(
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
                                      onTap: () async {
                                          if (!await _checkFile(context, video.path)) return;
                                          if (!context.mounted) return;
                                          context.pushNamed('player', extra: {
                                            'videoPath': video.path,
                                            'videoTitle': video.name,
                                          });
                                        },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                      childCount: videos.length,
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
            child: Text('⚠ $e',
                style: const TextStyle(color: GlassTheme.textSecondary)),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    // 与所有 tab 页统一：同一个留白/字号规格，切 tab 不跳
    return AppPageHeader(
      title: '观看历史',
      subtitle: count > 0 ? '$count 条记录' : null,
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded,
                size: 48, color: GlassTheme.textTertiary),
            const SizedBox(height: 12),
            const Text('暂无观看记录',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
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

  /// 检查文件是否存在，不存在则弹 toast 提示并返回 false。
  static Future<bool> _checkFile(BuildContext context, String path) async {
    if (!path.startsWith('http') && !File(path).existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件已不存在，可能已被删除')),
        );
      }
      return false;
    }
    return true;
  }
}
