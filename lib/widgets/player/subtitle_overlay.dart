import 'package:flutter/material.dart';

import '../../models/subtitle_model.dart';

/// 字幕覆盖层。
///
/// 两种用法：
/// - [entries] + [activeIndex]：旧的自绘浮层（第二字幕用，按条目命中显示）
/// - [lines]：统一字幕渲染（主字幕用，直接渲染 mpv 吐出的多行文本）
///
/// ## 外观完全由参数控制
/// 字号 / 黑底透明度 / 文字颜色 / 描边 / 双语次行样式都可以从设置传入，
/// 默认值等价于「白色文字 + 62% 黑底 + 轻描边」。
///
/// ## 断行策略
/// 优先用 [LayoutBuilder] 按可用宽度动态算每行字数（≈ CJK 字符宽 0.58×字号），
/// 不再硬编码 22/34 字符。仅当外部显式传入 `maxCharsPerLine > 0` 时覆盖该值。
class SubtitleOverlay extends StatefulWidget {
  final List<SubtitleEntry> entries;
  final int activeIndex;

  /// 多行字幕文本（统一渲染用，优先于 entries）。
  final List<String> lines;

  /// 字号。<= 0 表示由 [compact] 决定（保持旧的自适应行为）。
  final double fontSize;

  /// 紧凑样式：更小的内边距与圆角。
  final bool compact;

  /// 黑底不透明度（0 = 无黑底）。
  final double bgOpacity;

  /// 文字颜色。
  final Color textColor;

  /// 是否给文字加描边阴影。
  final bool stroke;

  /// 双语时译文相对原文的字号比例。
  final double secondaryScale;

  /// 双语时译文是否弱化为灰色。
  final bool secondaryDim;

  /// 每行最多显示的字数（超出按标点智能断行）。0 = 不限。
  final int maxCharsPerLine;

  const SubtitleOverlay({
    super.key,
    this.entries = const [],
    this.activeIndex = -1,
    this.lines = const [],
    this.fontSize = 0,
    this.compact = false,
    this.bgOpacity = 0.62,
    this.textColor = Colors.white,
    this.stroke = true,
    this.secondaryScale = 0.82,
    this.secondaryDim = true,
    this.maxCharsPerLine = 0,
  });

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  /// 当前显示的内容标识（用于检测"换了一句"以触发淡入）。
  String _shown = '';

  /// 断行结果缓存。
  ///
  /// 字幕浮层跟着播放进度高频重建（每秒数次），而断行只跟「文本 + 字数上限」
  /// 有关，跟时间无关。不做缓存的话每帧都要跑一遍 _smartWrap（O(n²) 的
  /// 标点扫描），长句字幕会明显拖慢帧率。
  List<_DisplayLine> _cacheLines = const [];
  String _cacheText = '';
  int _cacheMaxChars = -1;

  @override
  Widget build(BuildContext context) {
    String? text;
    if (widget.lines.isNotEmpty) {
      text = widget.lines.where((l) => l.trim().isNotEmpty).join('\n');
    } else if (widget.activeIndex >= 0 &&
        widget.activeIndex < widget.entries.length) {
      text = widget.entries[widget.activeIndex].text;
    }

    if (text == null || text.trim().isEmpty) {
      if (_shown.isNotEmpty) _shown = '';
      return const SizedBox.shrink();
    }

    // 换句才触发淡入；同一句内容不变时不做动画，避免闪烁
    if (_shown != text) _shown = text;

    final double fontSize =
        widget.fontSize > 0 ? widget.fontSize : (widget.compact ? 13.5 : 16.0);

    // 字数上限：外部显式传入 >0 则用，否则根据屏幕宽度与字号自适应。
    final int effectiveMaxChars;
    if (widget.maxCharsPerLine > 0) {
      effectiveMaxChars = widget.maxCharsPerLine;
    } else {
      // 0.58 ≈ CJK 字符平均宽/字号比；0.90 给左右留 5% 边距空间
      final screenW = MediaQuery.sizeOf(context).width;
      effectiveMaxChars =
          ((screenW * 0.90) / (fontSize * 0.58)).floor().clamp(16, 80);
    }

    // 文本或字数上限变了才重新断行
    if (_cacheText != text || _cacheMaxChars != effectiveMaxChars) {
      _cacheText = text;
      _cacheMaxChars = effectiveMaxChars;
      _cacheLines = _buildDisplayLines(
        text,
        effectiveMaxChars,
        fromMpvText: widget.lines.isNotEmpty,
      );
    }
    final displayLines = _cacheLines;
    if (displayLines.isEmpty) return const SizedBox.shrink();

    final style = TextStyle(
      color: widget.textColor,
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      height: 1.35,
      shadows: widget.stroke
          ? const [
              Shadow(
                  color: Colors.black87, blurRadius: 3, offset: Offset(1, 1)),
              Shadow(
                  color: Colors.black87, blurRadius: 3, offset: Offset(-1, -1)),
            ]
          : null,
    );

    final secondaryStyle = style.copyWith(
      fontSize: fontSize * widget.secondaryScale,
      fontWeight: FontWeight.w400,
      color: widget.secondaryDim
          ? widget.textColor.withValues(alpha: 0.72)
          : widget.textColor,
    );

    // 黑底只包住文字，不横向撑满屏幕。
    //
    // 外层 Center 让内容按自身宽度居中（不再被 Positioned 的
    // left+right 拉伸）；每行独立带小圆角黑底，面积≈文字面积。
    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        // 淡入淡出而不是滑动，避免字幕"跳"
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: Column(
          key: ValueKey(_shown),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final dl in displayLines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black
                        .withValues(alpha: widget.bgOpacity.clamp(0.0, 1.0)),
                    borderRadius: BorderRadius.circular(widget.compact ? 3 : 4),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.compact ? 5 : 7,
                      vertical: widget.compact ? 1.5 : 2.5,
                    ),
                    child: Text(
                      dl.text,
                      textAlign: TextAlign.center,
                      style: dl.isSecondary ? secondaryStyle : style,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一行待显示文本（标记是否属于译文，以便用更小的字号/灰色）。
class _DisplayLine {
  final String text;
  final bool isSecondary;
  const _DisplayLine({required this.text, required this.isSecondary});
}

/// 把原始文本拆成待显示的若干行（原文 + 译文，并按上限智能断行）。
///
/// [fromMpvText]：若为 true 则所有行属于同一种语言（mpv sub-text 不区分原文/译文）；
/// 此时 cap 1 行，且全部标记为 `isSecondary=false`。
List<_DisplayLine> _buildDisplayLines(
  String text,
  int maxChars, {
  bool fromMpvText = false,
}) {
  final rawLines = text.split('\n');
  final out = <_DisplayLine>[];

  // 单语：最多 1 行显示（默认单语字幕一行，过长加省略号）。
  if (fromMpvText) {
    for (final raw in rawLines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      final chunks = maxChars > 0 ? _smartWrap(t, maxChars) : <String>[t];
      out.addAll(chunks.map((c) => _DisplayLine(text: c, isSecondary: false)));
    }
    // 仅保留首行；有剩余内容时加省略号提醒用户当前字幕已被截断
    if (out.length > 1) {
      out.removeRange(1, out.length);
      out.first = _DisplayLine(
        text: '${out.first.text}…',
        isSecondary: false,
      );
    }
    return out;
  }

  // 双语模式（entries 路径）：固定两行——一行原文 + 一行译文。
  // 过长内容优先智能折行后取首行并加省略号，避免任意拆成四五行。
  for (var i = 0; i < rawLines.length; i++) {
    final raw = rawLines[i].trim();
    if (raw.isEmpty) continue;
    final isSecondary = i > 0;
    final chunks = maxChars > 0 ? _smartWrap(raw, maxChars) : <String>[raw];
    for (final c in chunks) {
      out.add(_DisplayLine(text: c, isSecondary: isSecondary));
    }
  }
  final prim = out.where((l) => !l.isSecondary).toList();
  final sec = out.where((l) => l.isSecondary).toList();
  out.clear();
  if (prim.isNotEmpty) {
    out.add(prim.first);
    if (prim.length > 1) {
      out.first = _DisplayLine(
        text: '${prim.first.text}…',
        isSecondary: false,
      );
    }
  }
  if (sec.isNotEmpty) {
    out.add(_DisplayLine(
      text: sec.length > 1 ? '${sec.first.text}…' : sec.first.text,
      isSecondary: true,
    ));
  }
  return out;
}

/// 按字数上限对长句做**智能断行**。
///
/// 优先在标点（，。！？；、,.!?; ）处断开；没有标点时退化为按空格，
/// 再不行才硬切，尽量不把词/短语劈开。
List<String> _smartWrap(String text, int maxChars) {
  if (maxChars <= 0 || text.length <= maxChars) return <String>[text];

  const breakers = ['，', '。', '！', '？', '；', '、', ',', '.', '!', '?', ';'];
  final out = <String>[];
  var rest = text;

  while (rest.length > maxChars) {
    // 在 [0, maxChars] 里找最后一个标点
    var cut = -1;
    for (var i = maxChars - 1; i >= 0; i--) {
      if (breakers.contains(rest[i])) {
        cut = i + 1; // 标点留在本行末尾
        break;
      }
    }
    // 没找到标点 → 找空格
    if (cut <= 0) {
      final sp = rest.lastIndexOf(' ', maxChars);
      if (sp > 0) cut = sp + 1;
    }
    // 还没有 → 硬切
    if (cut <= 0) cut = maxChars;

    out.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}
