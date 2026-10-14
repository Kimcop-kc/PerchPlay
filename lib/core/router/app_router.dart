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

  static final GoRouter router = GoRouter(
    initialLocation: '/home',
    routes: [
      // Shell 路由 — 底栏导航
      ShellRoute(
        builder: (context, state, child) => HomePage(child: child),
        routes: [
          GoRoute(
            path: '/home',
            name: 'library',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: LibraryView(),
            ),
          ),
          GoRoute(
            path: '/folders',
            name: 'folders',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: FolderBrowserPage(),
            ),
          ),
          GoRoute(
            path: '/playlist',
            name: 'playlist',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: PlaylistPage(),
            ),
          ),
          GoRoute(
            path: '/history',
            name: 'history',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HistoryPage(),
            ),
          ),
          GoRoute(
            path: '/cast',
            name: 'cast',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: CastPage(),
            ),
          ),
          GoRoute(
            path: '/nas',
            name: 'nas',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: NasBrowserPage(),
            ),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SettingsPage(),
            ),
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
          return PlayerPage(
            videoPath: extra?['videoPath'] ?? '',
            videoTitle: extra?['videoTitle'] ?? 'Unknown',
          );
        },
      ),
    ],
  );

  static final GlobalKey<NavigatorState> _rootNavigatorKey =
      GlobalKey<NavigatorState>();
}