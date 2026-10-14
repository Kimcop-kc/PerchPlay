import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/device_info_service.dart';
import '../services/ipad_optimization_service.dart';

/// 键盘 & 触控板快捷键处理
/// 在播放器页面包裹，处理 iPad 妙控键盘 + Apple Pencil 悬停
class KeyboardShortcutHandler extends ConsumerStatefulWidget {
  final Widget child;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSeekForward;
  final VoidCallback? onSeekBackward;
  final VoidCallback? onVolumeUp;
  final VoidCallback? onVolumeDown;
  final VoidCallback? onNextTrack;
  final VoidCallback? onPreviousTrack;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onToggleSubtitles;
  final VoidCallback? onToggleSpeed;
  final VoidCallback? onPiP;
  final VoidCallback? onToggleMute;
  final void Function(double position)? onSeekFraction;
  final VoidCallback? onExit;

  const KeyboardShortcutHandler({
    super.key,
    required this.child,
    this.onPlayPause,
    this.onSeekForward,
    this.onSeekBackward,
    this.onVolumeUp,
    this.onVolumeDown,
    this.onNextTrack,
    this.onPreviousTrack,
    this.onToggleFullscreen,
    this.onToggleSubtitles,
    this.onToggleSpeed,
    this.onPiP,
    this.onToggleMute,
    this.onSeekFraction,
    this.onExit,
  });

  @override
  ConsumerState<KeyboardShortcutHandler> createState() =>
      _KeyboardShortcutHandlerState();
}

class _KeyboardShortcutHandlerState
    extends ConsumerState<KeyboardShortcutHandler> {
  final _device = DeviceInfoService.instance;
  final _iPadService = IPadOptimizationService.instance;

  // Apple Pencil 悬停预览状态
  Offset? _pencilHoverPosition;
  bool _showPencilPreview = false;

  @override
  Widget build(BuildContext context) {
    // 仅在 iPad 上启用键盘快捷键
    if (!_device.isIPad) return widget.child;

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            // Apple Pencil 悬停预览条
            if (_showPencilPreview &&
                _iPadService.supportApplePencilHover)
              _buildPencilHoverPreview(),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isRepeat = event is KeyRepeatEvent;

    // 空格 → 播放/暂停
    if (key == LogicalKeyboardKey.space) {
      widget.onPlayPause?.call();
      return KeyEventResult.handled;
    }
    // 方向键
    if (key == LogicalKeyboardKey.arrowLeft) {
      widget.onSeekBackward?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.onSeekForward?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onVolumeUp?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onVolumeDown?.call();
      return KeyEventResult.handled;
    }
    // [ ] → 上一集 / 下一集
    if (key == LogicalKeyboardKey.bracketLeft) {
      widget.onPreviousTrack?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketRight) {
      widget.onNextTrack?.call();
      return KeyEventResult.handled;
    }
    // F → 全屏
    if (key == LogicalKeyboardKey.keyF) {
      widget.onToggleFullscreen?.call();
      return KeyEventResult.handled;
    }
    // S → 字幕
    if (key == LogicalKeyboardKey.keyS) {
      widget.onToggleSubtitles?.call();
      return KeyEventResult.handled;
    }
    // R → 倍速
    if (key == LogicalKeyboardKey.keyR) {
      widget.onToggleSpeed?.call();
      return KeyEventResult.handled;
    }
    // P → 画中画
    if (key == LogicalKeyboardKey.keyP) {
      widget.onPiP?.call();
      return KeyEventResult.handled;
    }
    // M → 静音
    if (key == LogicalKeyboardKey.keyM) {
      widget.onToggleMute?.call();
      return KeyEventResult.handled;
    }
    // Esc → 退出
    if (key == LogicalKeyboardKey.escape) {
      widget.onExit?.call();
      return KeyEventResult.handled;
    }
    // 0-9 → 跳转
    if (key >= LogicalKeyboardKey.digit0 &&
        key <= LogicalKeyboardKey.digit9) {
      final index = key.keyId - LogicalKeyboardKey.digit0.keyId;
      final fraction = index == 0 ? 0.0 : index * 0.1;
      widget.onSeekFraction?.call(fraction);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// 触控板/Apple Pencil 悬停信号
  void _handlePointerSignal(PointerSignalEvent event) {
    if (!_iPadService.supportApplePencilHover) return;

    if (event is PointerHoverEvent) {
      final kind = event.kind;
      if (kind == PointerDeviceKind.stylus) {
        // Apple Pencil 悬停
        setState(() {
          _pencilHoverPosition = event.position;
          _showPencilPreview = true;
        });
        // 短暂显示后隐藏
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) {
            setState(() => _showPencilPreview = false);
          }
        });
      }
    }
  }

  Widget _buildPencilHoverPreview() {
    return Positioned(
      bottom: 120,
      left: 0,
      right: 0,
      child: Container(
        height: 4,
        margin: const EdgeInsets.symmetric(horizontal: 80),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(0.3),
              const Color(0xFF6C5CE7).withOpacity(0.8),
              Colors.white.withOpacity(0.3),
            ],
          ),
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C5CE7).withOpacity(0.4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}