import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/glass_theme.dart';
import '../../widgets/glass/glass_nav_bar.dart';
import '../../widgets/glass/safe_glass.dart';
import 'breakpoints.dart';

/// iOS 27 玻璃质感 自适应导航外壳
///
/// 手机 → 玻璃底栏
/// 平板 → 毛玻璃左侧 NavigationRail
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
    if (AppBreakpoints.isTablet(context) ||
        AppBreakpoints.isDesktopOrLandscape(context)) {
      return _TabletGlassScaffold(child: child, currentRoute: currentRoute);
    }
    return _MobileGlassScaffold(child: child, currentRoute: currentRoute);
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
        // 仅首页让内容透过玻璃；其他页面加厚磨砂，
        // 避免内容从导航栏下透出来像「还有一层界面」
        translucent: currentRoute == '/home',
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

// ───────────── 平板：毛玻璃左侧导航 ─────────────

class _TabletGlassScaffold extends StatelessWidget {
  final Widget child;
  final String currentRoute;
  const _TabletGlassScaffold({required this.child, required this.currentRoute});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: GlassTheme.liquidBackground,
        ),
        child: Row(
          children: [
            // 左侧毛玻璃导航
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(GlassTheme.radiusLg),
              ),
              child: SafeBackdropFilter(
                blurSigma: 24,
                child: Container(
                  width: 88,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withOpacity(0.5),
                      Colors.white.withOpacity(0.25),
                    ],
                  ),
                  border: Border(
                    right: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.5),
                  ),
                ),
                child: Column(
                  children: [
                    // Logo
                    Padding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 16,
                        bottom: 16,
                      ),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              GlassTheme.accentPurple,
                              GlassTheme.accentTeal,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
                          boxShadow: [
                            BoxShadow(
                              color: GlassTheme.accentPurple.withOpacity(0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 24),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 导航项（前 6 个）
                    ..._NavConfig.all.take(6).map(
                          (c) => _buildTabletNavItem(
                            context,
                            config: c,
                            isActive: currentRoute == c.route,
                          ),
                        ),
                    const Spacer(),
                    // 底部设置
                    _buildTabletNavItem(
                      context,
                      config: _NavConfig.settings,
                      isActive: currentRoute == '/settings',
                    ),
                    SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
                  ],
                ),
              ),
            ),
          ),
          // 内容区
          Expanded(child: child),
        ],
        ),
      ),
    );
  }

  Widget _buildTabletNavItem(
    BuildContext context, {
    required _NavItemConfig config,
    required bool isActive,
  }) {
    return GestureDetector(
      onTap: () {
        if (!isActive) context.go(config.route);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: GlassCurves.iosDecelerate,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: isActive
              ? LinearGradient(
                  colors: [
                    GlassTheme.accentPurple.withOpacity(0.15),
                    GlassTheme.accentPurple.withOpacity(0.04),
                  ],
                )
              : null,
          borderRadius: BorderRadius.circular(GlassTheme.radiusSm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              config.icon,
              color: isActive ? GlassTheme.accentPurple : GlassTheme.textSecondary,
              size: 26,
            ),
            const SizedBox(height: 4),
            Text(
              config.label,
              style: TextStyle(
                fontSize: 11,
                color: isActive ? GlassTheme.accentPurple : GlassTheme.textSecondary,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
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
    _NavItemConfig(icon: Icons.cast_rounded, label: '投屏', route: '/cast'),
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