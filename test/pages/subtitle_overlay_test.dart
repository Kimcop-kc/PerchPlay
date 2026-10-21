import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perchplay/models/subtitle_model.dart';
import 'package:perchplay/widgets/player/subtitle_overlay.dart';

/// 字幕渲染组件回归测试。
///
/// 覆盖第三阶段布局规则：
/// - 单语默认最多一行（原文换行折叠为空格，不当作双语分隔符）
/// - 双语固定两行：原文在上，译文在下
/// - 超长文本单行省略号，不因固定字符数规则意外增加行数
/// - 无译文时不显示残留译文、不把原文复制成第二行
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: Center(child: child),
        ),
      );

  testWidgets('单语模式：原文换行折叠为空格，只显示一行', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: ['第一行', '第二行'],
          fontSize: 16,
        ),
      ),
    );

    // 只有一个 Text 节点
    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    // 换行被折叠成空格
    expect(texts.first.data, '第一行 第二行');
  });

  testWidgets('双语模式：固定两行，原文在上译文在下', (tester) async {
    final entries = [
      SubtitleEntry(
        index: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        text: '译文内容',
      ),
    ];
    await tester.pumpWidget(
      wrap(
        SubtitleOverlay(
          lines: const ['原文内容'],
          entries: entries,
          activeIndex: 0,
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(texts.length, 2);
    // 第一行是原文
    expect(texts[0].data, '原文内容');
    // 第二行是译文
    expect(texts[1].data, '译文内容');
    // 译文字号小于原文（secondaryScale < 1）
    final primarySize = texts[0].style!.fontSize!;
    final secondarySize = texts[1].style!.fontSize!;
    expect(secondarySize, lessThan(primarySize));
  });

  testWidgets('无译文时：不显示残留译文，不复制原文为第二行', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: ['只有原文'],
          entries: [],
          activeIndex: -1,
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    expect(texts.first.data, '只有原文');
  });

  testWidgets('只有译文没有原文时：译文作为唯一字幕正常显示', (tester) async {
    final entries = [
      SubtitleEntry(
        index: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        text: '译文',
      ),
    ];
    await tester.pumpWidget(
      wrap(
        SubtitleOverlay(
          entries: entries,
          activeIndex: 0,
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    expect(texts.first.data, '译文');
  });

  testWidgets('空字幕：不渲染任何内容', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: [],
          entries: [],
          activeIndex: -1,
          fontSize: 16,
        ),
      ),
    );

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('超长文本：单行省略号，不意外增加行数', (tester) async {
    const longText = '这是一段非常非常长的中文字幕内容，用于测试单行省略号行为，确保不会因为固定字符数规则而意外拆成多行显示。';
    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 200,
          child: const SubtitleOverlay(
            lines: [longText],
            fontSize: 16,
          ),
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    // 单行 + 省略号
    expect(texts.first.maxLines, 1);
    expect(texts.first.overflow, TextOverflow.ellipsis);
  });

  testWidgets('内部换行符 + 连续空白折叠为单个空格', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: ['第一句\n\n第二句', '   '],
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    expect(texts.first.data, '第一句 第二句');
  });

  testWidgets('双语原文空但译文存在：只显示译文一行', (tester) async {
    final entries = [
      SubtitleEntry(
        index: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        text: '译文内容',
      ),
    ];
    await tester.pumpWidget(
      wrap(
        SubtitleOverlay(
          lines: const ['   '],
          entries: entries,
          activeIndex: 0,
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    expect(texts.first.data, '译文内容');
  });

  testWidgets('lineSpacing 控制两行间距', (tester) async {
    final entries = [
      SubtitleEntry(
        index: 0,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        text: '译文',
      ),
    ];
    await tester.pumpWidget(
      wrap(
        SubtitleOverlay(
          lines: const ['原文'],
          entries: entries,
          activeIndex: 0,
          fontSize: 16,
          lineSpacing: 10,
        ),
      ),
    );

    // 两行之间有一个 SizedBox(height: 10) 的间隔
    final spacers = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.height == 10);
    expect(spacers.length, 1);
  });

  testWidgets('内嵌第二字幕：secondaryLines 作为译文，与原文双语两行', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: ['原文'],
          secondaryLines: ['第二字幕文本'],
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(texts.length, 2);
    expect(texts[0].data, '原文');
    expect(texts[1].data, '第二字幕文本');
  });

  testWidgets('内嵌第二字幕：secondaryLines 多行折叠为一行', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          lines: ['原文'],
          secondaryLines: ['第二字幕第一行', '第二字幕第二行'],
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(texts.length, 2);
    // 第二字幕多行折叠成单行（空格连接）
    expect(texts[1].data, '第二字幕第一行 第二字幕第二行');
  });

  testWidgets('内嵌第二字幕：无原文时只显示第二字幕一行', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SubtitleOverlay(
          secondaryLines: ['只有第二字幕'],
          fontSize: 16,
        ),
      ),
    );

    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(texts.length, 1);
    expect(texts.first.data, '只有第二字幕');
  });
}
