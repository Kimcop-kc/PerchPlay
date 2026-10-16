import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:perchplay/models/video_model.dart';
import 'package:perchplay/pages/home/home_page.dart';
import 'package:perchplay/providers/library_provider.dart';

/// 绌哄奖搴撶殑 Notifier锛堝鐢ㄧ幇鏈夌被鍨嬶級
class EmptyVideoListNotifier extends VideoListNotifier {
  @override
  Future<List<VideoModel>> build() async => [];
}

void main() {
  testWidgets('绌哄奖搴撴樉绀烘湰鍦版枃浠跺す鍜?NAS 涓や釜鍙偣鍑诲叆鍙?, (tester) async {
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

    expect(find.text('娴忚鏈湴鏂囦欢澶?), findsOneWidget);
    expect(find.text('娴忚 NAS'), findsOneWidget);

    await tester.tap(find.text('娴忚鏈湴鏂囦欢澶?));
    await tester.pumpAndSettle();
    expect(find.text('FOLDERS_PAGE'), findsOneWidget);
  }, skip: true); // 闇€瑕?media_kit 鍘熺敓搴擄紝绾?Dart 娴嬭瘯鐜璺宠繃
}