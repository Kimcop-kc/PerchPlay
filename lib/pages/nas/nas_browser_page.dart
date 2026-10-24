import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/system/system_ui_policy.dart';
import '../../models/nas_connection_model.dart';
import '../../providers/nas_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/safe_glass.dart';
import '../../widgets/common/app_page_header.dart';
import '../../widgets/player/mini_player.dart';
import '../../providers/player_provider.dart';
import '../cloud/cloud_drive_page.dart';

/// NAS 文件浏览器 — iOS 27 玻璃质感
class NasBrowserPage extends ConsumerStatefulWidget {
  const NasBrowserPage({super.key});

  @override
  ConsumerState<NasBrowserPage> createState() => _NasBrowserPageState();
}

class _NasBrowserPageState extends ConsumerState<NasBrowserPage> {
  Timer? _autoDiscoverTimer;

  /// 顶部「NAS / 云盘」切换。两者都是远程媒体库，合成一个 tab。
  bool _showCloud = false;

  @override
  void initState() {
    super.initState();
    // 打开页面就自动在后台找局域网 NAS（不需要用户点按钮），
    // 之后每 60 秒静默刷新一次；找到才在界面上出现可用连接。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nasProvider.notifier).discoverNas();
    });
    _autoDiscoverTimer = Timer.periodic(const Duration(seconds: 120), (_) {
      if (!mounted) return;
      ref.read(nasProvider.notifier).discoverNas();
    });
  }

  @override
  void dispose() {
    _autoDiscoverTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nasState = ref.watch(nasProvider);
    final isLarge = AppBreakpoints.isLargeScreen(context);

    // 订阅「有没有小窗」这个布尔量（不是整个 PlayerState）。
    // 小窗出现/消失时页面要重建，否则列表底部留白算错：
    // 小窗浮在导航栏之上，不占布局空间，留白不够就会压住最后几行。
    // 只取布尔值，播放位置每秒变化不会引起本页重建。
    //
    // 注意：这个值要传给下面的列表（通过 _miniVisible 缓存），
    // 不能只声明不用 —— 那样订阅就白建了，列表拿到的仍是旧值。
    final hasMini = ref.watch(playerProvider.select(
        (p) => p.currentVideo != null && p.videoController != null));
    _miniVisible = hasMini;

    // 云盘模式：整块换成云盘页（它自带完整 header 与列表），
    // 这里只负责把顶部分段切换器叠上去，避免两套 header 叠加。
    if (_showCloud) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              _buildTabletTitle(),
              const Expanded(child: CloudDriveView()),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        // 与首页一致：内容铺到屏幕底，避免导航栏下方出现空白层
        bottom: false,
        child: Column(
          children: [
            // 手机显示标题栏（含 NAS/网盘切换按钮）；
            // 平板标题在 _buildTabletLayout 内部，避免重复。
            if (!isLarge) _buildTabletTitle(),
            if (nasState.errorMessage != null)
              _buildErrorBanner(nasState.errorMessage!),
            // 状态指示：只在「点连接后卡住」的可疑状态下显示，
            // 正常使用时不干扰界面。
            //
            // 排查「点了没反应」时，这一条能直接告诉用户/开发者
            // 卡在哪一步：loading 一直为 true 说明请求发出去了但没回来；
            // connected 为 true 但文件为空说明连上了但读不到目录。
            if (nasState.isLoading || _shouldShowStateHint(nasState))
              _buildStateHint(nasState),
            _buildDiscoverySection(nasState),
            Expanded(
              child: isLarge
                  ? _buildTabletLayout(nasState)
                  : _buildMobileLayout(nasState),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前是否显示着后台播放小窗。
  ///
  /// 缓存自 build 里的 watch 结果：列表 builder 内部拿不到 ref.watch 的
  /// 订阅（用 ref.read 不会触发重建），所以必须由外层算好、这里只读。
  bool _miniVisible = false;

  bool _hasMiniPlayer() => _miniVisible;

  /// bottomSheet 底部要留的安全高度。
  ///
  /// 取「原生实测导航栏高度」与 56dp 中较大者。
  ///
  /// ## 为什么必须有 56dp 这个下限
  ///
  /// 用户实测日志里，小米手势导航上报的导航栏高度只有 **20.1dp**。
  /// 但手势条（那条小白线）本身加上下留白约 24~32dp，再加上手指点按
  /// 需要的余量，20dp 的留白等于没留 —— 按钮仍会被压住一半。
  ///
  /// 三键导航实测约 48dp，再加一点呼吸空间就是 56dp。
  /// 视觉上多出十几个 dp 完全可以接受，但按钮点不到是硬伤。
  static double _sheetSafeBottom(BuildContext ctx) {
    final inset = SystemUiPolicy.bottomSheetInset(MediaQuery.of(ctx));
    return inset > 56 ? inset : 56.0;
  }

  /// 是否值得显示状态提示。
  ///
  /// 只在「已经连上但文件列表为空」这种可疑状态下提示 ——
  /// 正常浏览时不显示，避免干扰。
  bool _shouldShowStateHint(NasState s) =>
      s.isConnected && s.currentFiles.isEmpty && s.errorMessage == null;

  /// 一条轻量的状态提示，帮助定位「点了没反应」卡在哪一层。
  Widget _buildStateHint(NasState s) {
    final text = s.isLoading
        ? '正在连接 / 读取目录…（若长时间停在这里，说明请求发出去了但没有响应）'
        : '已连接，但没有读到任何文件（可能是路径不对，或该目录确实为空）';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: GlassTheme.accentTeal.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
        border: Border.all(
            color: GlassTheme.accentTeal.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        children: [
          if (s.isLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.8, color: GlassTheme.accentTeal),
            )
          else
            const Icon(Icons.info_outline_rounded,
                size: 14, color: GlassTheme.accentTeal),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: GlassTheme.textSecondary,
                    fontSize: 11,
                    height: 1.4)),
          ),
        ],
      ),
    );
  }

  /// 连接/读取失败的错误横幅
  Widget _buildErrorBanner(String message) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: GlassTheme.accentPink.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
        border: Border.all(
            color: GlassTheme.accentPink.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: GlassTheme.accentPink, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    color: GlassTheme.textPrimary, fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: GlassTheme.textTertiary, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              ref.read(nasProvider.notifier).clearError();
            },
          ),
        ],
      ),
    );
  }

  // ═══════════════ 手机 ═══════════════

  Widget _buildMobileLayout(NasState state) {
    if (state.isConnected && state.activeConnection != null)
      return _buildFileBrowser(state);
    if (state.connections.isEmpty) {
      return _buildEmptyConnections();
    }
    return _buildConnectionList(state);
  }

  // ═══════════════ 局域网自动发现 ═══════════════

  /// 自动发现的可用连接
  ///
  /// 后台静默扫描，**只有真的发现 NAS 才显示**；没找到就什么都不显示
  /// （搜索中只在顶部给一条很轻的提示，不占地方、不需要用户操作）。
  Widget _buildDiscoverySection(NasState state) {
    final candidates = state.candidates;

    if (candidates.isEmpty) {
      // 没搜到：不显示任何东西（搜索中给一条细提示）
      if (!state.isDiscovering) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.8, color: GlassTheme.accentTeal),
            ),
            const SizedBox(width: 8),
            Text(
              '正在搜索局域网 NAS…',
              style: TextStyle(
                  color: GlassTheme.textTertiary.withValues(alpha: 0.9),
                  fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: GlassTheme.accentTeal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        border: Border.all(
            color: GlassTheme.accentTeal.withValues(alpha: 0.25), width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi_find_rounded,
                  size: 16, color: GlassTheme.accentTeal),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '发现局域网上的可用连接（${candidates.length}）',
                  style: const TextStyle(
                      color: GlassTheme.textPrimary, fontSize: 13),
                ),
              ),
              if (state.isDiscovering)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: GlassTheme.accentTeal),
                ),
            ],
          ),
          const SizedBox(height: 2),
          ...candidates.take(6).map((c) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  c.isWebDav ? Icons.cloud_done_rounded : Icons.dns_rounded,
                  size: 20,
                  color: c.isWebDav
                      ? GlassTheme.accentTeal
                      : GlassTheme.textSecondary,
                ),
                title: Text(c.label,
                    style: const TextStyle(
                        color: GlassTheme.textPrimary, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  c.address + (c.isWebDav ? ' · 可直接连接' : ' · 需账号密码'),
                  style: const TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right_rounded,
                    size: 18, color: GlassTheme.textTertiary),
                onTap: () => _showAddConnectionDialog(
                  context,
                  presetHost: c.host,
                  presetPort: c.port,
                  presetProtocol: c.protocol,
                ),
              )),
        ],
      ),
    );
  }

  // ═══════════════ 平板双栏 ═══════════════

  Widget _buildTabletLayout(NasState state) {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: Column(
            children: [
              _buildTabletTitle(),
              Expanded(
                child: state.connections.isEmpty
                    ? _buildEmptyConnections()
                    : _buildConnectionList(state),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 0.5, color: Color(0x14000000)),
        Expanded(
          child: state.isConnected && state.activeConnection != null
              ? _buildFileBrowser(state)
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.dns_rounded,
                          size: 48, color: GlassTheme.textTertiary),
                      const SizedBox(height: 12),
                      Text('选择一个连接以浏览文件',
                          style: TextStyle(
                              color: GlassTheme.textSecondary, fontSize: 15)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTabletTitle() {
    // 平板侧栏用紧凑标题（小字号），手机全宽用 AppPageHeader 大标题。
    final isLarge = AppBreakpoints.isLargeScreen(context);
    if (isLarge) {
      // 侧栏 300px：标题在左，切换按钮在最右
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _showCloud ? '网盘' : 'NAS',
                style: const TextStyle(
                  color: GlassTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            GlassButton.outlined(
              icon: _showCloud ? Icons.dns_rounded : Icons.cloud_rounded,
              label: _showCloud ? 'NAS' : '网盘',
              height: 32,
              foregroundColor: GlassTheme.accentPurple,
              onTap: () => setState(() => _showCloud = !_showCloud),
            ),
          ],
        ),
      );
    }
    // 手机：与所有 tab 页统一，切换按钮放最右侧（trailing）
    return AppPageHeader(
      title: '串流',
      subtitle: _showCloud ? '网盘 · 夸克 / 115 / 百度 / 阿里' : 'NAS · WebDAV / FTP',
      asSliver: false,
      childGap: 12,
      trailing: GlassButton.outlined(
        icon: _showCloud ? Icons.dns_rounded : Icons.cloud_rounded,
        label: _showCloud ? 'NAS' : '网盘',
        height: 36,
        foregroundColor: GlassTheme.accentPurple,
        onTap: () => setState(() => _showCloud = !_showCloud),
      ),
    );
  }

  // ═══════════════ 连接列表 ═══════════════

  Widget _buildConnectionList(NasState state) {
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        0,
        12,
        // 同 _buildFileList：小窗浮在导航栏之上，留白要把它算进去
        MiniPlayer.bottomInset(hasMiniPlayer: _hasMiniPlayer()),
      ),
      itemCount: state.connections.length + 1, // +1 为顶部「添加连接」按钮
      itemBuilder: (context, index) {
        // 顶部统一放「添加连接」按钮（手机/平板一致，标题栏不再放添加）
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10, top: 8),
            child: GlassButton.outlined(
              icon: Icons.add_link_rounded,
              label: '手动添加连接（WebDAV / FTP）',
              width: double.infinity,
              height: 44,
              foregroundColor: GlassTheme.accentTeal,
              onTap: () => _showAddConnectionDialog(context),
            ),
          );
        }
        final connIndex = index - 1;
        if (connIndex >= state.connections.length)
          return const SizedBox.shrink();

        final conn = state.connections[connIndex];
        final isActive = state.activeConnection?.id == conn.id;
        final isConnecting = state.isLoading && state.activeConnection == null;

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GlassCard(
            radius: GlassTheme.radiusSm,
            padding: const EdgeInsets.all(12),
            selected: isActive,
            tint: isActive ? GlassTheme.tintTeal : GlassTheme.tintWhite,
            onTap: () async {
              // 用户操作也记进日志：排查「点了没反应」时，先要确认点击事件
              // 到底有没有到达这里 —— 没有就是 UI 层问题，有就是连接层问题。
              debugPrint('[NAS-UI] 点击连接「${conn.name}」'
                  ' isActive=$isActive loading=${state.isLoading} '
                  'connected=${state.isConnected} '
                  'active=${state.activeConnection?.id ?? "null"} '
                  'connId=${conn.id}');

              // 已激活的连接：**进入文件浏览**，而不是什么都不做。
              //
              // 之前这里是 `if (!isActive) connect(...)`，于是点击当前
              // 已选中的连接完全没反应 —— 用户明明看到一张卡片可点，
              // 点下去却像死了一样（日志里连续 4 次 isActive=true 无动作）。
              //
              // 正确语义：
              //  - 未激活 -> 建立连接
              //  - 已激活 -> 回到该连接的文件列表（重新读一次目录）
              if (isActive) {
                if (state.isConnected && state.currentFiles.isNotEmpty) {
                  // 已经在浏览中：不该出现在列表页，但防御性处理
                  return;
                }
                debugPrint('[NAS-UI] 已激活 -> 重新进入文件浏览');
                await ref.read(nasProvider.notifier).connect(conn);
                return;
              }
              final ok = await ref.read(nasProvider.notifier).connect(conn);
              debugPrint('[NAS-UI] connect 返回 $ok');
            },
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        (isActive
                                ? GlassTheme.accentTeal
                                : Colors.black.withValues(alpha: 0.08))
                            .withValues(alpha: 0.2),
                        (isActive
                                ? GlassTheme.accentTeal
                                : Colors.black.withValues(alpha: 0.04))
                            .withValues(alpha: 0.06),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
                  ),
                  child: Icon(
                    _protocolIcon(conn.protocol),
                    color: isActive
                        ? GlassTheme.accentTeal
                        : GlassTheme.textSecondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(conn.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(
                        '${conn.protocol.name.toUpperCase()}://${conn.host}:${conn.port}',
                        style: const TextStyle(
                            color: GlassTheme.textTertiary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (isConnecting)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: GlassTheme.accentTeal),
                  )
                else if (isActive)
                  const Icon(Icons.check_circle_rounded,
                      color: GlassTheme.accentTeal, size: 20),
                // 编辑 / 删除入口。
                //
                // 之前卡片只有「点一下去连接」，添加完就再也改不了 ——
                // 密码错了、路径填错都只能删了重加，而删除入口也不存在，
                // 等于配置一次就锁死。这里补一个溢出菜单。
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_vert_rounded,
                      size: 20, color: GlassTheme.textTertiary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  onSelected: (v) {
                    if (v == 'edit') {
                      _showAddConnectionDialog(context, editing: conn);
                    } else if (v == 'delete') {
                      _confirmDeleteConnection(conn);
                    }
                  },
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_rounded,
                              size: 18, color: GlassTheme.textSecondary),
                          SizedBox(width: 10),
                          Text('修改连接'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline_rounded,
                              size: 18, color: GlassTheme.accentPink),
                          SizedBox(width: 10),
                          Text('删除连接',
                              style: TextStyle(color: GlassTheme.accentPink)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ═══════════════ 文件浏览器 ═══════════════

  Widget _buildFileBrowser(NasState state) {
    return Column(
      children: [
        _buildBreadcrumb(state),
        Expanded(
          child: state.isLoading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: GlassTheme.accentPurple))
              : state.currentFiles.isEmpty
                  ? Center(
                      child: Text('此目录为空',
                          style: TextStyle(color: GlassTheme.textSecondary)),
                    )
                  : _buildFileList(state),
        ),
      ],
    );
  }

  Widget _buildBreadcrumb(NasState state) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: GlassCard(
        radius: GlassTheme.radiusSm,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        tint: GlassTheme.tintTeal,
        child: Row(
          children: [
            GlassButton(
              icon: Icons.arrow_back_rounded,
              compact: true,
              ghost: true,
              foregroundColor: GlassTheme.textSecondary,
              onTap: () => ref.read(nasProvider.notifier).backToList(),
            ),
            GlassButton(
              icon: Icons.arrow_upward_rounded,
              compact: true,
              ghost: true,
              foregroundColor: GlassTheme.textTertiary,
              onTap: state.currentPath != '/' && state.currentPath.isNotEmpty
                  ? () => ref.read(nasProvider.notifier).navigateUp()
                  : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  state.currentPath,
                  style: const TextStyle(
                      color: GlassTheme.textSecondary, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(NasState state) {
    final sorted = [...state.currentFiles]..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.compareTo(b.name);
      });

    return ListView.builder(
      // 底部留白要跟着「有没有小窗」变。小窗是浮层、不占布局空间，
      // 只按导航栏留白的话，小窗出现时最后几行会被压住点不到。
      padding: EdgeInsets.fromLTRB(
        12,
        0,
        12,
        MiniPlayer.bottomInset(hasMiniPlayer: _hasMiniPlayer()),
      ),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final item = sorted[index];
        return _buildFileTile(state, item);
      },
    );
  }

  Widget _buildFileTile(NasState state, NasFileItem item) {
    final iconColor = item.isDirectory
        ? GlassTheme.accentTeal
        : item.isVideo
            ? GlassTheme.accentPurple
            : GlassTheme.textTertiary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GlassCard(
        radius: GlassTheme.radiusXs,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        tint: GlassTheme.tintWhite,
        onTap: () {
          debugPrint('[NAS-UI] 点击「${item.name}」'
              ' dir=${item.isDirectory} video=${item.isVideo}');
          if (item.isDirectory) {
            ref.read(nasProvider.notifier).navigateTo(item.path);
          } else if (item.isVideo) {
            final url =
                ref.read(nasProvider.notifier).getPlayableUrl(item.path);
            // 带认证头：需要登录的 NAS 上，播放是 mpv 直接连，
            // 不带 Authorization 会 401（目录能看、视频打不开）
            final headers = ref.read(nasProvider.notifier).playHeaders();
            debugPrint('[NAS-UI] 播放 URL = $url '
                '认证=${headers.isNotEmpty}');
            context.pushNamed('player', extra: {
              'videoPath': url,
              'videoTitle': item.name,
              if (headers.isNotEmpty) 'headers': headers,
            });
          }
        },
        child: Row(
          children: [
            Icon(
              item.isDirectory
                  ? Icons.folder_rounded
                  : item.isVideo
                      ? Icons.play_circle_rounded
                      : Icons.insert_drive_file_rounded,
              color: iconColor,
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  Text(
                    item.isDirectory ? '文件夹' : _formatSize(item.size),
                    style: const TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (item.isVideo)
              GlassButton(
                icon: Icons.play_arrow_rounded,
                compact: true,
                filled: true,
                height: 34,
                onTap: () {
                  final url =
                      ref.read(nasProvider.notifier).getPlayableUrl(item.path);
                  final headers = ref.read(nasProvider.notifier).playHeaders();
                  context.pushNamed('player', extra: {
                    'videoPath': url,
                    'videoTitle': item.name,
                    if (headers.isNotEmpty) 'headers': headers,
                  });
                },
              )
            else if (item.isDirectory)
              const Icon(Icons.chevron_right_rounded,
                  color: GlassTheme.textTertiary, size: 18),
          ],
        ),
      ),
    );
  }

  /// 删除连接前的确认。
  ///
  /// 必须二次确认：删掉后配置（含密码）就没了，得重新填写。
  Future<void> _confirmDeleteConnection(NasConnection conn) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF2F2F7),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('删除连接',
            style: TextStyle(color: Color(0xFF1C1C1E), fontSize: 18)),
        content: Text(
          '确定删除「${conn.name}」吗？\n\n'
          '只会移除本机保存的连接配置，不会影响 NAS 上的文件。',
          style: const TextStyle(
              color: Color(0xFF3A3A3C), fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消',
                style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: GlassTheme.accentPink,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(nasProvider.notifier).removeConnection(conn.id);
    }
  }

  // ═══════════════ 添加 / 编辑连接对话框 ═══════════════
  /// 添加或编辑一个 NAS 连接。
  ///
  /// [editing] 非空时为**编辑模式**：各字段用现有配置预填，
  /// 保存时走 `updateConnection`（保留原 id，覆盖配置）。
  void _showAddConnectionDialog(
    BuildContext context, {
    String? presetHost,
    int? presetPort,
    NasProtocol? presetProtocol,
    NasConnection? editing,
  }) {
    final isEdit = editing != null;
    final nameCtrl = TextEditingController(
        text: isEdit
            ? editing.name
            : (presetHost != null
                ? 'NAS ${presetHost.split('.').last}'
                : '我的 NAS'));
    final hostCtrl = TextEditingController(text: editing?.host ?? presetHost ?? '');
    // 默认仍选 WebDAV：群晖/威联通默认就开，且不需要填共享名；
    // SMB 也支持了（dart_smb2 / libsmb2，SMB2/3），用户可自行切换。
    final portCtrl = TextEditingController(
        text: (editing?.port ?? presetPort)?.toString() ?? '5005');
    final usernameCtrl =
        TextEditingController(text: editing?.username ?? '');
    final passwordCtrl =
        TextEditingController(text: editing?.password ?? '');
    final shareCtrl = TextEditingController(text: editing?.shareName ?? '');
    // WebDAV / FTP 的远程路径：WebDAV 必须知道具体路径（如群晖
    // /dav、Nextcloud /remote.php/dav/files/用户名），否则只能连到根目录，
    // 很多服务在根目录会返回 404/405。留空时按 `/` 处理。
    final pathCtrl = TextEditingController(text: editing?.remotePath ?? '');
    var protocol = editing?.protocol ?? presetProtocol ?? NasProtocol.webdav;
    // HTTPS 开关：编辑时沿用原值，新增时按端口猜（443 开 HTTPS）
    var useHttps = editing?.useHttps ?? ((presetPort ?? 5005) == 443);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return Container(
            // 高度 = min(内容自适应上限, 屏高 - 安全区)。
            //
            // 为什么必须减安全区：`showModalBottomSheet` 贴屏幕物理底边，
            // 面板底边就在导航栏下面，按钮必然被压住。
            // 减掉安全区让整个面板上移，按钮自然落在导航栏之上。
            // 这比「在面板内加 padding」可靠得多 —— padding 只把内容往上推，
            // 面板本身底边仍在导航栏区域里。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.88 -
                  _sheetSafeBottom(ctx),
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.92),
                  Colors.white.withValues(alpha: 0.82),
                ],
              ),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(GlassTheme.radiusXl)),
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(GlassTheme.radiusXl)),
              child: SafeBackdropFilter(
                blurSigma: 18,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 4),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      // 底部 padding 用 _sheetSafeBottom：叠加实测导航栏
                      // 与 48dp 下限。这个 bottomSheet 贴屏幕底，外层
                      // SafeArea 是 bottom:false，MediaQuery.padding 不生效；
                      // 低版本 manual 模式下连 viewPadding 都是 0。
                      padding: EdgeInsets.fromLTRB(
                        24,
                        8,
                        24,
                        24 + _sheetSafeBottom(ctx),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(isEdit ? '修改 NAS 连接' : '添加 NAS 连接',
                          style: const TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 20),
                      _dialogField('名称', nameCtrl),
                      const SizedBox(height: 14),
                      // 协议选择
                      const Text('协议',
                          style: TextStyle(
                              color: GlassTheme.textSecondary, fontSize: 13)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: NasProtocol.values.map((p) {
                          final selected = protocol == p;
                          // NFS 需要内核支持，Dart 层无法实现；
                          // SMB 已通过 dart_smb2（libsmb2）支持 SMB2/3。
                          final unsupported = p == NasProtocol.nfs;
                          return GlassButton(
                            label: unsupported
                                ? '${p.name.toUpperCase()}（暂不支持）'
                                : '${p.name.toUpperCase()} ✓',
                            height: 32,
                            filled: selected,
                            outlined: !selected,
                            foregroundColor: selected
                                ? Colors.white
                                : (unsupported
                                    ? GlassTheme.textTertiary
                                    : GlassTheme.textSecondary),
                            onTap: () {
                              setDialogState(() => protocol = p);
                              switch (p) {
                                case NasProtocol.smb:
                                  portCtrl.text = '445';
                                  break;
                                case NasProtocol.ftp:
                                  portCtrl.text = '21';
                                  break;
                                case NasProtocol.webdav:
                                  portCtrl.text = '5005';
                                  break;
                                case NasProtocol.nfs:
                                  portCtrl.text = '2049';
                                  break;
                              }
                            },
                          );
                        }).toList(),
                      ),
                      if (protocol == NasProtocol.nfs)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'NFS 需要系统内核支持，Android 上无法直连。'
                            '请改用 SMB（群晖/威联通/Windows 共享都支持）'
                            '或 WebDAV。',
                            style: TextStyle(
                                color: GlassTheme.accentPink,
                                fontSize: 11.5,
                                height: 1.4),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _dialogField('主机地址', hostCtrl),
                      // SMB 必须先指定共享名（如 video / movies）
                      if (protocol == NasProtocol.smb) ...[
                        const SizedBox(height: 14),
                        _dialogField('共享名（如 video）', shareCtrl),
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'SMB 必须填写共享文件夹名。端口固定 445，'
                            'Windows 共享填工作组名（默认 WORKGROUP 可留空）。',
                            style: TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 11,
                                height: 1.4),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _dialogField('端口', portCtrl, isNumber: true),
                      // HTTPS 开关：WebDAV / FTP 都需要明确选择加密方式
                      if (protocol == NasProtocol.webdav ||
                          protocol == NasProtocol.ftp) ...[
                        const SizedBox(height: 12),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '使用 HTTPS（加密）',
                            style: TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            useHttps
                                ? 'https://${hostCtrl.text.isEmpty ? 'your-nas' : hostCtrl.text}:${portCtrl.text}'
                                : 'http://${hostCtrl.text.isEmpty ? 'your-nas' : hostCtrl.text}:${portCtrl.text}',
                            style: const TextStyle(
                              color: GlassTheme.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                          value: useHttps,
                          activeColor: GlassTheme.accentTeal,
                          onChanged: (v) =>
                              setDialogState(() => useHttps = v),
                        ),
                      ],
                      // WebDAV / FTP 需要远程路径
                      if (protocol == NasProtocol.webdav ||
                          protocol == NasProtocol.ftp) ...[
                        const SizedBox(height: 14),
                        _dialogField('路径（留空为 /）', pathCtrl),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            protocol == NasProtocol.webdav
                                ? 'WebDAV 必须填对路径：群晖填 /dav，'
                                    'Nextcloud 填 /remote.php/dav/files/用户名，'
                                    '坚果云填 /dav。填错会连不上或只看到根目录。'
                                : 'FTP 的远程起始目录，留空表示登录后所在目录。',
                            style: const TextStyle(
                                color: GlassTheme.textTertiary,
                                fontSize: 11,
                                height: 1.4),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      _dialogField('用户名', usernameCtrl),
                      const SizedBox(height: 14),
                      _dialogField('密码', passwordCtrl, isPassword: true),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: GlassButton(
                              label: '取消',
                              height: 46,
                              ghost: true,
                              foregroundColor: GlassTheme.textSecondary,
                              onTap: () => Navigator.pop(ctx),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GlassButton.filled(
                              label: isEdit ? '保存' : '连接',
                              height: 46,
                              onTap: () {
                                if (hostCtrl.text.trim().isEmpty) return;
                                final conn = NasConnection(
                                  // 编辑时保留原 id（updateConnection 靠它匹配）；
                                  // 新增时生成一个新 id
                                  id: isEdit
                                      ? editing.id
                                      : DateTime.now()
                                          .millisecondsSinceEpoch
                                          .toRadixString(16),
                                  name: nameCtrl.text.trim(),
                                  protocol: protocol,
                                  host: hostCtrl.text.trim(),
                                  port: int.tryParse(portCtrl.text) ?? 445,
                                  username: usernameCtrl.text,
                                  password: passwordCtrl.text,
                                  // SMB 必需：先连到具体共享
                                  shareName: shareCtrl.text.trim(),
                                  // WebDAV/FTP 的远程起始路径；留空按根目录
                                  remotePath: pathCtrl.text.trim().isEmpty
                                      ? '/'
                                      : pathCtrl.text.trim(),
                                  savePassword: true,
                                  useHttps: useHttps,
                                );
                                Navigator.pop(ctx);
                                if (isEdit) {
                                  // 编辑：覆盖配置；若原连接是活跃的，
                                  // updateConnection 内部会断开旧连接并重连
                                  ref
                                      .read(nasProvider.notifier)
                                      .updateConnection(conn);
                                } else {
                                  ref
                                      .read(nasProvider.notifier)
                                      .addConnection(conn);
                                  ref
                                      .read(nasProvider.notifier)
                                      .connect(conn);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
        },
      ),
    );
  }

  Widget _dialogField(String label, TextEditingController ctrl,
      {bool isPassword = false, bool isNumber = false}) {
    return TextField(
      controller: ctrl,
      obscureText: isPassword,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: GlassTheme.textTertiary, fontSize: 13),
        filled: true,
        fillColor: Colors.black.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
          borderSide: BorderSide(color: Colors.black.withValues(alpha: 0.06)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
          borderSide: const BorderSide(color: GlassTheme.accentTeal, width: 1),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  // ═══════════════ 空状态 ═══════════════

  Widget _buildEmptyConnections() {
    return Center(
      // 小窗浮在底部时会盖住居中内容的下半部分（包括「手动添加」按钮），
      // 这个按钮是唯一入口，被挡住用户就没法添加连接了。
      // 用 Padding 把小窗占的高度顶上去，而不是整体缩小。
      child: Padding(
        padding: EdgeInsets.only(
          bottom: _hasMiniPlayer()
              ? MiniPlayer.height + MiniPlayer.navBarHeight
              : 0,
        ),
        child: GlassPanel(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_rounded, size: 48, color: GlassTheme.textTertiary),
              const SizedBox(height: 12),
              const Text('未添加 NAS 连接',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              // 后台自动搜索：找到会直接出现在上方「可用连接」里
              const Text('正在自动搜索局域网 NAS…\n也可以手动填写地址',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: GlassTheme.textTertiary, fontSize: 12, height: 1.5)),
              const SizedBox(height: 16),
              GlassButton.outlined(
                icon: Icons.add_link_rounded,
                label: '手动添加（WebDAV / FTP）',
                width: double.infinity,
                height: 44,
                foregroundColor: GlassTheme.accentTeal,
                onTap: () => _showAddConnectionDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  IconData _protocolIcon(NasProtocol protocol) {
    switch (protocol) {
      case NasProtocol.smb:
        return Icons.folder_shared_rounded;
      case NasProtocol.ftp:
        return Icons.cloud_upload_rounded;
      case NasProtocol.webdav:
        return Icons.cloud_sync_rounded;
      case NasProtocol.nfs:
        return Icons.lan_rounded;
    }
  }
}
