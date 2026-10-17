import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/adaptive_scaffold.dart';
import '../../models/video_model.dart';
import '../../models/playlist_model.dart';
import '../../providers/library_provider.dart';
import '../../providers/permission_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/scrape_provider.dart';
import '../../services/app_settings_service.dart';
import '../../services/library_query_service.dart';
import '../../services/media_namer_service.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/scrape/scrape_widgets.dart';

class HomePage extends StatelessWidget {
  final Widget child;
  const HomePage({super.key, required this.child});

  /// 标签页切换：新旧页面真正交叉淡化（旧页淡出与新页淡入同时进行），
  /// 曲线/时长完全一致，衔接不突兀。导航栏不在切换范围内，保持静止。
  static const _switchDuration = Duration(milliseconds: 280);
  static const _switchCurve = Curves.easeInOutCubic;

  @override
  Widget build(BuildContext context) {
    // 从路由取当前路径，驱动玻璃导航栏的选中态
    final location = GoRouterState.of(context).uri.path;
    return AdaptiveScaffold(
      currentRoute: location,
      child: AnimatedSwitcher(
        duration: _switchDuration,
        switchInCurve: _switchCurve,
        switchOutCurve: _switchCurve,
        // 旧页与新页叠放，形成真正的交叉淡化（默认布局会把旧页移出）
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        ),
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.012),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey(location),
          child: RepaintBoundary(child: child),
        ),
      ),
    );
  }
}

class LibraryView extends ConsumerStatefulWidget {
  const LibraryView({super.key});

  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _listAnimController;

  /// 搜索词（临时，不持久化）
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// 排序 / 筛选（持久化，下次进入保持）
  LibrarySort _sort = LibrarySort.name;
  LibraryFilter _filter = LibraryFilter.all;

  @override
  void initState() {
    super.initState();
    // 排序/筛选从设置读回来，避免每次进来都要重选
    _sort = LibrarySort.fromId(AppSettingsService.instance.librarySort);
    _filter = LibraryFilter.fromId(AppSettingsService.instance.libraryFilter);
    _listAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    WidgetsBinding.instance.addObserver(this);
    // 入场动画只在初始化时触发一次（之前写在 build 里，
    // 每次重建都会注册一个 postFrame 回调）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initLibrary();
      if (!_listAnimController.isCompleted) {
        _listAnimController.forward();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从「所有文件访问」设置页返回时刷新权限并重新扫描
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    }
  }

  Future<void> _onResumed() async {
    if (!mounted) return;
    final notifier = ref.read(permissionProvider.notifier);
    final before = ref.read(permissionProvider).hasAllFilesAccess;
    await notifier.refreshAllFilesAccess();
    final after = ref.read(permissionProvider).hasAllFilesAccess;
    if (!before && after) {
      // 刚授予「所有文件访问」→ 立刻重扫
      await ref.read(libraryProvider.notifier).scan();
    }
    // 文件在别的 App / 文件管理器里被删掉后，回前台必须把它从影库里摘掉，
    // 否则首页永远显示一张点不开的卡片。
    // 只做 existsSync 的轻量检查（不重扫）；剔除数为 0 时内部不改 state，
    // 界面不会重建。
    // 必须在「有读取权限」时才做：没权限时 existsSync 对共享存储一律返回
    // false，那样会把整个影库误判成已删除。
    if (ref.read(permissionProvider).hasVideoPermission) {
      await ref.read(libraryProvider.notifier).pruneMissingFiles();
    }
  }

  /// 启动时：检查权限 → 仅当影库为空（首次）才自动扫描，否则只加载缓存
  Future<void> _initLibrary() async {
    final permissionNotifier = ref.read(permissionProvider.notifier);
    await permissionNotifier.requestVideoPermission();
    await permissionNotifier.refreshAllFilesAccess();
    final perm = ref.read(permissionProvider);
    if (!perm.hasVideoPermission) return;

    // 首次引导「所有文件访问权限」：与其他播放器一致，直接跳到系统开关页
    if (Platform.isAndroid &&
        !perm.hasAllFilesAccess &&
        !AppSettingsService.instance.allFilesPrompted) {
      await AppSettingsService.instance.setAllFilesPrompted(true);
      await permissionNotifier.requestAllFilesAccess();
      return; // 用户授权返回后，resume 时会自动重扫
    }

    // 冷启动时初始化刮削（加载已缓存结果 + 启用）—— 必须在 scan 前，
    // 否则 scan 里触发的 scrapeBatch 会因 isEnabled=false 而跳过。
    ref.read(scrapeProvider.notifier).boot();

    // 已有缓存视频则不重复全盘扫描（避免每次进首页都扫）
    final current = ref.read(libraryProvider).valueOrNull;
    if (current == null || current.isEmpty) {
      await ref.read(libraryProvider.notifier).scan();
    } else {
      // 冷启动也当成"回到首页"：先花几毫秒把文件已经不在磁盘上的条目剔掉
      // （在手机里删了视频、冷启动又只读缓存时，这张卡片会一直挂着）。
      await ref.read(libraryProvider.notifier).pruneMissingFiles();
      // 不重扫，但刮削必须补齐。
      // 刮削原来只在 scan() 之后触发，而影库非空时冷启动不扫描 ——
      // 结果就是「刚升级 App」或「刚填好 TMDB Key」的用户，现有视频
      // 永远不会被刮削，必须手动点一次刷新才出海报，看起来像"识别不了"。
      // scrapeBatch 内部会跳过已有结果的；scrapeForVideo 也会先查本地缓存，
      // 所以这里不会产生多余的网络请求。
      // 路径要重新取一次：上面剔除了已消失的视频
      final alive =
          ref.read(libraryProvider).valueOrNull ?? const <VideoModel>[];
      ref
          .read(scrapeProvider.notifier)
          .scrapeBatch([for (final v in alive) v.path]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listAnimController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 应用搜索/排序/筛选
  List<VideoModel> _query0(List<VideoModel> videos) => LibraryQuery.apply(
        videos,
        query: _query,
        sort: _sort,
        filter: _filter,
      );

  void _setSort(LibrarySort s) {
    setState(() => _sort = s);
    AppSettingsService.instance.setLibrarySort(s.id);
  }

  void _setFilter(LibraryFilter f) {
    setState(() => _filter = f);
    AppSettingsService.instance.setLibraryFilter(f.id);
  }

  @override
  Widget build(BuildContext context) {
    final libraryAsync = ref.watch(libraryProvider);
    // 这里仍然**不** watch playerProvider：小窗挪到 AdaptiveScaffold 了，
    // 首页连"有没有小窗"都不用知道，播放位置每秒更新更不该重建这层网格。
    final columns = AppBreakpoints.gridColumns(context);
    final hp = AppBreakpoints.horizontalPadding(context);

    return libraryAsync.when(
      data: (all) {
        // 影库本身为空 vs 筛选后为空，是两种情况，不能都显示"影库为空"
        if (all.isEmpty) return _buildEmptyLibrary(context);
        final videos = _query0(all);
        return _buildMobileLayout(videos, columns, hp, totalCount: all.length);
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
      List<VideoModel> videos, int columns, double hp,
      {required int totalCount}) {
    // 小窗已经上移到 AdaptiveScaffold（所有 tab 共用），这里不再自己画一个，
    // 原来为了叠加小窗而套的 Stack 也就没用了。
    // 留白固定 96：导航栏 72 + 手势条 24；小窗占位由外壳统一补，
    // 否则首页会补两遍，切换 tab 时底部间距还会跳一下。
    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        _buildHeader(hp, totalCount: totalCount, shownCount: videos.length),
        if (videos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildNoMatch(),
          )
        else
          SliverPadding(
            // 底部预留：导航栏(72)+手势条(24)=96。
            // 小窗显示时它由 AdaptiveScaffold 额外补 72，见那边的注释
            padding: EdgeInsets.fromLTRB(hp, 8, hp, 96),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                // 横向卡片（16:9），缩略图铺满整张卡片
                childAspectRatio: 1.7,
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

  Widget _buildHeader(double hp,
      {bool compact = false, int totalCount = 0, int shownCount = 0}) {
    // 沉浸式：标题延伸到状态栏下，紧贴安全区顶部
    final topPad = MediaQuery.of(context).padding.top + (compact ? 8 : 16);
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(hp, topPad, hp, compact ? 8 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!compact) ...[
              const Text('PerchPlay',
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
                  // 有筛选/搜索时显示"命中数 / 总数"，避免误以为影库变小了
                  (shownCount > 0 && shownCount < totalCount)
                      ? '$shownCount / $totalCount 个视频'
                      : '全部视频',
                  style: TextStyle(
                    color: GlassTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 12 : 13,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                _buildSortMenu(),
                _buildFilterMenu(),
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
            const SizedBox(height: 10),
            _buildSearchField(),
          ],
        ),
      ),
    );
  }

  /// 排序菜单
  Widget _buildSortMenu() {
    return PopupMenuButton<LibrarySort>(
      tooltip: '排序',
      position: PopupMenuPosition.under,
      onSelected: _setSort,
      itemBuilder: (ctx) => [
        for (final s in LibrarySort.values)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Icon(
                  s == _sort
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: s == _sort
                      ? GlassTheme.accentPurple
                      : GlassTheme.textTertiary,
                ),
                const SizedBox(width: 8),
                Text(s.label,
                    style: TextStyle(
                        color: s == _sort
                            ? GlassTheme.accentPurple
                            : GlassTheme.textPrimary)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.swap_vert_rounded,
          size: 18,
          color: _sort == LibrarySort.name
              ? GlassTheme.textTertiary
              : GlassTheme.accentPurple,
        ),
      ),
    );
  }

  /// 筛选菜单
  Widget _buildFilterMenu() {
    return PopupMenuButton<LibraryFilter>(
      tooltip: '筛选',
      position: PopupMenuPosition.under,
      onSelected: _setFilter,
      itemBuilder: (ctx) => [
        for (final f in LibraryFilter.values)
          PopupMenuItem(
            value: f,
            child: Row(
              children: [
                Icon(
                  f == _filter
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: f == _filter
                      ? GlassTheme.accentPurple
                      : GlassTheme.textTertiary,
                ),
                const SizedBox(width: 8),
                Text(f.label,
                    style: TextStyle(
                        color: f == _filter
                            ? GlassTheme.accentPurple
                            : GlassTheme.textPrimary)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          Icons.filter_alt_rounded,
          size: 18,
          color: _filter == LibraryFilter.all
              ? GlassTheme.textTertiary
              : GlassTheme.accentPurple,
        ),
      ),
    );
  }

  /// 搜索框：按文件名 / 所在目录过滤
  Widget _buildSearchField() {
    return GlassPanel(
      radius: GlassTheme.radiusFull,
      opacity: GlassTheme.glassLight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(Icons.search_rounded,
              size: 18, color: GlassTheme.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              style: const TextStyle(
                  color: GlassTheme.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索视频名或文件夹',
                hintStyle: TextStyle(
                    color: GlassTheme.textTertiary, fontSize: 14),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                setState(() => _query = '');
              },
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.close_rounded,
                    size: 16, color: GlassTheme.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  /// 搜索/筛选后没有结果（与"影库为空"区分开）
  Widget _buildNoMatch() {
    final filtering =
        _filter != LibraryFilter.all || _query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(filtering ? Icons.search_off_rounded : Icons.movie_rounded,
              size: 44, color: GlassTheme.textTertiary),
          const SizedBox(height: 12),
          Text(
            filtering ? '没有符合条件的视频' : '这里还没有视频',
            style: const TextStyle(
                color: GlassTheme.textSecondary, fontSize: 15),
          ),
          if (filtering) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _query = '';
                  _filter = LibraryFilter.all;
                });
                AppSettingsService.instance.setLibraryFilter('all');
              },
              child: const Text('清除筛选',
                  style: TextStyle(color: GlassTheme.accentPurple)),
            ),
          ],
        ],
      ),
    );
  }

  /// 长按视频卡片：添加到播放列表 / 移除
  Future<void> _showVideoActions(VideoModel video) async {
    await showGlassSheet<void>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Text(video.name,
                style: const TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              '文件名：${video.path.split('/').last}',
              style: const TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            GlassButton.outlined(
              icon: Icons.image_search_rounded,
              label: '匹配影片信息',
              width: double.infinity,
              height: 46,
              foregroundColor: GlassTheme.accentPurple,
              onTap: () {
                Navigator.pop(ctx);
                showManualMatchSheet(
                  context,
                  ref,
                  videoPath: video.path,
                  initialQuery: MediaNamer.parse(video.path).fullTitle,
                );
              },
            ),
            const SizedBox(height: 10),
            GlassButton.outlined(
              icon: Icons.playlist_add_rounded,
              label: '添加到播放列表',
              width: double.infinity,
              height: 46,
              foregroundColor: GlassTheme.accentTeal,
              onTap: () {
                Navigator.pop(ctx);
                _showAddToPlaylist(video);
              },
            ),
            const SizedBox(height: 10),
            GlassButton.outlined(
              icon: Icons.delete_outline_rounded,
              label: '从影库移除',
              width: double.infinity,
              height: 46,
              foregroundColor: GlassTheme.accentPink,
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteVideo(video);
              },
            ),
        ],
      ),
    );
  }

  /// 选择要加入的播放列表（可现场新建）
  Future<void> _showAddToPlaylist(VideoModel video) async {
    // 快照，避免在弹窗里 watch 快速变化的 provider
    final notifier = ref.read(playlistListProvider.notifier);
    final playlists = ref.read(playlistListProvider).valueOrNull ??
        const <Playlist>[];

    await showGlassSheet<void>(
      context: context,
      maxHeightFactor: 0.7,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            const Text('添加到播放列表',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            // 新建并添加
            GlassButton.filled(
              icon: Icons.add_rounded,
              label: '新建播放列表并添加',
              width: double.infinity,
              height: 44,
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _askPlaylistName();
                if (name == null || name.trim().isEmpty) return;
                await notifier.createPlaylist(name.trim());
                final created = notifier.byName(name.trim());
                if (created != null) {
                  await notifier.addVideoToPlaylist(created.id, video.id);
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已添加到「${name.trim()}」')),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text('还没有播放列表，先新建一个',
                      style: TextStyle(
                          color: GlassTheme.textTertiary, fontSize: 13)),
                ),
              )
            else
              // 外壳已经是 SingleChildScrollView，这里的列表不能再自己滚动
              // （否则嵌套滚动 + 无界高度约束会报 RenderFlex 错误）
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: playlists.length,
                  itemBuilder: (_, i) {
                    final pl = playlists[i];
                    final added = pl.videoIds.contains(video.id);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        pl.isAuto
                            ? Icons.auto_awesome_motion_rounded
                            : Icons.playlist_play_rounded,
                        color: pl.isAuto
                            ? GlassTheme.accentPurple
                            : GlassTheme.accentTeal,
                        size: 20,
                      ),
                      title: Text(pl.name,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${pl.videoIds.length} 个视频${pl.isAuto ? ' · 自动生成' : ''}',
                        style: const TextStyle(
                            color: GlassTheme.textTertiary, fontSize: 11),
                      ),
                      trailing: added
                          ? const Icon(Icons.check_rounded,
                              color: GlassTheme.accentTeal, size: 18)
                          : const Icon(Icons.add_rounded,
                              color: GlassTheme.textTertiary, size: 18),
                      onTap: () async {
                        Navigator.pop(ctx);
                        if (added) {
                          await notifier.removeVideoFromPlaylist(
                              pl.id, video.id);
                        } else {
                          await notifier.addVideoToPlaylist(pl.id, video.id);
                        }
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(added
                                    ? '已从「${pl.name}」移除'
                                    : '已添加到「${pl.name}」')),
                          );
                        }
                      },
                    );
                  },
                ),
          ],
        ),
    );
  }

  Future<String?> _askPlaylistName() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GlassTheme.bg,
        title: const Text('新建播放列表',
            style: TextStyle(color: GlassTheme.textPrimary, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: GlassTheme.textPrimary),
          decoration: const InputDecoration(
            hintText: '列表名称',
            hintStyle: TextStyle(color: GlassTheme.textTertiary),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('创建',
                style: TextStyle(color: GlassTheme.accentTeal)),
          ),
        ],
      ),
    );
  }

  /// 本地缩略图（没有刮削海报时用）
  /// 本地缩略图占位
  ///
  /// 注意：缩略图文件是生成在系统缓存目录里的，系统清缓存后会失效，
  /// 但数据库里的路径还在。这时如果直接 Image.file，只会渲染成**一片空白**，
  /// 表现就是"没刮到海报的卡片什么都不显示"。所以这里必须：
  ///   1. 先判断文件是否真的还在
  ///   2. 给 Image.file 加 errorBuilder 兜底
  Widget _thumbPlaceholder() => Container(
        color: Colors.black.withOpacity(0.08),
        child: const Center(
          child: Icon(Icons.movie_rounded,
              color: GlassTheme.textTertiary, size: 40),
        ),
      );

  Widget _localThumb(VideoModel video) {
    final path = video.thumbnailPath;
    if (path.isEmpty || !File(path).existsSync()) {
      return _thumbPlaceholder();
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      // 明确解码尺寸：缩略图按原分辨率解码会占大量内存并掉帧
      cacheWidth: 480,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _thumbPlaceholder(),
    );
  }

  Widget _buildVideoCard(VideoModel video, int index) {
    final progressPercent = video.durationMs > 0
        ? (video.lastPosition / video.durationMs).clamp(0.0, 1.0)
        : 0.0;
    // 只订阅**这一个**视频的刮削结果：用 select 切片，
    // 否则刮削批量跑时（每秒一条）所有卡片都会跟着重建
    final scraped = ref.watch(
        scrapeProvider.select((s) => s.results[video.path]));

    return GestureDetector(
      onTap: () {
        context.pushNamed('player', extra: {
          'videoPath': video.path,
          'videoTitle': video.name,
        });
      },
      onLongPress: () => _showVideoActions(video),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GlassTheme.radiusLg),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 缩略图铺满整张卡片 ──
            // 有刮削海报时优先用海报（这是刮削结果唯一的可见出口，
            // 之前刮到的 posterPath 没有任何界面使用）
            if (scraped?.posterUrl != null)
              ScrapedPoster(
                url: scraped!.posterUrl!,
                fit: BoxFit.cover,
                fallback: _localThumb(video),
              )
            else
              _localThumb(video),

            // 播放按钮（居中）
            Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.35),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.7),
                    width: 1.5,
                  ),
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 26),
              ),
            ),

            // 右上角删除按钮
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () => _confirmDeleteVideo(video),
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.4),
                  ),
                  child: const Icon(
                    Icons.delete_outline_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),

            // ── 底部渐变遮罩 + 标题 + 时长 ──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 24, 10, 8),
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(GlassTheme.radiusLg)),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.75),
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      video.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDuration(video.durationMs),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 底部进度条（静态，避免 LinearProgressIndicator 动画在 S/W 渲染崩溃）
            if (progressPercent > 0 && progressPercent < 1)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(GlassTheme.radiusLg)),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: progressPercent,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: GlassTheme.accentPurple,
                        borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(GlassTheme.radiusLg)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 确认删除影库记录（不删磁盘文件）
  Future<void> _confirmDeleteVideo(VideoModel video) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF2F2F7),
        title: const Text('移除视频',
            style: TextStyle(color: GlassTheme.textPrimary, fontSize: 17)),
        content: Text(
          '从影库移除「${video.name}」？\n（不会删除手机里的文件）',
          style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: GlassTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除',
                style: TextStyle(color: GlassTheme.accentPink)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(libraryProvider.notifier).deleteVideo(video.id);
    }
  }

  Widget _buildEmptyLibrary(BuildContext context) {
    final hasPermission = ref.watch(permissionProvider).hasVideoPermission;
    final hasAllFiles = ref.watch(permissionProvider).hasAllFilesAccess;
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
            // 「所有文件访问权限」入口（未授权时显示，扫描才能扫全）
            if (!hasAllFiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Semantics(
                  button: true,
                  label: '开启所有文件访问权限',
                  child: GlassButton.outlined(
                    icon: Icons.admin_panel_settings_rounded,
                    label: '开启所有文件访问权限',
                    width: double.infinity,
                    height: 48,
                    foregroundColor: GlassTheme.accentTeal,
                    onTap: () async {
                      await ref
                          .read(permissionProvider.notifier)
                          .requestAllFilesAccess();
                    },
                  ),
                ),
              ),
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

}
