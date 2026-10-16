import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/glass_theme.dart';
import '../../widgets/glass/glass_nav_bar.dart';

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

class _MobileGlassScaffold extends StatelessWidget {
  final Widget child;
  final String currentRoute;
  const _MobileGlassScaffold({required this.child, required this.currentRoute});

  @override
  Widget build(BuildContext context) {
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
                      GlassTheme.accentPurple.withOpacity(0.28),
                      GlassTheme.accentPurple.withOpacity(0.08),
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
                      GlassTheme.accentTeal.withOpacity(0.22),
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
                      GlassTheme.accentPink.withOpacity(0.14),
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
                      GlassTheme.accentTeal.withOpacity(0.20),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
      bottomNavigationBar: GlassNavBar(
        currentRoute: currentRoute,
        items: _navItems(context),
      ),
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
    _NavItemConfig(icon: Icons.folder_rounded, label: '文件夹', route: '/folders'),
    _NavItemConfig(icon: Icons.playlist_play_rounded, label: '列表', route: '/playlist'),
    _NavItemConfig(icon: Icons.history_rounded, label: '历史', route: '/history'),
    // 投屏不再占底栏：改为在视频播放页内直接搜索/连接设备
    _NavItemConfig(icon: Icons.dns_rounded, label: 'NAS', route: '/nas'),
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