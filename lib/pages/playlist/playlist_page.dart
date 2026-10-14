import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../models/video_model.dart';
import '../../providers/library_provider.dart';
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
    // Playlist 只保存 videoIds，这里按 id 关联回视频实体
    final videosById = <String, VideoModel>{
      for (final video
          in ref.watch(videoListProvider).valueOrNull ?? const <VideoModel>[])
        video.id: video,
    };

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
                        final videos = playlist.videoIds
                            .map((id) => videosById[id])
                            .whereType<VideoModel>()
                            .toList();
                        final firstVideo = videos.isNotEmpty
                            ? videos.first
                            : null;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassCard(
                            radius: GlassTheme.radiusMd,
                            tint: GlassTheme.tintTeal,
                            padding: const EdgeInsets.all(14),
                            onTap: () {
                              if (videos.isNotEmpty) {
                                context.pushNamed('player', extra: {
                                  'videoPath': videos.first.path,
                                  'videoTitle': videos.first.name,
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
                                              color: GlassTheme.textPrimary,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${videos.length} 个视频${firstVideo != null ? ' · ${_fmtDuration(firstVideo.durationMs)}' : ''}',
                                        style: const TextStyle(
                                            color: GlassTheme.textTertiary,
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
                                    if (videos.isNotEmpty) {
                                      context.pushNamed('player', extra: {
                                        'videoPath': videos.first.path,
                                        'videoTitle': videos.first.name,
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
            child: Text('⚠ $e', style: const TextStyle(color: GlassTheme.textSecondary)),
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
                    color: GlassTheme.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            GlassButton.outlined(
              icon: Icons.add_rounded,
              label: '新建',
              height: 36,
              foregroundColor: GlassTheme.accentTeal,
              onTap: () => _showCreatePlaylistDialog(),
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
            Icon(Icons.playlist_add_rounded, size: 48, color: GlassTheme.textTertiary),
            const SizedBox(height: 12),
            const Text('尚未创建播放列表',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            GlassButton.outlined(
              icon: Icons.add_rounded,
              label: '新建列表',
              foregroundColor: GlassTheme.accentTeal,
              onTap: () => _showCreatePlaylistDialog(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF2F2F7),
        title: const Text('新建播放列表',
            style: TextStyle(color: GlassTheme.textPrimary, fontSize: 18)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: GlassTheme.textPrimary),
          decoration: InputDecoration(
            hintText: '输入列表名称',
            hintStyle: TextStyle(color: GlassTheme.textTertiary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.black.withOpacity(0.2)),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: GlassTheme.accentTeal),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: GlassTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建',
                style: TextStyle(color: GlassTheme.accentTeal)),
          ),
        ],
      ),
    );

    controller.dispose();

    if (name != null && name.isNotEmpty && mounted) {
      await ref.read(playlistProvider.notifier).createPlaylist(name);
    }
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
