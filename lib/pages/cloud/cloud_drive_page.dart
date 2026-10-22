import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/glass_theme.dart';
import '../../models/cloud_drive_model.dart';
import '../../services/cloud/cloud_drive_service.dart';
import '../../widgets/common/app_page_header.dart';
import '../../widgets/glass/glass_button.dart';
import '../../widgets/glass/glass_panel.dart';
import 'cloud_login_page.dart';

/// 云盘页：管理已登录的云盘账号 + 浏览文件。
///
/// 两种用法：
///  - 独立路由（`/cloud`）：自己带 Scaffold 与 header
///  - 嵌入「网络存储」页（[embedded] = true）：只出内容，header/Scaffold
///    交给外层，避免两套顶栏叠加
class CloudDrivePage extends ConsumerStatefulWidget {
  /// 嵌入模式：不画 Scaffold 与自己的 header。
  final bool embedded;

  const CloudDrivePage({super.key, this.embedded = false});

  @override
  ConsumerState<CloudDrivePage> createState() => _CloudDrivePageState();
}

/// 嵌入用的别名（语义更清楚）。
class CloudDriveView extends CloudDrivePage {
  const CloudDriveView({super.key}) : super(embedded: true);
}

class _CloudDrivePageState extends ConsumerState<CloudDrivePage> {
  final _svc = CloudDriveService.instance;

  bool _loading = true;
  String? _error;

  /// 当前浏览的账号（null = 显示账号列表）
  CloudDriveAccount? _current;

  /// 当前目录 id / 路径
  String _dirId = '';
  String _dirPath = '/';
  final List<(String id, String path)> _stack = [];

  List<CloudFileItem> _items = [];
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    // 注意：**不要**在这里调 _svc.dispose()。
    //
    // CloudDriveService 是全局单例，而 CloudDriveView 现在是「网络存储」
    // 页里的一段视图——用户切到云盘又切回 NAS 时，这个 widget 会被销毁，
    // 如果在这里关掉全局服务的 HttpClient，下次切回云盘就得重新 connect，
    // 多一次网络往返，切换体验很差。
    //
    // 全局单例的释放交给真正的退出时机（App 销毁），而不是某个视图销毁。
    super.dispose();
  }

  Future<void> _init() async {
    await _svc.ensureLoaded();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final content = CustomScrollView(
      slivers: [
        // 嵌入模式下 header 由外层（网络存储页）提供，这里不再画大标题。
        // 但进入子目录后需要「返回上一级」入口，否则用户会卡在子目录里，
        // 所以 embedded 模式渲染一条精简导航行（只有返回 + 当前路径）。
        if (widget.embedded)
          SliverToBoxAdapter(
            child: _buildEmbeddedNavBar(),
          )
        else
          AppPageHeader(
            title: '云盘',
            subtitle: _current == null
                ? '夸克 / 115 / 百度 / 阿里云盘'
                : _current!.type.displayName,
            leading: _current == null
                ? null
                : GestureDetector(
                    onTap: _goUp,
                    child: const Icon(Icons.arrow_back_ios,
                        size: 20, color: GlassTheme.textSecondary),
                  ),
            trailing: _current != null
                ? GlassButton.outlined(
                    icon: Icons.refresh_rounded,
                    label: '刷新',
                    height: 36,
                    foregroundColor: GlassTheme.textSecondary,
                    onTap: _reload,
                  )
                : null,
          ),
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: CircularProgressIndicator(color: GlassTheme.accentPurple),
            ),
          )
        else if (_error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildError(_error!),
          )
        else if (_current == null)
          _buildAccountList()
        else
          _buildFileList(),
      ],
    );

    // 嵌入模式：外层已经有 Scaffold/SafeArea，这里只出内容
    if (widget.embedded) return content;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: content,
      ),
    );
  }

  /// 嵌入模式下的精简导航条：只保留「返回上一级 + 当前路径 + 刷新」。
  ///
  /// 大标题由外层「网络存储」页提供，这里不能重复画；但进入子目录后
  /// 没有返回入口会让用户卡死，所以保留这一条。
  Widget _buildEmbeddedNavBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Row(
        children: [
          if (_current != null) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded,
                  color: GlassTheme.textPrimary),
              onPressed: _goUp,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              _current == null ? '选择账号后浏览文件' : _dirPath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: GlassTheme.textSecondary, fontSize: 13),
            ),
          ),
          if (_current != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  size: 20, color: GlassTheme.textTertiary),
              onPressed: _reload,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
    );
  }

  // ──────────── 账号列表 ────────────

  Widget _buildAccountList() {
    final accounts = _svc.accounts;
    if (accounts.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_outlined,
                    size: 48, color: GlassTheme.textTertiary),
                const SizedBox(height: 14),
                const Text('还没有添加云盘',
                    style: TextStyle(
                        color: GlassTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  '支持夸克、115、百度、阿里云盘\n添加后可直接浏览并播放云盘里的视频',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: GlassTheme.textTertiary,
                      fontSize: 12,
                      height: 1.6),
                ),
                const SizedBox(height: 20),
                GlassButton.filled(
                  icon: Icons.add_rounded,
                  label: '添加云盘',
                  onTap: _showAddSheet,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      sliver: SliverList.builder(
        itemCount: accounts.length + 1, // +1 为底部「添加」按钮
        itemBuilder: (context, i) {
          // 底部「添加」按钮
          if (i == accounts.length) {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: GlassButton.outlined(
                icon: Icons.add_rounded,
                label: '添加云盘',
                width: double.infinity,
                height: 44,
                foregroundColor: GlassTheme.accentPurple,
                onTap: _showAddSheet,
              ),
            );
          }
          final acc = accounts[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassPanel(
              radius: GlassTheme.radiusMd,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(_iconFor(acc.type),
                      size: 26, color: GlassTheme.accentPurple),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(acc.name,
                            style: const TextStyle(
                                color: GlassTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(
                          acc.nickname.isNotEmpty
                              ? acc.nickname
                              : acc.type.displayName,
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 20, color: GlassTheme.textTertiary),
                    onPressed: () => _removeAccount(acc),
                  ),
                  GlassButton.outlined(
                    label: '打开',
                    height: 34,
                    foregroundColor: GlassTheme.accentTeal,
                    onTap: () => _openAccount(acc),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ──────────── 文件列表 ────────────

  Widget _buildFileList() {
    if (_items.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text('这个文件夹是空的',
              style: TextStyle(color: GlassTheme.textTertiary, fontSize: 14)),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
      sliver: SliverList.builder(
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final f = _items[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassPanel(
              radius: GlassTheme.radiusSm,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: InkWell(
                onTap: () => _onTapItem(f),
                child: Row(
                  children: [
                    Icon(
                      f.isDirectory
                          ? Icons.folder_rounded
                          : (f.isVideo
                              ? Icons.movie_rounded
                              : Icons.insert_drive_file_rounded),
                      size: 22,
                      color: f.isDirectory
                          ? GlassTheme.accentPurple
                          : GlassTheme.textTertiary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: f.isDirectory || f.isVideo
                              ? GlassTheme.textPrimary
                              : GlassTheme.textTertiary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (!f.isDirectory)
                      Text(_fmtSize(f.size),
                          style: const TextStyle(
                              color: GlassTheme.textTertiary, fontSize: 11)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildError(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 44, color: GlassTheme.accentPink),
            const SizedBox(height: 12),
            Text(msg,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: GlassTheme.textSecondary,
                    fontSize: 13,
                    height: 1.5)),
            const SizedBox(height: 16),
            GlassButton.outlined(label: '重试', onTap: _reload),
          ],
        ),
      ),
    );
  }

  // ──────────── 动作 ────────────

  Future<void> _showAddSheet() async {
    final type = await showModalBottomSheet<CloudDriveType>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: GlassTheme.bg,
          borderRadius: BorderRadius.circular(GlassTheme.radiusLg),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择云盘',
                  style: TextStyle(
                      color: GlassTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              for (final t in CloudDriveType.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_iconFor(t), color: GlassTheme.accentPurple),
                  title: Text(t.displayName,
                      style: const TextStyle(
                          color: GlassTheme.textPrimary, fontSize: 15)),
                  subtitle: Text(
                    t.usesToken ? '需登录网页获取 token' : '网页登录后自动保存',
                    style: const TextStyle(
                        color: GlassTheme.textTertiary, fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(ctx, t),
                ),
            ],
          ),
        ),
      ),
    );
    if (type == null || !mounted) return;

    final acc = await Navigator.of(context).push<CloudDriveAccount>(
      MaterialPageRoute(
        builder: (_) => CloudLoginPage(type: type),
      ),
    );
    if (acc == null || !mounted) return;

    // 保存并测试
    setState(() => _loading = true);
    await _svc.addAccount(acc);
    final nick = await _svc.connect(acc);
    if (nick != null) {
      await _svc.updateAccount(acc.copyWith(nickname: nick));
    }
    if (!mounted) return;
    setState(() => _loading = false);

    if (nick == null) {
      _snack('已保存，但连接测试失败。请确认已完成登录后重试。');
    } else {
      _snack('已添加：$nick');
    }
  }

  Future<void> _removeAccount(CloudDriveAccount acc) async {
    await _svc.removeAccount(acc.id);
    if (mounted) setState(() {});
  }

  Future<void> _openAccount(CloudDriveAccount acc) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final nick = await _svc.connect(acc);
    if (!mounted) return;
    if (nick == null) {
      setState(() {
        _loading = false;
        _error = '连接失败。可能是登录已过期，删掉重新添加即可。';
      });
      return;
    }
    // 各家根目录 id 不同
    _dirId = switch (acc.type) {
      CloudDriveType.quark => '0',
      CloudDriveType.pan115 => '0',
      CloudDriveType.baidu => '/',
      CloudDriveType.aliyun => 'root',
    };
    _dirPath = '/';
    _stack.clear();
    _current = acc;
    await _loadDir();
  }

  Future<void> _loadDir() async {
    final acc = _current;
    if (acc == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final list =
        await _svc.listDirectory(acc.id, _dirId, parentPath: _dirPath);
    if (!mounted) return;
    if (list == null) {
      setState(() {
        _loading = false;
        _error = '读取目录失败。登录可能已过期。';
      });
      return;
    }
    // 只显示文件夹和视频，其它类型对播放器没意义
    final filtered = list.where((e) => e.isDirectory || e.isVideo).toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    setState(() {
      _items = filtered;
      _loading = false;
    });
  }

  Future<void> _reload() async {
    if (_current == null) {
      setState(() => _loading = false);
      return;
    }
    // 之前列目录失败（多半是 Cookie/连接失效）时，重试要先重建连接，
    // 否则旧的失效 client 会一直失败，点「重试」永远好不了。
    if (_error != null) {
      final ok = await _svc.connect(_current!);
      if (ok == null) {
        setState(() {
          _loading = false;
          _error = '连接失败。登录可能已过期，请返回后重新登录。';
        });
        return;
      }
    }
    await _loadDir();
  }

  void _goUp() {
    if (_stack.isEmpty) {
      // 已经在根：回到账号列表
      setState(() {
        _current = null;
        _items = [];
      });
      return;
    }
    final prev = _stack.removeLast();
    _dirId = prev.$1;
    _dirPath = prev.$2;
    _loadDir();
  }

  Future<void> _onTapItem(CloudFileItem f) async {
    if (f.isDirectory) {
      _stack.add((_dirId, _dirPath));
      _dirId = f.id;
      _dirPath = f.path;
      await _loadDir();
      return;
    }
    if (!f.isVideo) return;

    final acc = _current;
    if (acc == null) return;

    if (_opening) return;
    setState(() => _opening = true);
    // 取直链可能要 1~3 秒（尤其百度/阿里），给用户一个明确反馈，
    // 否则点了没反应会以为卡死。
    _snack('正在获取播放地址…');
    try {
      final url = await _svc.getDownloadUrl(acc.id, f.id);
      if (!mounted) return;
      if (url == null || url.isEmpty) {
        _snack('取播放地址失败。链接可能已过期，刷新后再试。');
        return;
      }
      if (!mounted) return;
      await context.pushNamed('player', extra: {
        'videoPath': url,
        'videoTitle': f.name,
      });
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  IconData _iconFor(CloudDriveType t) {
    switch (t) {
      case CloudDriveType.quark:
        return Icons.cloud_rounded;
      case CloudDriveType.pan115:
        return Icons.cloud_queue_rounded;
      case CloudDriveType.baidu:
        return Icons.cloud_circle_rounded;
      case CloudDriveType.aliyun:
        return Icons.cloud_done_rounded;
    }
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
  }
}
