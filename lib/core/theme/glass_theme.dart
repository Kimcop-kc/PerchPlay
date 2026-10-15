import 'dart:ui';
import 'package:flutter/material.dart';

/// iOS 27 玻璃质感主题
///
/// 设计语言：
///   - 大面积 BackdropFilter 模糊（毛玻璃）
///   - 微妙的彩色着色（tinted glass）
///   - 大圆角（20-28px）
///   - 柔和阴影 + 光泽高光
///   - Spring 弹性动画曲

class GlassTheme {
  GlassTheme._();

  // ────────── 基础色板（浅色玻璃底） ──────────
  static const bg = Color(0xFFF2F2F7);          // iOS 浅灰底
  static const bgRaised = Color(0xFFE5E5EA);    // 抬高一层
  static const accentPurple = Color(0xFF6E5CE7); // 主紫
  static const accentTeal = Color(0xFF00B8A9);   // 主青
  static const accentPink = Color(0xFFFF4D6D);   // 点缀粉
  static const surfaceWhite = Color(0xFFFFFFFF);
  // 浅色主题下文字颜色
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF3C3C43);
  static const textTertiary = Color(0xFF8E8E93);

  // ────────── 玻璃透明度预设 ──────────
  static const glassLight = 0.06;   // 极透
  static const glassStandard = 0.10; // 标准毛玻璃
  static const glassHeavy = 0.16;   // 厚玻璃
  static const glassSheet = 0.20;   // Sheet 面板

  // ────────── 彩色玻璃 ──────────
  static const tintPurple = Color(0x189B7EF0);
  static const tintTeal = Color(0x1445E0D0);
  static const tintPink = Color(0x14FF6B9D);
  static const tintWhite = Color(0x0AFFFFFF);

  /// 底部玻璃导航栏遮挡内容的高度（不含系统手势条）。
  /// = 导航栏轨道高(64+2) + 顶部 padding(6) = 72。
  /// 各滚动页面在底部预留此高度，避免最后一项被导航栏遮住。
  static const double navBarOverlay = 72.0;

  // ────────── 圆角 ──────────
  static const radiusXs = 10.0;
  static const radiusSm = 14.0;
  static const radiusMd = 20.0;
  static const radiusLg = 24.0;
  static const radiusXl = 28.0;
  static const radius2xl = 32.0;
  static const radiusFull = 999.0;

  // ────────── 阴影 ──────────
  static List<BoxShadow> glassShadow(Color tint) => [
        BoxShadow(
          color: tint.withOpacity(0.12),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: tint.withOpacity(0.04),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ];

  static List<BoxShadow> softShadow() => [
        BoxShadow(
          color: Colors.black.withOpacity(0.3),
          blurRadius: 30,
          offset: const Offset(0, 10),
        ),
      ];

  // ────────── 渐变 ──────────
  static const LinearGradient sheenPurple = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x229B7EF0),
      Color(0x0845E0D0),
    ],
  );

  static const LinearGradient sheenTeal = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x1845E0D0),
      Color(0x089B7EF0),
    ],
  );

  static const LinearGradient sheenCard = LinearGradient(
    begin: Alignment(-1, -0.5),
    end: Alignment(1, 1),
    colors: [
      Color(0x18FFFFFF),
      Color(0x04FFFFFF),
    ],
    stops: [0.0, 0.7],
  );

  /// 顶部光泽高光（模拟玻璃反光）——液态玻璃的强烈折射高光
  static const LinearGradient topGlare = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.center,
    colors: [
      Color(0x40FFFFFF),
      Color(0x08FFFFFF),
      Color(0x00FFFFFF),
    ],
    stops: [0.0, 0.4, 0.7],
  );

  /// 液态玻璃底部反光
  static const LinearGradient bottomGlare = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.center,
    colors: [
      Color(0x14FFFFFF),
      Color(0x00FFFFFF),
    ],
  );

  /// 液态玻璃斜向折射光带
  static const LinearGradient liquidSheen = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x26FFFFFF),
      Color(0x05FFFFFF),
      Color(0x18FFFFFF),
    ],
    stops: [0.0, 0.5, 1.0],
  );

  /// 液态玻璃页面背景：柔和的彩色光斑（iOS 26 Liquid Glass 标志）
  static const LinearGradient liquidBackground = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFF6F4FC),  // 顶部偏紫白
      Color(0xFFF2F2F7),  // 中间浅灰
      Color(0xFFEFF9F8),  // 底部偏青白
    ],
    stops: [0.0, 0.5, 1.0],
  );

  // ────────── 玻璃背景 Painter ──────────
  static BoxDecoration glassDecoration({
    double opacity = glassStandard,
    Color tint = Colors.transparent,
    double radius = radiusMd,
    bool showBorder = true,
    bool showShadow = false,
    Color shadowTint = Colors.black,
  }) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: showBorder
          ? Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 0.5,
            )
          : null,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(opacity + 0.02),
          Colors.white.withOpacity(opacity),
        ],
      ),
      boxShadow: showShadow ? glassShadow(shadowTint) : null,
    );
  }
}

// ═══════════════════════════════════════════
// Spring 动画曲线（iOS 27 弹簧参数）
// ═══════════════════════════════════════════

class GlassCurves {
  GlassCurves._();

  /// iOS 27 默认弹性动画: 有阻尼的弹簧
  static final SpringDescription springSmooth = const SpringDescription(
    mass: 1,
    stiffness: 200,
    damping: 22,
  );

  /// 回弹明显的弹性
  static final SpringDescription springBouncy = const SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 14,
  );

  /// 轻微弹性（卡片悬浮）
  static final SpringDescription springSubtle = const SpringDescription(
    mass: 1,
    stiffness: 300,
    damping: 26,
  );

  /// 拟物化 deceleration（iOS scroll）
  static const Curve iosDecelerate = Cubic(0.16, 1, 0.3, 1);

  /// 交错入场 stagger builder
  static CurveTween staggerCurve(int index, {int total = 5}) {
    final start = (index / total) * 0.25;
    final end = (start + 0.35).clamp(0.0, 1.0);
    return CurveTween(curve: Interval(start, end, curve: Curves.easeOutCubic));
  }
}

// ═══════════════════════════════════════════
// 入场动画辅助
// ═══════════════════════════════════════════

class GlassAnimations {
  GlassAnimations._();

  /// 淡入 + 上浮动画
  static Widget fadeSlideUp({
    required AnimationController controller,
    required int index,
    Duration duration = const Duration(milliseconds: 600),
    required Widget child,
  }) {
    final t = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOut,
    );
    return GlassAnimatedBuilder(
      listenable: t,
      builder: (_, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - t.value)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  /// 缩放弹出
  static Widget scaleIn({
    required AnimationController controller,
    required int index,
    required Widget child,
  }) {
    final t = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOut,
    );
    return GlassAnimatedBuilder(
      listenable: t,
      builder: (_, child) => Opacity(
        opacity: t.value,
        child: Transform.scale(
          scale: 0.88 + 0.12 * t.value,
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 自定义动画构建器（避免与 Flutter AnimatedBuilder 冲突）
class GlassAnimatedBuilder extends AnimatedWidget {
  final Widget? child;
  final Widget Function(BuildContext, Widget?) builder;
  const GlassAnimatedBuilder({
    super.key,
    required super.listenable,
    required this.builder,
    this.child,
  });

  @override
  Widget build(BuildContext context) => builder(context, child);
}
