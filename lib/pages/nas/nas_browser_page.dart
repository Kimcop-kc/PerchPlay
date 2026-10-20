import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/responsive/breakpoints.dart';
import '../../models/nas_connection_model.dart';
import '../../providers/nas_provider.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/glass/glass_panel.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/safe_glass.dart';
import '../../widgets/common/app_page_header.dart';
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
            if (nasState.errorMessage != null)
              _buildErrorBanner(nasState.errorMessage!),
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
                style: const TextStyle(color: GlassTheme.textPrimary, fontSize: 13)),
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
    if (state.isConnected) return _buildFileBrowser(state);
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
          child: state.isConnected
              ? _buildFileBrowser(state)
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.dns_rounded, size: 48, color: GlassTheme.textTertiary),
                      const SizedBox(height: 12),
                      Text('选择一个连接以浏览文件',
                          style:
                              TextStyle(color: GlassTheme.textSecondary, fontSize: 15)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTabletTitle() {
    // 与所有 tab 页统一：同一个留白/字号规格，切 tab 不跳
    return AppPageHeader(
      title: '网络存储',
      subtitle:
          _showCloud ? '云盘 · 夸克 / 115 / 百度 / 阿里' : 'NAS · WebDAV / FTP',
      asSliver: false,
      childGap: 12,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「NAS / 云盘」分段切换：两者都是「远程媒体库」，
          // 合成一个 tab 免得底栏挤到 7 项、手机每项只剩约 50dp。
          GlassButton.outlined(
            icon: _showCloud ? Icons.dns_rounded : Icons.cloud_rounded,
            label: _showCloud ? 'NAS' : '云盘',
            height: 36,
            foregroundColor: GlassTheme.accentPurple,
            onTap: () => setState(() => _showCloud = !_showCloud),
          ),
          if (!_showCloud) ...[
            const SizedBox(width: 8),
            GlassButton.outlined(
              icon: Icons.add_link_rounded,
              label: '添加',
              height: 36,
              foregroundColor: GlassTheme.accentTeal,
              onTap: () => _showAddConnectionDialog(context),
            ),
          ],
        ],
      ),
    );
  }

  // ═══════════════ 连接列表 ═══════════════

  Widget _buildConnectionList(NasState state) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, GlassTheme.navBarOverlay),
      itemCount: state.connections.length + 1, // +1 for add button on mobile
      itemBuilder: (context, index) {
        if (index == 0 && !AppBreakpoints.isLargeScreen(context)) {
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
        final connIndex =
            AppBreakpoints.isLargeScreen(context) ? index : index - 1;
        if (connIndex >= state.connections.length) return const SizedBox.shrink();

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
              if (!isActive) {
                await ref.read(nasProvider.notifier).connect(conn);
              }
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
                    borderRadius:
                        BorderRadius.circular(GlassTheme.radiusXs),
                  ),
                  child: Icon(
                    _protocolIcon(conn.protocol),
                    color: isActive ? GlassTheme.accentTeal : GlassTheme.textSecondary,
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
                  style: const TextStyle(color: GlassTheme.textSecondary, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileList(NasState state) {
    final sorted = [...state.currentFiles]
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.compareTo(b.name);
      });

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, GlassTheme.navBarOverlay),
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
          if (item.isDirectory) {
            ref.read(nasProvider.notifier).navigateTo(item.path);
          } else if (item.isVideo) {
            final url =
                ref.read(nasProvider.notifier).getPlayableUrl(item.path);
            context.pushNamed('player', extra: {
              'videoPath': url,
              'videoTitle': item.name,
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
                    style: const TextStyle(color: GlassTheme.textTertiary, fontSize: 11),
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
                  final url = ref
                      .read(nasProvider.notifier)
                      .getPlayableUrl(item.path);
                  context.pushNamed('player', extra: {
                    'videoPath': url,
                    'videoTitle': item.name,
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

  // ═══════════════ 添加连接对话框 ═══════════════

  void _showAddConnectionDialog(
    BuildContext context, {
    String? presetHost,
    int? presetPort,
    NasProtocol? presetProtocol,
  }) {
    final nameCtrl = TextEditingController(
        text: presetHost != null ? 'NAS ${presetHost.split('.').last}' : '我的 NAS');
    final hostCtrl = TextEditingController(text: presetHost ?? '');
    // 默认仍选 WebDAV：群晖/威联通默认就开，且不需要填共享名；
    // SMB 也支持了（dart_smb2 / libsmb2，SMB2/3），用户可自行切换。
    final portCtrl =
        TextEditingController(text: presetPort?.toString() ?? '5005');
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final shareCtrl = TextEditingController();
    var protocol = presetProtocol ?? NasProtocol.webdav;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(GlassTheme.radiusXl),
            child: SafeBackdropFilter(
              blurSigma: 24,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.8),
                      Colors.white.withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(GlassTheme.radiusXl),
                  border: Border.all(
                      color: Colors.black.withValues(alpha: 0.08), width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 32,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('添加 NAS 连接',
                          style: TextStyle(
                              color: GlassTheme.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 20),
                      _dialogField('名称', nameCtrl),
                      const SizedBox(height: 14),
                      // 协议选择
                      const Text('协议',
                          style:
                              TextStyle(color: GlassTheme.textSecondary, fontSize: 13)),
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
                              label: '连接',
                              height: 46,
                              onTap: () {
                                if (hostCtrl.text.trim().isEmpty) return;
                                final conn = NasConnection(
                                  id: DateTime.now()
                                      .millisecondsSinceEpoch
                                      .toRadixString(16),
                                  name: nameCtrl.text.trim(),
                                  protocol: protocol,
                                  host: hostCtrl.text.trim(),
                                  port:
                                      int.tryParse(portCtrl.text) ?? 445,
                                  username: usernameCtrl.text,
                                  password: passwordCtrl.text,
                                  // SMB 必需：先连到具体共享
                                  shareName: shareCtrl.text.trim(),
                                  savePassword: true,
                                );
                                ref
                                    .read(nasProvider.notifier)
                                    .addConnection(conn);
                                Navigator.pop(ctx);
                                ref
                                    .read(nasProvider.notifier)
                                    .connect(conn);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
          borderSide:
              const BorderSide(color: GlassTheme.accentTeal, width: 1),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  // ═══════════════ 空状态 ═══════════════

  Widget _buildEmptyConnections() {
    return Center(
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
                    color: GlassTheme.textTertiary,
                    fontSize: 12,
                    height: 1.5)),
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
