import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../pages/home/home_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/folders/folder_browser_page.dart';
import '../../pages/playlist/playlist_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/history/history_page.dart';
import '../../pages/cast/cast_page.dart';
import '../../pages/nas/nas_browser_page.dart';

class AppRouter {
  AppRouter._();

  /// 标签页切换过渡：淡入 + 极小上浮，避免硬切显得生硬
  static CustomTransitionPage<void> _tabPage(
    GoRouterState state,
    Widget child,
  ) {
    return CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (context, animation, secondary, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  static final GoRouter router = GoRouter(
    initialLocation: '/home',
    navigatorKey: _rootNavigatorKey,
    routes: [
      // Shell 路由 — 底栏导航
      ShellRoute(
        builder: (context, state, child) => HomePage(child: child),
        routes: [
          GoRoute(
            path: '/home',
            name: 'library',
            pageBuilder: (context, state) =>
                _tabPage(state, const LibraryView()),
          ),
          GoRoute(
            path: '/folders',
            name: 'folders',
            pageBuilder: (context, state) =>
                _tabPage(state, const FolderBrowserPage()),
          ),
          GoRoute(
            path: '/playlist',
            name: 'playlist',
            pageBuilder: (context, state) =>
                _tabPage(state, const PlaylistPage()),
          ),
          GoRoute(
            path: '/history',
            name: 'history',
            pageBuilder: (context, state) =>
                _tabPage(state, const HistoryPage()),
          ),
          GoRoute(
            path: '/cast',
            name: 'cast',
            pageBuilder: (context, state) =>
                _tabPage(state, const CastPage()),
          ),
          GoRoute(
            path: '/nas',
            name: 'nas',
            pageBuilder: (context, state) =>
                _tabPage(state, const NasBrowserPage()),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (context, state) =>
                _tabPage(state, const SettingsPage()),
          ),
        ],
      ),
      // 独立页面 - 播放器
      GoRoute(
        path: '/player',
        name: 'player',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final queue = extra?['queueIds'];
          return PlayerPage(
            videoPath: extra?['videoPath'] ?? '',
            videoTitle: extra?['videoTitle'] ?? 'Unknown',
            queueIds: queue is List ? List<String>.from(queue) : null,
            startIndex: (extra?['startIndex'] as int?) ?? 0,
          );
        },
      ),
    ],
  );

  static final GlobalKey<NavigatorState> _rootNavigatorKey =
      GlobalKey<NavigatorState>();
}