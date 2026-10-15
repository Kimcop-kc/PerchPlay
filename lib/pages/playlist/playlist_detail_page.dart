import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../models/playlist_model.dart';
import '../../models/video_model.dart';
import '../../providers/library_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_button.dart';

/// 播放列表详情：先看清单（确认分类对不对），再决定播哪一集
class PlaylistDetailPage extends ConsumerWidget {
  final String playlistId;
  const PlaylistDetailPage({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistProvider).valueOrNull ??
        const <Playlist>[];
    Playlist? playlist;
    for (final p in playlists) {
      if (p.id == playlistId) {
        playlist = p;
        break;
      }
    }

    final allVideos =
        ref.watch(videoListProvider).valueOrNull ?? const <VideoModel>[];
    final byId = {for (final v in allVideos) v.id: v};
    final videos = playlist == null
        ? <VideoModel>[]
        : playlist.videoIds
            .map((id) => byId[id])
            .whereType<VideoModel>()
            .toList();

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

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            // ── 顶栏 ──
            Padding(
              padding: EdgeInsets.fromLTRB(
                  4, MediaQuery.of(context).padding.top + 4, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: GlassTheme.textPrimary),
                    onPressed: () => context.pop(),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                playlist?.name ?? '播放列表',
                                style: const TextStyle(
                                    color: GlassTheme.textPrimary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (playlist?.isAuto == true) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: GlassTheme.accentPurple
                                      .withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('自动',
                                    style: TextStyle(
                                        color: GlassTheme.accentPurple,
                                        fontSize: 10)),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          playlist?.isAuto == true
                              ? '按文件名自动分组 · ${videos.length} 个视频'
                              : '${videos.length} 个视频',
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── 播放全部 ──
            if (videos.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: GlassButton.filled(
                  icon: Icons.play_arrow_rounded,
                  label: '从头播放（${videos.length}）',
                  width: double.infinity,
                  height: 46,
                  onTap: () => playFrom(0),
                ),
              ),

            // ── 清单 ──
            Expanded(
              child: videos.isEmpty
                  ? const Center(
                      child: Text('这个列表还没有视频\n长按影库里的视频即可添加',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 13,
                              height: 1.6)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          12, 0, 12, GlassTheme.navBarOverlay),
                      itemCount: videos.length,
                      itemBuilder: (context, index) {
                        final v = videos[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GlassCard(
                            radius: GlassTheme.radiusMd,
                            tint: GlassTheme.tintWhite,
                            padding: const EdgeInsets.all(10),
                            onTap: () => playFrom(index),
                            child: Row(
                              children: [
                                // 序号
                                SizedBox(
                                  width: 26,
                                  child: Text('${index + 1}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: GlassTheme.textTertiary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                ),
                                // 缩略图
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: SizedBox(
                                    width: 76,
                                    height: 43,
                                    child: v.thumbnailPath.isNotEmpty
                                        ? Image.file(
                                            File(v.thumbnailPath),
                                            fit: BoxFit.cover,
                                            // 列表小图按显示尺寸解码，省内存
                                            cacheWidth: 200,
                                            gaplessPlayback: true,
                                            errorBuilder: (_, __, ___) =>
                                                _thumbPlaceholder(),
                                          )
                                        : _thumbPlaceholder(),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(v.name,
                                          style: const TextStyle(
                                              color: GlassTheme.textPrimary,
                                              fontSize: 14),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 2),
                                      Text(
                                        _subtitle(v),
                                        style: const TextStyle(
                                            color: GlassTheme.textTertiary,
                                            fontSize: 11),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                // 手动列表可移除
                                if (playlist?.isAuto != true)
                                  IconButton(
                                    tooltip: '从列表移除',
                                    icon: const Icon(
                                        Icons.remove_circle_outline_rounded,
                                        size: 20,
                                        color: GlassTheme.textTertiary),
                                    onPressed: () => ref
                                        .read(playlistProvider.notifier)
                                        .removeVideoFromPlaylist(
                                            playlistId, v.id),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
        color: Colors.black.withOpacity(0.08),
        child: const Center(
          child: Icon(Icons.movie_rounded,
              color: GlassTheme.textTertiary, size: 20),
        ),
      );

  String _subtitle(VideoModel v) {
    final parts = <String>[];
    if (v.durationMs > 0) parts.add(_fmtDuration(v.durationMs));
    if (v.size > 0) parts.add(_fmtSize(v.size));
    if (v.lastPosition > 1000) {
      parts.add('上次看到 ${_fmtDuration(v.lastPosition.round())}');
    }
    return parts.isEmpty ? v.path.split('/').last : parts.join(' · ');
  }

  String _fmtDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
