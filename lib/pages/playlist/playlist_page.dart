import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../providers/playlist_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';

class PlaylistPage extends ConsumerStatefulWidget {
  const PlaylistPage({super.key});

  @override
  ConsumerState<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<PlaylistPage> {
  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: playlistsAsync.when(
          data: (playlists) {
            if (playlists.isEmpty) return _buildEmpty();
            return CustomScrollView(
              slivers: [
                _buildHeader(playlists.length),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final playlist = playlists[index];
                        final firstVideo = playlist.videos.isNotEmpty
                            ? playlist.videos.first
                            : null;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassCard(
                            radius: GlassTheme.radiusMd,
                            tint: GlassTheme.tintTeal,
                            padding: const EdgeInsets.all(14),
                            onTap: () {
                              if (playlist.videos.isNotEmpty) {
                                context.pushNamed('player', extra: {
                                  'videoPath': playlist.videos.first.path,
                                  'videoTitle': playlist.videos.first.name,
                                });
                              }
                            },
                            child: Row(
                              children: [
                                // 封面占位
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                        GlassTheme.radiusSm),
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0x2245E0D0),
                                        Color(0x089B7EF0),
                                      ],
                                    ),
                                  ),
                                  child: const Icon(
                                      Icons.playlist_play_rounded,
                                      size: 30,
                                      color: GlassTheme.accentTeal),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(playlist.name,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${playlist.videos.length} 个视频${firstVideo != null ? ' · ${_fmtDuration(firstVideo.durationMs)}' : ''}',
                                        style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                GlassButton.outlined(
                                  label: '播放',
                                  height: 34,
                                  foregroundColor: GlassTheme.accentTeal,
                                  onTap: () {
                                    if (playlist.videos.isNotEmpty) {
                                      context.pushNamed('player', extra: {
                                        'videoPath':
                                            playlist.videos.first.path,
                                        'videoTitle':
                                            playlist.videos.first.name,
                                      });
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      childCount: playlists.length,
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
            const Text('播放列表',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            GlassButton.outlined(
              icon: Icons.add_rounded,
              label: '新建',
              height: 36,
              foregroundColor: GlassTheme.accentTeal,
              onTap: () {
                // TODO: 新建播放列表 dialog
              },
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
            Icon(Icons.playlist_add_rounded, size: 48, color: Colors.grey[700]),
            const SizedBox(height: 12),
            const Text('尚未创建播放列表',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            GlassButton.outlined(
              icon: Icons.add_rounded,
              label: '新建列表',
              foregroundColor: GlassTheme.accentTeal,
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDuration(int ms) {
    if (ms <= 0) return '';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    if (h > 0) return '${h}h${m}m';
    return '${m}分钟';
  }
}