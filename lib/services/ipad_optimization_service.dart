import 'package:flutter/material.dart';
import 'device_info_service.dart';

/// iPad 布局模式
enum IPadLayoutMode {
  /// 全屏 (full screen) → 标准双栏
  fullScreen,

  /// 分屏一半 (splitView half) → 默认 ~50% 宽度 → 类手机布局
  splitHalf,

  /// 分屏 1/3 → 紧凑手机布局
  splitCompact,

  /// Slide Over 浮窗 → 最紧凑
  slideOver,
}

/// iPad 专属优化服务
/// Stage Manager、分屏、台前调度、Apple Pencil、妙控键盘、120Hz
class IPadOptimizationService {
  IPadOptimizationService._();
  static final instance = IPadOptimizationService._();

  final _device = DeviceInfoService.instance;

  // ────────────── Stage Manager / 分屏 ──────────────

  bool get supportStageManager => _device.supportStageManager;

  /// 在 Stage Manager 下运行时，窗口尺寸变化通知
  void Function(Size newSize)? onStageManagerResize;

  // ────────────── 布局策略：iPad 尺寸映射 ──────────────

  /// 根据当前宽度推断 iPad 布局模式
  IPadLayoutMode inferLayoutMode(double width) {
    if (width >= 900) return IPadLayoutMode.fullScreen;
    if (width >= 600) return IPadLayoutMode.splitHalf;
    if (width >= 400) return IPadLayoutMode.splitCompact;
    return IPadLayoutMode.slideOver;
  }

  // ────────────── 键盘快捷键 ──────────────

  /// iPad 妙控键盘支持的快捷键列表
  static const keyboardShortcuts = <String, String>{
    'Space': '播放 / 暂停',
    '→': '快进 10 秒',
    '←': '快退 10 秒',
    '↑': '音量 +',
    '↓': '音量 -',
    'F': '进入/退出全屏',
    'Esc': '退出播放器',
    'S': '切换字幕',
    'R': '切换倍速',
    'P': '画中画',
    'M': '静音/取消静音',
    '[ ': '上一集',
    '] ': '下一集',
    '0–9': '跳转到 0%–90%',
  };

  // ────────────── Apple Pencil / Trackpad 手势 ──────────────

  /// 触控板双指滑动 → 快进快退
  bool get supportTrackpadGestures => true;

  /// Apple Pencil 悬停预览 (iPad Pro 2022 M2 特有)
  bool get supportApplePencilHover => _device.isIPadPro2022;

  // ────────────── 120Hz ProMotion ──────────────

  bool get support120Hz => _device.has120Hz;

  /// 是否应该在播放时锁定 120Hz（防止掉帧）
  bool get lock120HzDuringPlayback => _device.has120Hz;

  // ────────────── LiDAR 场景 ──────────────

  bool get hasLidar => _device.hasLidar;

  // not useful for video player yet, but could enable AR features

  // ────────────── Liquid Retina XDR ──────────────

  bool get hasXDRDisplay =>
      _device.isIPadPro2022 || (_device.iPadModel == IPadModel.ipadPro2021);

  /// 设置页使用的别名：是否支持 XDR 显示
  bool get supportXDR => hasXDRDisplay;

  /// HDR 内容支持
  bool get supportHDRContent =>
      hasXDRDisplay || _device.capabilities.supportHDR;

  // ────────────── iPad 导航栏样式 ──────────────

  /// iPad 应该使用固定左侧导航栏还是底部栏
  bool get useSidebarNavigation {
    if (_device.isIPad) {
      final mode =
          inferLayoutMode(_device.capabilities.maxScreenWidth.toDouble());
      // SplitView 紧凑模式下可降至底部栏
      return mode == IPadLayoutMode.fullScreen ||
          mode == IPadLayoutMode.splitHalf;
    }
    return false;
  }

  // ────────────── 引导提示 ──────────────

  Future<bool> showIPadWelcomeSheet(BuildContext context) async {
    if (!_device.isIPadPro2022) return false;

    return await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: const Color(0xFFF2F2F7),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.tablet_mac_rounded,
                      color: Color(0xFF6C5CE7), size: 22),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('iPad Pro 已就绪',
                        style: TextStyle(
                            color: Color(0xFF1C1C1E),
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    Text('M2 芯片 · ProMotion · XDR',
                        style:
                            TextStyle(color: Color(0xFF8E8E93), fontSize: 13)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            _featureRow(
                Icons.aspect_ratio_rounded, '台前调度', '支持多窗口、分屏、Slide Over'),
            const SizedBox(height: 10),
            _featureRow(
                Icons.keyboard_rounded, '键盘快捷键', '妙控键盘 Space 播放/暂停，←→ 快进快退'),
            const SizedBox(height: 10),
            _featureRow(Icons.draw_rounded, 'Apple Pencil 悬停', '悬停预览进度条、快速定位'),
            const SizedBox(height: 10),
            _featureRow(
                Icons.hdr_on_rounded, 'XDR 显示', '1600nit 峰值亮度，HDR 内容完美呈现'),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6C5CE7),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('开始使用', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    ).then((v) => v ?? false);
  }

  Widget _featureRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF3C3C43), size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style:
                      const TextStyle(color: Color(0xFF1C1C1E), fontSize: 14)),
              Text(subtitle,
                  style:
                      const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}
