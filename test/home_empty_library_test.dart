import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/pages/home/home_page.dart';
import 'package:perchplay/providers/library_provider.dart';

/// 空影库的 Notifier（复用现有类型）
class EmptyVideoListNotifier extends VideoListNotifier {
  @override
  Future<List<VideoModel>> build() async => [];
}

void main() {
  testWidgets('空影库显示本地文件夹和 NAS 两个可点击入口', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const LibraryView(),
        ),
        GoRoute(
          path: '/folders',
          name: 'folders',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('FOLDERS_PAGE')),
          ),
        ),
        GoRoute(
          path: '/nas',
          name: 'nas',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('NAS_PAGE')),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith(EmptyVideoListNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('浏览本地文件夹'), findsOneWidget);
    expect(find.text('浏览 NAS'), findsOneWidget);

    await tester.tap(find.text('浏览本地文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('FOLDERS_PAGE'), findsOneWidget);
  }, skip: true); // 需要 media_kit 原生库，纯 Dart 测试环境跳过
}