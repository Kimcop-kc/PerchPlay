import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/constants/app_constants.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';

class FolderBrowserPage extends StatefulWidget {
  /// 切回「全部视频」视图的回调（由首页传入，用于点击胶囊切换器时切回）。
  final VoidCallback? onSwitchToVideos;
  const FolderBrowserPage({super.key, this.onSwitchToVideos});

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  String _currentPath = '';
  String _rootPath = '';
  List<FileSystemEntity> _entries = [];
  bool _loading = true;
  bool _gridView = true;
  String? _errorMessage;

  /// 搜索词（文件名模糊匹配，临时不持久化）
  String _query = '';

  /// 搜索输入框控制器。
  ///
  /// 必须有：否则点「清除」按钮只把 _query 置空，输入框里的文字仍留在屏幕上
  /// （TextField 没有 controller 时无法被外部清空）。
  final _searchController = TextEditingController();

  /// 排序：name / time / size
  String _sortBy = 'name';

  /// 筛选：all / dir / video
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRoots() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      // 直接进入内部存储根，列出其下的真实文件夹/文件，
      // 不再展示「0 / sdcard」这类无意义的存储根节点。
      final storage = Directory('/storage/emulated/0');
      if (await storage.exists()) {
        _rootPath = '/storage/emulated/0';
      } else {
        final sdcard = Directory('/sdcard');
        _rootPath = await sdcard.exists() ? '/sdcard' : '';
      }

      if (_rootPath.isEmpty) {
        if (!mounted) return;
        setState(() {
          _entries = const [];
          _currentPath = '';
          _loading = false;
        });
        return;
      }

      await _navigate(_rootPath);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '无法加载存储目录：$e';
      });
    }
  }

  Future<void> _navigate(String path) async {
    // 进入新目录时清空搜索词 —— 否则会带着上一个目录的过滤条件，
    // 新目录里的文件被"搜掉"，看起来像目录是空的。
    _searchController.clear();
    setState(() {
      _query = '';
      _loading = true;
      _errorMessage = null;
    });
    try {
      final dir = Directory(path);
      _entries = await dir.list().toList();
      _entries.sort((a, b) {
        final aDir = a is Directory ? 0 : 1;
        final bDir = b is Directory ? 0 : 1;
        if (aDir != bDir) return aDir - bDir;
        return a.path.compareTo(b.path);
      });
      if (!mounted) return;
      setState(() {
        _currentPath = path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '无法访问该目录：$e';
      });
    }
  }

  Future<void> _requestStoragePermission() async {
    // Android 13+ 用 videos，≤12 用 storage
    final status = await Permission.videos.request();
    final granted = status.isGranted || status.isLimited;
    if (granted) {
      if (!mounted) return;
      setState(() => _errorMessage = null);
      await _loadRoots();
      return;
    }
    // 回退旧权限
    final legacy = await Permission.storage.request();
    if (legacy.isGranted || legacy.isLimited) {
      if (!mounted) return;
      setState(() => _errorMessage = null);
      await _loadRoots();
    } else if (mounted) {
      setState(() => _errorMessage = '未获得存储权限，请到系统设置中开启');
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final parent = Directory(_currentPath).parent.path;
    // 已在存储根：刷新根目录（不显示更高层的系统目录）
    if (_currentPath == _rootPath ||
        parent == _currentPath ||
        !parent.startsWith(_rootPath)) {
      _navigate(_rootPath);
    } else {
      _navigate(parent);
    }
  }

  /// 应用搜索 + 筛选 + 排序后的条目列表。
  List<FileSystemEntity> get _filteredEntries {
    var list = _entries;
    // 搜索：按文件名模糊匹配
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      list = list.where((e) {
        final name = e.path.split('/').last.toLowerCase();
        return name.contains(q);
      }).toList();
    }
    // 筛选
    if (_filter == 'dir') {
      list = list.where((e) => e is Directory).toList();
    } else if (_filter == 'video') {
      list = list.where((e) => e is File && _isVideoFile(e.path)).toList();
    }
    // 排序
    list = List<FileSystemEntity>.from(list);
    list.sort((a, b) {
      switch (_sortBy) {
        case 'time':
          final at = _statMs(a);
          final bt = _statMs(b);
          return bt.compareTo(at);
        case 'size':
          final as = a is File ? a.lengthSync() : 0;
          final bs = b is File ? b.lengthSync() : 0;
          return bs.compareTo(as);
        case 'name':
        default:
          final aDir = a is Directory ? 0 : 1;
          final bDir = b is Directory ? 0 : 1;
          if (aDir != bDir) return aDir - bDir;
          return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      }
    });
    return list;
  }

  static int _statMs(FileSystemEntity e) {
    try {
      return e.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        // 与首页一致：内容铺到屏幕底，避免导航栏下方出现空白层
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    // 与「全部视频」页完全一致的头部结构：
    // 透明背景（不用 GlassPanel 实心面板）+ 同样的左右留白 + 同样的标题区，
    // 这样在首页切换视图时布局不会跳变。
    final hp = AppBreakpoints.horizontalPadding(context);
    final topPad = MediaQuery.of(context).padding.top + 16;

    return Padding(
      padding: EdgeInsets.fromLTRB(hp, topPad, hp, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与首页一致的大标题区（不随视图切换而消失，视觉才连续）
          const Text(
            'PerchPlay',
            style: TextStyle(
              color: GlassTheme.textPrimary,
              fontSize: 36,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
              height: 1.1,
            ),
          ),
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
          // 第一行：切换器 +（返回）+ 右侧视图切换。
          // 结构与「全部视频」页保持一致：左侧切换器，中间 Spacer 撑开，
          // 右侧操作按钮。不再显示「内部存储」这类冗余路径文字。
          Row(
            children: [
              _buildViewSwitcher(),
              if (_currentPath.isNotEmpty && _currentPath != _rootPath) ...[
                const SizedBox(width: 8),
                GlassButton(
                  icon: Icons.arrow_back_rounded,
                  compact: true,
                  ghost: true,
                  foregroundColor: GlassTheme.textSecondary,
                  onTap: _navigateUp,
                ),
              ],
              const Spacer(),
              GlassButton(
                icon: _gridView
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
                compact: true,
                ghost: true,
                foregroundColor: GlassTheme.textSecondary,
                onTap: () => setState(() => _gridView = !_gridView),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 第二行：搜索框独占一行（与首页完全一致）
          _buildSearchField(),
          const SizedBox(height: 6),
          // 第三行：排序 / 筛选 / 刷新右对齐（与首页一致）
          Row(
            children: [
              const Spacer(),
              _buildSortMenu(),
              _buildFilterMenu(),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                color: GlassTheme.textTertiary,
                tooltip: '刷新',
                onPressed: () => _navigate(_currentPath.isNotEmpty
                    ? _currentPath
                    : _rootPath),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 与首页一致的「全部视频 / 文件夹」胶囊分段切换器。
  /// 「全部视频」触发 [FolderBrowserPage.onSwitchToVideos] 回调切回首页视图。
  Widget _buildViewSwitcher() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
        border: Border.all(
          color: Colors.white.withOpacity(0.08),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segmentItem(
            selected: false,
            icon: Icons.movie_rounded,
            label: '全部视频',
            onTap: () {
              if (widget.onSwitchToVideos != null) {
                widget.onSwitchToVideos!();
              }
            },
          ),
          _segmentItem(
            selected: true,
            icon: Icons.folder_rounded,
            label: '文件夹',
            onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _segmentItem({
    required bool selected,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? GlassTheme.accentPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(GlassTheme.radiusFull),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.white : GlassTheme.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : GlassTheme.textSecondary,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索框：与「全部视频」页**完全一致**的实现
  /// （GlassPanel + radiusFull 玻璃胶囊 + 同字号/图标/左内边距 + 清除按钮）。
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
                hintText: '搜索文件名',
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

  Widget _buildSortMenu() {
    return PopupMenuButton<String>(
      tooltip: '排序',
      icon: const Icon(Icons.sort_rounded,
          size: 18, color: GlassTheme.textTertiary),
      onSelected: (v) => setState(() => _sortBy = v),
      itemBuilder: (ctx) => [
        _sortItem('name', '名称'),
        _sortItem('time', '最近修改'),
        _sortItem('size', '文件大小'),
      ],
    );
  }

  PopupMenuItem<String> _sortItem(String value, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(
            _sortBy == value
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: _sortBy == value
                ? GlassTheme.accentPurple
                : GlassTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildFilterMenu() {
    return PopupMenuButton<String>(
      tooltip: '筛选',
      icon: const Icon(Icons.filter_list_rounded,
          size: 18, color: GlassTheme.textTertiary),
      onSelected: (v) => setState(() => _filter = v),
      itemBuilder: (ctx) => [
        _filterItem('all', '全部'),
        _filterItem('dir', '只看文件夹'),
        _filterItem('video', '只看视频'),
      ],
    );
  }

  PopupMenuItem<String> _filterItem(String value, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(
            _filter == value
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: _filter == value
                ? GlassTheme.accentPurple
                : GlassTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: GlassTheme.accentPurple),
      );
    }
    if (_errorMessage != null) {
      return _buildErrorState();
    }
    if (_entries.isEmpty) {
      return _buildEmptyState();
    }
    final filtered = _filteredEntries;
    if (filtered.isEmpty) {
      return _buildNoMatchState();
    }
    if (_currentPath.isNotEmpty) {
      // 面包屑路径
      return Column(
        children: [
          _buildBreadcrumb(),
          Expanded(
            child: _gridView ? _buildGridView() : _buildListView(),
          ),
        ],
      );
    }
    return _buildGridView();
  }

  Widget _buildNoMatchState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.search_off_rounded,
              size: 40, color: GlassTheme.textTertiary),
          SizedBox(height: 8),
          Text('没有匹配的文件',
              style: TextStyle(
                  color: GlassTheme.textTertiary, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded,
                size: 48, color: GlassTheme.accentPink),
            const SizedBox(height: 12),
            Text(_errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: GlassTheme.textPrimary, fontSize: 14, height: 1.5)),
            const SizedBox(height: 16),
            GlassButton.outlined(
              icon: Icons.lock_open_rounded,
              label: '授权存储权限',
              height: 44,
              foregroundColor: GlassTheme.accentPurple,
              onTap: _requestStoragePermission,
            ),
            const SizedBox(height: 8),
            GlassButton(
              icon: Icons.refresh_rounded,
              label: '重试',
              height: 40,
              ghost: true,
              foregroundColor: GlassTheme.textSecondary,
              onTap: _loadRoots,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: GlassPanel(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded, size: 48, color: GlassTheme.textTertiary),
            const SizedBox(height: 12),
            const Text('未发现可访问的存储目录',
                style: TextStyle(color: GlassTheme.textPrimary, fontSize: 16)),
            const SizedBox(height: 6),
            const Text('请授权存储权限后重试',
                style: TextStyle(color: GlassTheme.textTertiary, fontSize: 12)),
            const SizedBox(height: 16),
            GlassButton.outlined(
              icon: Icons.lock_open_rounded,
              label: '授权存储权限',
              height: 44,
              foregroundColor: GlassTheme.accentPurple,
              onTap: _requestStoragePermission,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            GestureDetector(
              onTap: _loadRoots,
              child: const Icon(Icons.folder_rounded, size: 14, color: GlassTheme.textTertiary),
            ),
            ...parts.asMap().entries.map((e) {
              final path = '/' + parts.sublist(0, e.key + 1).join('/');
              return Row(
                children: [
                  const Icon(Icons.chevron_right_rounded, size: 14, color: GlassTheme.textTertiary),
                  GestureDetector(
                    onTap: () => _navigate(path),
                    child: Text(e.value,
                        style: TextStyle(
                            color: e.key == parts.length - 1
                                ? GlassTheme.accentPurple
                                : GlassTheme.textSecondary,
                            fontSize: 12)),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildGridView() {
    final w = MediaQuery.of(context).size.width;
    // 与「全部视频」页一致的左右留白，切视图时网格不左右跳
    final hp = AppBreakpoints.horizontalPadding(context);
    // 手机用原来的 3 列，平板按屏幕宽度动态列数（≥600dp 起）
    final bool isMobile = w < 600;
    final columns = isMobile ? 3 : AppBreakpoints.gridColumns(context);
    // 扣除左右留白 + 列间距后，每张卡片宽度
    final cardW = (w - hp * 2 - (columns - 1) * 10) / columns;
    // 文件夹卡片只展示图标(40px) + 标题(1-2行)，~115dp 高度足够
    final ratio = isMobile ? 0.85 : (cardW / 115).clamp(0.9, 2.0);
    return GridView.builder(
      // 顶部 8 / 底部 96：与首页 SliverPadding(fromLTRB(hp, 8, hp, 96)) 对齐
      padding: EdgeInsets.fromLTRB(hp, 8, hp, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: ratio,
      ),
      itemCount: _filteredEntries.length,
      itemBuilder: (context, index) {
        final entry = _filteredEntries[index];
        final isDir = entry is Directory;
        final isVideo = _isVideoFile(entry.path);

        return GlassCard(
          radius: GlassTheme.radiusLg,
          padding: const EdgeInsets.all(12),
          tint: isDir ? GlassTheme.tintTeal : GlassTheme.tintPurple,
          onTap: () {
            if (isDir) {
              _navigate(entry.path);
            } else if (isVideo) {
              context.pushNamed('player', extra: {
                'videoPath': entry.path,
                'videoTitle': entry.path.split('/').last,
              });
            }
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isDir
                    ? Icons.folder_rounded
                    : (isVideo ? Icons.play_circle_rounded : Icons.insert_drive_file_rounded),
                size: 40,
                color: isDir
                    ? GlassTheme.accentTeal.withOpacity(0.8)
                    : (isVideo ? GlassTheme.accentPurple : GlassTheme.textTertiary),
              ),
              const SizedBox(height: 8),
              Text(
                entry.path.split('/').last,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildListView() {
    final hp = AppBreakpoints.horizontalPadding(context);
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(hp, 0, hp, 96),
      itemCount: _filteredEntries.length,
      itemBuilder: (context, index) {
        final entry = _filteredEntries[index];
        final isDir = entry is Directory;
        final isVideo = _isVideoFile(entry.path);

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GlassCard(
            radius: GlassTheme.radiusSm,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            onTap: () {
              if (isDir) {
                _navigate(entry.path);
              } else if (isVideo) {
                context.pushNamed('player', extra: {
                  'videoPath': entry.path,
                  'videoTitle': entry.path.split('/').last,
                });
              }
            },
            child: Row(
              children: [
                Icon(
                  isDir ? Icons.folder_rounded : Icons.movie_rounded,
                  size: 22,
                  color: isDir ? GlassTheme.accentTeal : GlassTheme.accentPurple,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(entry.path.split('/').last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 14)),
                ),
                if (isDir)
                  const Icon(Icons.chevron_right_rounded, color: GlassTheme.textTertiary),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _isVideoFile(String path) {
    final idx = path.lastIndexOf('.');
    if (idx < 0) return false;
    final ext = path.substring(idx + 1).toLowerCase();
    // 用统一常量：原来这里硬编码 9 种，与 AppConstants（21 种）不一致，
    // 导致 mpg/rmvb/m2ts 等格式在文件夹里点不开
    return AppConstants.supportedVideoFormats.contains(ext);
  }
}