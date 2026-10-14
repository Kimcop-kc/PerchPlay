import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/adaptive_scaffold.dart';
import '../../models/video_model.dart';
import '../../providers/library_provider.dart';
import '../../providers/permission_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_slider.dart';

class HomePage extends StatelessWidget {
  final Widget child;
  const HomePage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // 从路由取当前路径，驱动玻璃导航栏的选中态
    final location = GoRouterState.of(context).uri.path;
    return AdaptiveScaffold(
      currentRoute: location,
      child: child,
    );
  }
}

class LibraryView extends ConsumerStatefulWidget {
  const LibraryView({super.key});

  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView>
    with SingleTickerProviderStateMixin {
  late AnimationController _listAnimController;
  VideoModel? _selectedVideo;

  @override
  void initState() {
    super.initState();
    _listAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // 延迟到首帧后初始化，避免 provider 在 build 周期内被修改（Riverpod 禁止）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initLibrary();
    });
  }

  /// 启动时：检查权限 → 已授权则自动扫描，否则提示授权
  Future<void> _initLibrary() async {
    final permissionNotifier = ref.read(permissionProvider.notifier);
    await permissionNotifier.requestVideoPermission();
    final hasPermission = ref.read(permissionProvider).hasVideoPermission;
    if (hasPermission) {
      await ref.read(libraryProvider.notifier).scan();
    }
  }

  @override
  void dispose() {
    _listAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraryAsync = ref.watch(libraryProvider);
    final isLarge = AppBreakpoints.isLargeScreen(context);
    final columns = AppBreakpoints.gridColumns(context);
    final hp = AppBreakpoints.horizontalPadding(context);

    return libraryAsync.when(
      data: (videos) {
        if (videos.isEmpty) return _buildEmptyLibrary(context);

        // 触发入场动画
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_listAnimController.isCompleted) {
            _listAnimController.forward();
          }
        });

        if (isLarge) {
          return _buildTabletLayout(videos, columns, hp);
        }
        return _buildMobileLayout(videos, columns, hp);
      },
      loading: () => const Center(
        child: CircularProgressIndicator(color: GlassTheme.accentPurple),
      ),
      error: (e, _) => Center(
        child: Text('⚠ $e', style: const TextStyle(color: GlassTheme.textSecondary)),
      ),
    );
  }

  Widget _buildMobileLayout(
      List<VideoModel> videos, int columns, double hp) {
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        _buildHeader(hp),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 24),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.62,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => GlassAnimations.scaleIn(
                controller: _listAnimController,
                index: index,
                child: _buildVideoCard(videos[index], index),
              ),
              childCount: videos.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabletLayout(
      List<VideoModel> videos, int columns, double hp) {
    return Row(
      children: [
        // 左侧网格
        SizedBox(
          width: 420,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              _buildHeader(hp, compact: true),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(hp, 8, hp, 24),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns - 1,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.62,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => GlassAnimations.scaleIn(
                      controller: _listAnimController,
                      index: index,
                      child: _buildVideoCard(videos[index], index,
                          showSelect: true),
                    ),
                    childCount: videos.length,
                  ),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 0.5, color: Color(0x14000000)),
        // 右侧详情
        Expanded(
          child: _selectedVideo != null
              ? _buildVideoDetail(_selectedVideo!)
              : _buildSelectPrompt(),
        ),
      ],
    );
  }

  Widget _buildHeader(double hp, {bool compact = false}) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(hp, 24, hp, compact ? 8 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!compact) ...[
              const Text('VidFlow',
                  style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    height: 1.1,
                  )),
              const SizedBox(height: 4),
              Text(
                '你的本地影库',
                style: TextStyle(
                  color: GlassTheme.accentPurple.withOpacity(0.6),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 18),
            ],
            Row(
              children: [
                Icon(Icons.movie_rounded,
                    size: compact ? 16 : 18, color: GlassTheme.textTertiary),
                const SizedBox(width: 6),
                Text(
                  '全部视频',
                  style: TextStyle(
                    color: GlassTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 12 : 13,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  color: GlassTheme.textTertiary,
                  onPressed: () async {
                    final notifier = ref.read(permissionProvider.notifier);
                    await notifier.requestVideoPermission();
                    if (ref.read(permissionProvider).hasVideoPermission) {
                      await ref.read(libraryProvider.notifier).scan();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCard(VideoModel video, int index,
      {bool showSelect = false}) {
    final isSelected = _selectedVideo?.id == video.id;
    final progressPercent = video.durationMs > 0
        ? (video.lastPosition / video.durationMs).clamp(0.0, 1.0)
        : 0.0;

    return GlassCard(
      radius: GlassTheme.radiusLg,
      padding: const EdgeInsets.all(10),
      enableHover: true,
      selected: isSelected,
      tint: GlassTheme.tintPurple,
      onTap: () {
        if (showSelect) {
          setState(() => _selectedVideo = video);
        } else {
          context.pushNamed('player', extra: {
            'videoPath': video.path,
            'videoTitle': video.name,
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 缩略图区
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                  child: video.thumbnailPath.isNotEmpty
                      ? Image.file(
                          File(video.thumbnailPath),
                          fit: BoxFit.cover,
                        )
                      : Container(
                          color: Colors.black.withOpacity(0.05),
                          child: Icon(Icons.movie_rounded,
                              color: GlassTheme.textTertiary, size: 32),
                        ),
                ),
                // 渐变遮罩
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 36,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(GlassTheme.radiusSm)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.5),
                        ],
                      ),
                    ),
                  ),
                ),
                // 播放按钮
                Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.25),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 22),
                  ),
                ),
                // 进度条
                if (progressPercent > 0 && progressPercent < 1)
                  Positioned(
                    bottom: 6,
                    left: 8,
                    right: 8,
                    child: GlassSlider(
                      value: progressPercent,
                      height: 3,
                      activeColor: GlassTheme.accentPurple,
                      showThumb: false,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 标题
          Text(
            video.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _formatDuration(video.durationMs),
            style: TextStyle(
              color: GlassTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  // ── 右侧详情 ──

  Widget _buildVideoDetail(VideoModel video) {
    final progressPercent = video.durationMs > 0
        ? video.lastPosition / video.durationMs
        : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 海报
          GlassCard(
            radius: GlassTheme.radiusXl,
            padding: EdgeInsets.zero,
            height: 280,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (video.thumbnailPath.isNotEmpty)
                  ClipRRect(
                    borderRadius:
                        BorderRadius.circular(GlassTheme.radiusXl),
                    child: Image.file(File(video.thumbnailPath),
                        fit: BoxFit.cover),
                  )
                else
                  Center(
                    child: Icon(Icons.movie_rounded,
                        size: 64, color: GlassTheme.textTertiary),
                  ),
                Positioned(
                  bottom: 20,
                  left: 20,
                  right: 20,
                  child: GlassButton.filled(
                    icon: Icons.play_arrow_rounded,
                    label: '播放',
                    width: double.infinity,
                    onTap: () => context.pushNamed('player', extra: {
                      'videoPath': video.path,
                      'videoTitle': video.name,
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(video.name,
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: GlassTheme.textPrimary)),
          const SizedBox(height: 8),
          Text(video.folderPath,
              style: TextStyle(color: GlassTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 20),
          // 元数据标签
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metadataChip(Icons.schedule_rounded,
                  _formatDuration(video.durationMs)),
              _metadataChip(Icons.storage_rounded, _formatSize(video.size)),
              _metadataChip(Icons.calendar_today_rounded,
                  _formatDate(video.dateModified)),
              if (video.playCount > 0)
                _metadataChip(
                    Icons.replay_rounded, '播放 ${video.playCount} 次'),
            ],
          ),
          const SizedBox(height: 20),
          // 进度
          if (progressPercent > 0) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('观看进度',
                    style: TextStyle(color: GlassTheme.textSecondary, fontSize: 13)),
                Text('${(progressPercent * 100).round()}%',
                    style: const TextStyle(
                        color: GlassTheme.accentPurple,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            GlassSlider(
              value: progressPercent,
              height: 5,
              activeColor: GlassTheme.accentPurple,
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectPrompt() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_rounded, size: 48, color: GlassTheme.textTertiary),
          const SizedBox(height: 12),
          Text('点击左侧视频查看详情',
              style: TextStyle(color: GlassTheme.textSecondary, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildEmptyLibrary(BuildContext context) {
    final hasPermission = ref.watch(permissionProvider).hasVideoPermission;
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_rounded,
                size: 56, color: GlassTheme.textTertiary),
            const SizedBox(height: 16),
            const Text('影库为空',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              hasPermission
                  ? '未扫描到视频\n点击下方按钮重新扫描'
                  : '需要授权读取本地视频\n授权后自动扫描',
              textAlign: TextAlign.center,
              style: TextStyle(color: GlassTheme.textSecondary, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 24),
            // 授权 / 扫描入口（主操作）
            Semantics(
              button: true,
              label: hasPermission ? '扫描视频' : '授权并扫描',
              child: GlassButton.filled(
                icon: hasPermission ? Icons.search_rounded : Icons.lock_open_rounded,
                label: hasPermission ? '扫描视频' : '授权并扫描',
                width: double.infinity,
                height: 48,
                onTap: () async {
                  final notifier = ref.read(permissionProvider.notifier);
                  if (!hasPermission) {
                    await notifier.requestVideoPermission();
                  }
                  if (ref.read(permissionProvider).hasVideoPermission) {
                    await ref.read(libraryProvider.notifier).scan();
                  }
                },
              ),
            ),
            const SizedBox(height: 12),
            // 本地文件夹入口
            Semantics(
              button: true,
              label: '浏览本地文件夹',
              child: GlassButton.outlined(
                icon: Icons.folder_rounded,
                label: '浏览本地文件夹',
                width: double.infinity,
                height: 48,
                foregroundColor: GlassTheme.accentPurple,
                onTap: () => context.pushNamed('folders'),
              ),
            ),
            const SizedBox(height: 12),
            // NAS 入口
            Semantics(
              button: true,
              label: '浏览 NAS',
              child: GlassButton.outlined(
                icon: Icons.dns_rounded,
                label: '浏览 NAS',
                width: double.infinity,
                height: 48,
                foregroundColor: GlassTheme.accentTeal,
                onTap: () => context.pushNamed('nas'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataChip(IconData icon, String label) {
    return GlassPanel(
      radius: GlassTheme.radiusXs,
      opacity: GlassTheme.glassLight,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: GlassTheme.textTertiary),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  color: GlassTheme.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '--';
    final totalSec = ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '${h}h${m.toString().padLeft(2, '0')}m';
    }
    return '${m}m${s.toString().padLeft(2, '0')}s';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
