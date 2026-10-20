import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../pages/home/home_page.dart';
import '../../pages/player/player_page.dart';
import '../../pages/playlist/playlist_page.dart';
import '../../pages/playlist/playlist_detail_page.dart';
import '../../pages/settings/settings_page.dart';
import '../../pages/history/history_page.dart';
import '../../pages/cast/cast_page.dart';
import '../../pages/nas/nas_browser_page.dart';
import '../../pages/ai/ai_models_page.dart';

class AppRouter {
  AppRouter._();

  /// 标签页之间不做路由级过渡：真正的交叉淡化在 shell 里用
  /// AnimatedSwitcher 完成（路由级过渡在 ShellRoute 下是「直接替换」，
  /// 旧页面会瞬间消失，无法做出衔接感）。
  static NoTransitionPage<void> _tabPage(
    GoRouterState state,
    Widget child,
  ) {
    return NoTransitionPage<void>(
      key: state.pageKey,
      child: child,
    );
  }

  static final GoRouter router = GoRouter(
    initialLocation: '/home',
    navigatorKey: _rootNavigatorKey,

    /// 兜底：任何没匹配上的 location 都回首页，而不是抛 GoException。
    ///
    /// 真实场景：从手机「文件管理 / 相册」用「其他应用打开」视频时，
    /// Android 会用 `content://com.android.fileexplorer.myprovider/...`
    /// 作为 Intent 的 data，Flutter 引擎把它当成初始路由，
    /// GoRouter 找不到就崩在 `GoException: no routes for location`。
    ///
    /// 真正的打开逻辑走原生 MethodChannel（见 NativeBridgeService 的
    /// takeLaunchVideoUri / registerLaunchUriHandler），
    /// 这里只需要保证「不炸」并且落到首页。
    onException: (context, state, router) {
      debugPrint('[Router] 未匹配的 location: ${state.uri}，回首页');
      router.go('/home');
    },

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
            path: '/playlist',
            name: 'playlist',
            pageBuilder: (context, state) =>
                _tabPage(state, const PlaylistPage()),
            routes: [
              // 列表详情：先看清单再决定播哪个（防止自动分类出错）
              GoRoute(
                path: ':id',
                name: 'playlistDetail',
                pageBuilder: (context, state) => _tabPage(
                  state,
                  PlaylistDetailPage(
                    playlistId: state.pathParameters['id'] ?? '',
                  ),
                ),
              ),
            ],
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
      // 独立页面 - AI 模型管理
      GoRoute(
        path: '/ai-models',
        name: 'aiModels',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const AiModelsPage(),
      ),
    ],
  );

  static final GlobalKey<NavigatorState> _rootNavigatorKey =
      GlobalKey<NavigatorState>();
}