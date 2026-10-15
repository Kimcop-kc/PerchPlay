import 'dart:async';
import 'package:flutter/material.dart';
import 'device_info_service.dart';
import 'native_bridge_service.dart';

/// 中国品牌 ROM 适配服务
/// 处理：电池优化白名单、悬浮窗权限、自启动、MIUI/EMUI/ColorOS/OriginOS 差异
class RomOptimizationService {
  RomOptimizationService._();
  static final instance = RomOptimizationService._();

  final _device = DeviceInfoService.instance;

  // ────────────── 电池优化白名单 ──────────────
  // 小米 / 华为 / OPPO / vivo 在后台播放时必须请求忽略电池优化

  bool get needsBatteryOptimizationBypass =>
      _device.isChineseBrand;

  String get batteryOptimizationGuideText {
    if (_device.isXiaomi) {
      return '长按 PerchPlay 图标 → 应用信息 → 省电策略 → 选择「无限制」';
    }
    if (_device.isHuawei) {
      return '设置 → 应用 → 应用启动管理 → PerchPlay → 手动管理（全部开启）';
    }
    if (_device.isOppo) {
      return '设置 → 电池 → 应用耗电管理 → PerchPlay → 允许后台运行';
    }
    if (_device.isVivo) {
      return '设置 → 电池 → 后台高耗电 → PerchPlay → 允许';
    }
    return '';
  }

  // ────────────── 悬浮窗权限 ──────────────
  // 中国品牌 ROM 默认禁止悬浮窗，需要引导用户打开

  bool get needsOverlayPermissionGuide => _device.isChineseBrand;

  String get overlayPermissionGuideText {
    if (_device.isXiaomi) {
      return '设置 → 应用设置 → 授权管理 → 应用权限管理 → PerchPlay → 显示悬浮窗 → 允许';
    }
    if (_device.isHuawei) {
      return '设置 → 应用 → 权限管理 → 悬浮窗 → PerchPlay → 允许';
    }
    if (_device.isOppo) {
      return '设置 → 应用管理 → 悬浮窗管理 → PerchPlay → 允许';
    }
    if (_device.isVivo) {
      return '设置 → 更多设置 → 权限管理 → 悬浮窗 → PerchPlay → 允许';
    }
    return '';
  }

  // ────────────── 自启动权限 ──────────────
  // 华为/OPPO/vivo 需要手动开启自启动

  bool get needsAutoStartPermission {
    return _device.isHuawei || _device.isOppo || _device.isVivo;
  }

  String get autoStartGuideText {
    if (_device.isHuawei) {
      return '手机管家 → 应用启动管理 → PerchPlay → 手动管理 → 开启「自启动」';
    }
    if (_device.isOppo) {
      return '设置 → 应用管理 → 自启动管理 → PerchPlay → 开启';
    }
    if (_device.isVivo) {
      return 'i管家 → 应用管理 → 权限管理 → 自启动 → PerchPlay → 开启';
    }
    return '';
  }

  // ────────────── 设置页使用的对外别名 / 跳转 ──────────────

  /// 电池优化引导文案（设置页）
  String get batteryGuide => batteryOptimizationGuideText;

  /// 自启动引导文案（设置页）
  String get autoStartGuide => autoStartGuideText;

  /// 跳转到系统电池优化设置
  Future<bool> openBatterySettings() =>
      NativeBridgeService.instance.requestBatteryOptimization();

  /// 跳转到厂商自启动管理页
  Future<bool> openAutoStartSettings() =>
      NativeBridgeService.instance.requestAutoStart();

  // ────────────── MIUI 特定 ──────────────

  bool get isMiuiWithXiaomiAccount =>
      _device.isXiaomi; // 小米账号优化

  String get miuiVideoToolboxGuide =>
      '安全中心 → 视频工具箱 → 添加 PerchPlay → 开启画质增强 / 动态补偿';

  // ────────────── 全面屏凹口安全区 ──────────────

  /// 返回顶部安全 padding，适配挖孔/刘海
  EdgeInsets getSafeAreaPadding(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    var top = mediaQuery.padding.top;
    var bottom = mediaQuery.padding.bottom;
    var left = mediaQuery.padding.left;
    var right = mediaQuery.padding.right;

    // 小米全面屏额外底部 padding（手势条区域）
    if (_device.isXiaomi) {
      bottom = bottom < 24 ? 24 : bottom;
    }
    // 华为底部手势
    if (_device.isHuawei) {
      bottom = bottom < 20 ? 20 : bottom;
    }

    return EdgeInsets.fromLTRB(left, top, right, bottom);
  }

  // ────────────── 播放器安全区偏移 ──────────────

  /// 播放时挖孔区域不遮挡关键按钮
  double get topBarExtraPadding {
    if (_device.isXiaomi) return 8;
    if (_device.isHuawei) return 6;
    return 0;
  }

  // ────────────── 展示权限引导对话框 ──────────────

  Future<bool> showPermissionGuideDialog(BuildContext context) async {
    final completer = Completer<bool>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFFF2F2F7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              _device.isXiaomi
                  ? Icons.phone_android_rounded
                  : Icons.shield_rounded,
              color: const Color(0xFFFF6900),
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${_brandDisplayName} 手机优化',
                style: const TextStyle(color: Color(0xFF1C1C1E), fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '为确保 PerchPlay 正常使用，建议进行以下设置：',
                style: TextStyle(color: Color(0xFF3C3C43), fontSize: 14),
              ),
              const SizedBox(height: 16),
              if (needsBatteryOptimizationBypass) ...[
                _guideStep('1. 关闭电池优化', batteryOptimizationGuideText),
              ],
              if (needsOverlayPermissionGuide) ...[
                const SizedBox(height: 12),
                _guideStep('2. 开启悬浮窗权限', overlayPermissionGuideText),
              ],
              if (needsAutoStartPermission) ...[
                const SizedBox(height: 12),
                _guideStep('3. 开启自启动', autoStartGuideText),
              ],
              if (_device.isXiaomi) ...[
                const SizedBox(height: 12),
                _guideStep('💡 小技巧', miuiVideoToolboxGuide),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              completer.complete(false);
            },
            child: const Text('稍后设置',
                style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              completer.complete(true);
            },
            child: const Text('我知道了'),
          ),
        ],
      ),
    );

    return completer.future;
  }

  Widget _guideStep(String title, String content) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Color(0xFF1C1C1E),
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Text(content,
              style: const TextStyle(
                  color: Color(0xFF3C3C43), fontSize: 12, height: 1.5)),
        ],
      ),
    );
  }

  String get _brandDisplayName {
    switch (_device.brand) {
      case DeviceBrand.xiaomi:
        return '小米';
      case DeviceBrand.huawei:
        return '华为/荣耀';
      case DeviceBrand.oppo:
        return 'OPPO/一加';
      case DeviceBrand.vivo:
        return 'vivo/iQOO';
      default:
        return '安卓';
    }
  }
}
