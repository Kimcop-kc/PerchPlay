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
        top: false,
        // 不再预留底部安全区：让内容像首页那样一直铺到屏幕底，
        // 否则导航栏下方会留出一条空白（首页没有这层）
        bottom: false,
        child: playlistsAsync.when(
          data: (playlists) {
            if (playlists.isEmpty) return _buildEmpty();
            return CustomScrollView(
              slivers: [
                _buildHeader(playlists.length),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                      12, 0, 12, GlassTheme.navBarOverlay),
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

                        // 带队列播放：整张列表按顺序连播
                        void playFrom(int index) {
                          if (videos.isEmpty) return;
                          final start = index.clamp(0, videos.length - 1);
                          context.pushNamed('player', extra: {
                            'videoPath': videos[start].path,
                            'videoTitle': videos[start].name,
                            'queueIds': videos.map((v) => v.id).toList(),
                            'startIndex': start,
                          });
                        }

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassCard(
                            radius: GlassTheme.radiusMd,
                            tint: GlassTheme.tintTeal,
                            padding: const EdgeInsets.all(14),
                            onTap: () => playFrom(0),
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
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(playlist.name,
                                                style: const TextStyle(
                                                    color:
                                                        GlassTheme.textPrimary,
                                                    fontSize: 16,
                                                    fontWeight:
                                                        FontWeight.w700),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis),
                                          ),
                                          if (playlist.isAuto) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 1),
                                              decoration: BoxDecoration(
                                                color: GlassTheme.accentPurple
                                                    .withOpacity(0.12),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: const Text('自动',
                                                  style: TextStyle(
                                                      color: GlassTheme
                                                          .accentPurple,
                                                      fontSize: 10)),
                                            ),
                                          ],
                                        ],
                                      ),
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
                                  onTap: () => playFrom(0),
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
    final topPad = MediaQuery.of(context).padding.top + 24;
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, topPad, 20, 16),
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
            Icon(Icons.playlist_add_rounded,
                size: 48, color: GlassTheme.textTertiary),
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
