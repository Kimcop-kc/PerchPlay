import 'package:flutter/material.dart';

import '../../models/subtitle_model.dart';

/// 字幕覆盖层（统一渲染入口）。
///
/// 三种输入，按优先级：
/// 1. [lines] 与 [entries]/[activeIndex] **同时有效** → 双语：
///    原文（[lines] 合并为一行）在上，译文（命中的 [entries] 条目）在下。
/// 2. 仅 [lines] → 单语主字幕。
/// 3. 仅 [entries] + [activeIndex] → 单语第二字幕。
///
/// ## 布局规则
/// - 单语：最多 1 行；原文自带的换行符折叠为空格（不当作双语分隔符）。
/// - 双语：固定 2 行 —— 原文一行、译文一行，共用一个 Column 容器、
///   统一宽度与对齐；行间距由 [lineSpacing] 控制。
/// - 超长文本：优先自适应缩小字号；缩到下限仍放不下则单行省略号，
///   绝不因固定字符数规则意外增加行数。
///
/// ## 样式
/// 字号 / 黑底透明度 / 文字颜色 / 描边 / 双语次行样式全部由外部传入，
/// 默认值等价于「白色文字 + 62% 黑底 + 轻描边」。
class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleEntry> entries;
  final int activeIndex;

  /// 多行字幕文本（mpv `sub-text` 或主字幕行）。
  final List<String> lines;

  /// 第二字幕文本（mpv `secondary-sub-text`，内嵌第二字幕轨）。
  ///
  /// 与 [entries]/[activeIndex] 互斥：内嵌第二字幕的文本由 mpv 直接推送，
  /// 无需 Dart 侧解析匹配。优先于 [entries]。
  final List<String> secondaryLines;

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

  /// 双语文两行之间的额外间距（逻辑像素）。
  final double lineSpacing;

  /// 自适应字号下限（相对 [fontSize] 的比例，0~1）。
  final double minFontScale;

  const SubtitleOverlay({
    super.key,
    this.entries = const [],
    this.activeIndex = -1,
    this.lines = const [],
    this.secondaryLines = const [],
    this.fontSize = 0,
    this.compact = false,
    this.bgOpacity = 0.62,
    this.textColor = Colors.white,
    this.stroke = true,
    this.secondaryScale = 0.82,
    this.secondaryDim = true,
    this.lineSpacing = 3,
    this.minFontScale = 0.72,
  });

  @override
  Widget build(BuildContext context) {
    // ── 确定原文与译文文本 ──
    final String? primaryText = _normalizePrimary();
    final String? secondaryText = _normalizeSecondary();

    if (primaryText == null && secondaryText == null) {
      return const SizedBox.shrink();
    }

    final double baseFontSize =
        fontSize > 0 ? fontSize : (compact ? 13.5 : 16.0);

    // 双语（原文 + 译文同时存在）时译文用缩小样式；
    // 只有译文（没有原文）时，译文就是唯一字幕，用正常样式。
    final bool bilingual = primaryText != null && secondaryText != null;
    final primaryStyle = _buildStyle(baseFontSize, isSecondary: false);
    final secondaryStyle = _buildStyle(baseFontSize, isSecondary: bilingual);

    // 外层 Center 让内容按自身宽度居中（不被 Positioned 的 left+right 拉伸）。
    // 黑底只包住文字，不横向撑满屏幕。
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (primaryText != null)
                _buildLine(context, primaryText, primaryStyle, maxWidth),
              if (bilingual) SizedBox(height: lineSpacing),
              if (secondaryText != null)
                _buildLine(context, secondaryText, secondaryStyle, maxWidth),
            ],
          );
        },
      ),
    );
  }

  /// 主字幕文本：合并 [lines] 的非空行，内部换行折叠为空格。
  String? _normalizePrimary() {
    if (lines.isEmpty) return null;
    final parts =
        lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.join(' ');
  }

  /// 译文文本：优先用 [secondaryLines]（内嵌第二字幕的 mpv 文本），
  /// 否则取命中的 [entries] 条目文本（外挂第二字幕）。
  String? _normalizeSecondary() {
    if (secondaryLines.isNotEmpty) {
      final parts = secondaryLines
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) return parts.join(' ');
    }
    if (activeIndex < 0 || activeIndex >= entries.length) return null;
    final t = entries[activeIndex].text.trim();
    return t.isEmpty ? null : t;
  }

  TextStyle _buildStyle(double size, {required bool isSecondary}) {
    final base = TextStyle(
      color: textColor,
      fontSize: isSecondary ? size * secondaryScale : size,
      fontWeight: isSecondary ? FontWeight.w400 : FontWeight.w500,
      height: 1.35,
      shadows: stroke
          ? const [
              Shadow(
                color: Colors.black87,
                blurRadius: 3,
                offset: Offset(1, 1),
              ),
              Shadow(
                color: Colors.black87,
                blurRadius: 3,
                offset: Offset(-1, -1),
              ),
            ]
          : null,
    );
    if (!isSecondary) return base;
    return base.copyWith(
      color: secondaryDim ? textColor.withValues(alpha: 0.72) : textColor,
    );
  }

  /// 渲染一行：自适应字号 + 单行省略号。
  Widget _buildLine(
    BuildContext context,
    String text,
    TextStyle baseStyle,
    double maxWidth,
  ) {
    // 把文本内部的换行/连续空白折叠成单个空格（字幕文本不应含排版换行）
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return const SizedBox.shrink();

    // 字号基准直接取 baseStyle 的字号（译文已被 secondaryScale 缩小过）
    final double baseFontSize = baseStyle.fontSize ?? 16.0;
    final double minSize = baseFontSize * minFontScale;
    final double fittedSize = _fitSingleLine(
      normalized,
      baseStyle,
      baseFontSize,
      minSize,
      maxWidth,
    );

    final style = baseStyle.copyWith(fontSize: fittedSize);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: bgOpacity.clamp(0.0, 1.0)),
        borderRadius: BorderRadius.circular(compact ? 3 : 4),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 5 : 7,
          vertical: compact ? 1.5 : 2.5,
        ),
        child: Text(
          normalized,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }

  /// 计算能在一行内放下 [text] 的最大字号（在 [base] 与 [min] 之间二分）。
  ///
  /// 放得下返回 [base]；放不下按比例缩小，缩到 [min] 仍放不下就返回 [min]，
  /// 由 Text 的 `overflow: ellipsis` 做最终省略。
  double _fitSingleLine(
    String text,
    TextStyle baseStyle,
    double base,
    double min,
    double maxWidth,
  ) {
    if (maxWidth <= 0) return base;

    bool fits(double size) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: baseStyle.copyWith(fontSize: size)),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      return painter.width <= maxWidth;
    }

    if (fits(base)) return base;

    var lo = min;
    var hi = base;
    var best = min;
    for (var i = 0; i < 8; i++) {
      final mid = (lo + hi) / 2;
      if (fits(mid)) {
        best = mid;
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return best;
  }
}
