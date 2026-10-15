import 'dart:ui';
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

/// NAS 文件浏览器 — iOS 27 玻璃质感
class NasBrowserPage extends ConsumerStatefulWidget {
  const NasBrowserPage({super.key});

  @override
  ConsumerState<NasBrowserPage> createState() => _NasBrowserPageState();
}

class _NasBrowserPageState extends ConsumerState<NasBrowserPage> {
  @override
  Widget build(BuildContext context) {
    final nasState = ref.watch(nasProvider);
    final isLarge = AppBreakpoints.isLargeScreen(context);

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
        color: GlassTheme.accentPink.withOpacity(0.12),
        borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
        border: Border.all(
            color: GlassTheme.accentPink.withOpacity(0.3), width: 0.5),
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
    if (state.connections.isEmpty) return _buildEmptyConnections();
    return _buildConnectionList(state);
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
    final topPad = MediaQuery.of(context).padding.top + 20;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPad, 20, 12),
      child: Row(
        children: [
          const Expanded(
            child: Text('NAS 文件',
                style: TextStyle(
                    color: GlassTheme.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w800)),
          ),
          GlassButton.outlined(
            icon: Icons.add_link_rounded,
            label: '添加',
            height: 36,
            foregroundColor: GlassTheme.accentTeal,
            onTap: () => _showAddConnectionDialog(context),
          ),
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
              label: '添加 NAS 连接',
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
                                : Colors.black.withOpacity(0.08))
                            .withOpacity(0.2),
                        (isActive
                                ? GlassTheme.accentTeal
                                : Colors.black.withOpacity(0.04))
                            .withOpacity(0.06),
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

  void _showAddConnectionDialog(BuildContext context) {
    final nameCtrl = TextEditingController(text: '我的 NAS');
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '445');
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    var protocol = NasProtocol.smb;

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
                      Colors.white.withOpacity(0.8),
                      Colors.white.withOpacity(0.5),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(GlassTheme.radiusXl),
                  border: Border.all(
                      color: Colors.black.withOpacity(0.08), width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
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
                          // SMB / NFS 尚未实现，明确标注，避免用户以为是设备问题
                          final unsupported = p == NasProtocol.smb ||
                              p == NasProtocol.nfs;
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
                      if (protocol == NasProtocol.smb ||
                          protocol == NasProtocol.nfs)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            '该协议暂未实现。NAS 请改用 WebDAV（群晖/威联通都支持，'
                            '在「控制面板 → 文件服务 → WebDAV」开启）或 FTP。',
                            style: TextStyle(
                                color: GlassTheme.accentPink,
                                fontSize: 11.5,
                                height: 1.4),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _dialogField('主机地址', hostCtrl),
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
        fillColor: Colors.black.withOpacity(0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassTheme.radiusXs),
          borderSide: BorderSide(color: Colors.black.withOpacity(0.06)),
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
            const SizedBox(height: 16),
            GlassButton.outlined(
              icon: Icons.add_link_rounded,
              label: '添加 SMB / FTP / WebDAV',
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
