import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/glass_theme.dart';
import '../../models/playlist_model.dart';
import '../../models/video_model.dart';
import '../../providers/library_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../services/app_settings_service.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/common/app_page_header.dart';
import '../../widgets/video/cover_thumb.dart';

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
                  // 与 header 一致用自适应水平 padding，平板限宽居中
                  padding: EdgeInsets.fromLTRB(
                      AppBreakpoints.horizontalPadding(context),
                      0,
                      AppBreakpoints.horizontalPadding(context),
                      GlassTheme.navBarOverlay),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final playlist = playlists[index];
                        final videos = playlist.videoIds
                            .map((id) => videosById[id])
                            .whereType<VideoModel>()
                            .toList();
                        final firstVideo =
                            videos.isNotEmpty ? videos.first : null;

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
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 720),
                              child: GlassCard(
                                radius: GlassTheme.radiusMd,
                                tint: GlassTheme.tintTeal,
                                padding: const EdgeInsets.all(14),
                                // 点卡片进详情看清单（防止自动分类出错）
                                onTap: () => context.pushNamed(
                                  'playlistDetail',
                                  pathParameters: {'id': playlist.id},
                                ),
                                child: Row(
                                  children: [
                                    // 封面：取该列表第一个视频的海报/缩略图；
                                    // 空列表保留原来的渐变图标占位
                                    if (firstVideo != null)
                                      CoverThumb(
                                        video: firstVideo,
                                        width: 64,
                                        height: 64,
                                        radius: GlassTheme.radiusSm,
                                        iconSize: 30,
                                      )
                                    else
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
                                                        color: GlassTheme
                                                            .textPrimary,
                                                        fontSize: 16,
                                                        fontWeight:
                                                            FontWeight.w700),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis),
                                              ),
                                              if (playlist.isAuto) ...[
                                                const SizedBox(width: 6),
                                                _autoBadge(playlist),
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
                                    const SizedBox(width: 4),
                                    // 删除入口：以前这里没有删除按钮，
                                    // 自动列表就算删了下次扫描也会重建
                                    IconButton(
                                      tooltip: '删除列表',
                                      iconSize: 20,
                                      visualDensity: VisualDensity.compact,
                                      color: GlassTheme.textTertiary,
                                      icon: const Icon(
                                          Icons.delete_outline_rounded),
                                      onPressed: () => _confirmDelete(playlist),
                                    ),
                                  ],
                                ),
                              ),
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
            child: Text('⚠ $e',
                style: const TextStyle(color: GlassTheme.textSecondary)),
          ),
        ),
      ),
    );
  }

  /// 删除列表（自动列表会记住删除意图，不再自动重建）
  Future<void> _confirmDelete(Playlist playlist) async {
    final isAuto = playlist.isAuto;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GlassTheme.surfaceWhite,
        title: Text('删除「${playlist.name}」',
            style:
                const TextStyle(color: GlassTheme.textPrimary, fontSize: 17)),
        content: Text(
          isAuto
              ? '这是自动生成的列表。删除后不会再自动重建，'
                  '随时可以用标题栏的「恢复自动列表」找回。\n列表里的视频文件不会被删除。'
              : '只会删除这个列表，里面的视频文件不会被删除。',
          style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除',
                style: TextStyle(color: GlassTheme.accentPink)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(playlistProvider.notifier).deletePlaylist(playlist.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            isAuto ? '已删除自动列表「${playlist.name}」' : '已删除「${playlist.name}」'),
        action: isAuto
            ? SnackBarAction(
                label: '恢复',
                onPressed: () => ref
                    .read(playlistProvider.notifier)
                    .restoreAutoPlaylists(
                        ref.read(videoListProvider).valueOrNull ??
                            const <VideoModel>[]),
              )
            : null,
      ),
    );
  }

  Widget _buildHeader(int count) {
    // 有被删掉的自动列表时给出恢复入口（否则用户会以为功能坏了）
    final canRestore =
        AppSettingsService.instance.hiddenAutoPlaylists.isNotEmpty;
    // 与大标题同排的按钮用紧凑尺寸，避免把 36px 标题行撑高
    return AppPageHeader(
      title: '播放列表',
      subtitle: count > 0 ? '$count 个列表' : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canRestore) ...[
            GlassButton.outlined(
              icon: Icons.restore_rounded,
              label: '恢复自动列表',
              height: 36,
              foregroundColor: GlassTheme.textSecondary,
              onTap: () => ref
                  .read(playlistProvider.notifier)
                  .restoreAutoPlaylists(
                      ref.read(videoListProvider).valueOrNull ??
                          const <VideoModel>[]),
            ),
            const SizedBox(width: 8),
          ],
          GlassButton.outlined(
            icon: Icons.add_rounded,
            label: '新建',
            height: 36,
            foregroundColor: GlassTheme.accentTeal,
            onTap: () => _showCreatePlaylistDialog(),
          ),
        ],
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
      // 小屏 / 键盘弹出时避免内容被顶出屏幕（默认 insetPadding 40 太宽）
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF2F2F7),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        title: const Text('新建播放列表',
            style: TextStyle(color: GlassTheme.textPrimary, fontSize: 18)),
        content: SingleChildScrollView(
          child: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: GlassTheme.textPrimary),
            decoration: InputDecoration(
              hintText: '输入列表名称',
              hintStyle: TextStyle(color: GlassTheme.textTertiary),
              enabledBorder: UnderlineInputBorder(
                borderSide:
                    BorderSide(color: Colors.black.withValues(alpha: 0.2)),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: GlassTheme.accentTeal),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textSecondary)),
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

  /// 自动列表的类型标签
  Widget _autoBadge(Playlist list) {
    if (list.id.startsWith('auto:series:')) {
      return _badge('影视', GlassTheme.accentPurple);
    }
    if (list.id.startsWith('auto:movie:')) {
      return _badge('电影', GlassTheme.accentPurple);
    }
    if (list.id.startsWith('auto:fallback:')) {
      return _badge('分组', const Color(0xFFF0A500));
    }
    // personal → 来源 emoji + 绿色小标
    final emoji = _extractEmoji(list.name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: GlassTheme.accentTeal.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (emoji.isNotEmpty)
            Text(emoji, style: const TextStyle(fontSize: 10)),
          if (emoji.isNotEmpty) const SizedBox(width: 2),
          const Text('个人',
              style: TextStyle(color: GlassTheme.accentTeal, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 10)),
    );
  }

  /// 从字符串开头取一个绘文字/图标（📷、✂️ 等）
  String _extractEmoji(String s) {
    if (s.isEmpty) return '';
    final runes = s.runes.toList();
    final first = runes.first;
    // 常见 emoji 范围（大致覆盖）
    if ((first >= 0x1F300 && first <= 0x1F9FF) ||
        (first >= 0x2600 && first <= 0x27BF) ||
        (first >= 0x2702 && first <= 0x27B0) ||
        (first >= 0x1FA00 && first <= 0x1FA6F) ||
        (first >= 0x1F600 && first <= 0x1F64F) ||
        (first >= 0x1F680 && first <= 0x1F6FF) ||
        (first >= 0x231A && first <= 0x23FF)) {
      return String.fromCharCode(first);
    }
    return '';
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
