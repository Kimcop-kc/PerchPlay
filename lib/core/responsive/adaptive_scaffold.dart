import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/glass_theme.dart';
import '../../providers/player_provider.dart';
import '../../widgets/glass/glass_nav_bar.dart';
import '../../widgets/player/mini_player.dart';

/// iOS 27 玻璃质感 自适应导航外壳
///
/// 始终使用玻璃底栏（与手机一致），不做平板 NavigationRail 切换。
class AdaptiveScaffold extends StatelessWidget {
  final Widget child;
  final String currentRoute;

  const AdaptiveScaffold({
    super.key,
    required this.child,
    required this.currentRoute,
  });

  @override
  Widget build(BuildContext context) {
    return _MobileGlassScaffold(
        currentRoute: currentRoute, child: child);
  }
}

// ───────────── 手机：玻璃底栏 ─────────────

class _MobileGlassScaffold extends ConsumerWidget {
  final Widget child;
  final String currentRoute;
  const _MobileGlassScaffold({required this.child, required this.currentRoute});

  /// 玻璃导航栏的固定高度（GlassNavBar 默认 height: 64 + 上下 padding 8）
  static const double _navBarHeight = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: GlassTheme.liquidBackground,
        ),
        child: Stack(
          children: [
            // 液态玻璃彩色光斑（多重叠加，更强折射感）
            Positioned(
              top: -100,
              left: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      GlassTheme.accentPurple.withValues(alpha: 0.28),
                      GlassTheme.accentPurple.withValues(alpha: 0.08),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 180,
              right: -100,
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      GlassTheme.accentTeal.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -80,
              left: 40,
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      GlassTheme.accentPink.withValues(alpha: 0.14),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 120,
              right: -70,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      GlassTheme.accentTeal.withValues(alpha: 0.20),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            _buildContent(context, ref),
            _buildMiniPlayer(context, ref),
          ],
        ),
      ),
      bottomNavigationBar: GlassNavBar(
        currentRoute: currentRoute,
        items: _navItems(context),
      ),
    );
  }

  /// 页面本体：小窗显示时补一段底部留白，否则小窗会盖住各页最后一行内容。
  ///
  /// 只补 [MiniPlayer.height]（小窗实际占用的高度），导航栏那段留白由
  /// 各页自己已经有（首页 96），补两遍会让底部空一大块。
  Widget _buildContent(BuildContext context, WidgetRef ref) {
    return Consumer(
      builder: (context, ref, _) {
        final hasMini = ref.watch(playerProvider.select(
            (p) => p.currentVideo != null && p.videoController != null));
        if (!hasMini) return child;
        return Padding(
          padding: const EdgeInsets.only(bottom: MiniPlayer.height),
          child: child,
        );
      },
    );
  }

  /// 后台播放小窗：浮在导航栏之上，**所有 tab 共用**。
  ///
  /// 以前它画在首页内部，切到文件夹/列表/历史/NAS/设置就消失了，
  /// 用户会以为"后台播放被中断了"。
  Widget _buildMiniPlayer(BuildContext context, WidgetRef ref) {
    return Consumer(
      builder: (context, ref, _) {
        // 只订阅「有没有小窗」这个布尔量：播放位置每秒都在变，
        // 直接 watch 整个 PlayerState 会让整个外壳（含当前页面）跟着重建
        final hasMini = ref.watch(playerProvider.select(
            (p) => p.currentVideo != null && p.videoController != null));
        if (!hasMini) return const SizedBox.shrink();
        final video = ref.read(playerProvider).currentVideo!;
        // 用 viewPadding 而不是 padding：键盘弹出时 padding.bottom 会变 0，
        // 导航栏本身也贴到屏幕底部，小窗要跟着它一起走，不能浮在半空
        final bottom = _navBarHeight + MediaQuery.of(context).viewPadding.bottom;
        return Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: MiniPlayer(
            video: video,
            playerState: ref.read(playerProvider),
            onTap: () => context.pushNamed('player', extra: {
              'videoPath': video.path,
              'videoTitle': video.name,
            }),
            onClose: () => ref.read(playerProvider.notifier).stop(),
          ),
        );
      },
    );
  }

  List<NavBarItem> _navItems(BuildContext context) {
    return _NavConfig.all.map((c) {
      return NavBarItem(
        icon: c.icon,
        label: c.label,
        route: c.route,
        onTap: () {
          if (currentRoute != c.route) context.go(c.route);
        },
      );
    }).toList();
  }
}

// ───────────── 导航配置 ─────────────

class _NavConfig {
  _NavConfig._();

  static const List<_NavItemConfig> all = [
    _NavItemConfig(icon: Icons.home_rounded, label: '首页', route: '/home'),
    // 不再有「文件夹」tab：首页标题行的「全部视频 / 文件夹」切换器
    // 已经能进文件夹视图，底栏再放一个就是重复入口。
    _NavItemConfig(icon: Icons.playlist_play_rounded, label: '列表', route: '/playlist'),
    _NavItemConfig(icon: Icons.history_rounded, label: '历史', route: '/history'),
    // NAS 与云盘合并为「存储」：两者都是远程媒体库，
    // 分开会让底栏到 7 项，手机每项只剩约 50dp、文字挤在一起。
    _NavItemConfig(icon: Icons.dns_rounded, label: '存储', route: '/nas'),
    settings,
  ];

  static const settings = _NavItemConfig(
    icon: Icons.settings_rounded,
    label: '设置',
    route: '/settings',
  );
}

class _NavItemConfig {
  final IconData icon;
  final String label;
  final String route;
  const _NavItemConfig({
    required this.icon,
    required this.label,
    required this.route,
  });
}