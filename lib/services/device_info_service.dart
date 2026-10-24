import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import 'native_bridge_service.dart';

/// 设备品牌枚举
enum DeviceBrand {
  xiaomi,
  huawei,
  oppo,
  vivo,
  samsung,
  apple,
  ipad,
  other,
}

/// iPad 具体型号
enum IPadModel {
  ipadPro2022,
  ipadPro2021,
  ipadPro2020,
  ipadAir,
  ipad,
  ipadMini,
  notIPad,
}

/// 设备能力
class DeviceCapabilities {
  final bool hasNotch;
  final bool hasPunchHole;
  final bool isGestureNavigation;
  final bool supportHDR;
  final bool has120Hz;
  final bool supportPiP;
  final bool supportStageManager;
  final bool hasLidar;
  final bool isM1OrAbove;
  final int cpuCores;
  final double maxScreenWidth;
  final double maxScreenHeight;

  const DeviceCapabilities({
    this.hasNotch = false,
    this.hasPunchHole = false,
    this.isGestureNavigation = true,
    this.supportHDR = false,
    this.has120Hz = false,
    this.supportPiP = false,
    this.supportStageManager = false,
    this.hasLidar = false,
    this.isM1OrAbove = false,
    this.cpuCores = 8,
    this.maxScreenWidth = 428,
    this.maxScreenHeight = 926,
  });

  /// 仅覆盖 supportHDR，其余字段保持不变。
  ///
  /// 用于真实 HDR 检测结果回填（init 里拿到原生数据后覆盖硬编码值）。
  DeviceCapabilities copyWithSupportHDR(bool value) {
    return DeviceCapabilities(
      hasNotch: hasNotch,
      hasPunchHole: hasPunchHole,
      isGestureNavigation: isGestureNavigation,
      supportHDR: value,
      has120Hz: has120Hz,
      supportPiP: supportPiP,
      supportStageManager: supportStageManager,
      hasLidar: hasLidar,
      isM1OrAbove: isM1OrAbove,
      cpuCores: cpuCores,
      maxScreenWidth: maxScreenWidth,
      maxScreenHeight: maxScreenHeight,
    );
  }
}

/// 设备信息服务 —— 检测品牌、型号、能力、RAM
class DeviceInfoService {
  DeviceInfoService._();
  static final instance = DeviceInfoService._();

  DeviceBrand _brand = DeviceBrand.other;
  DeviceBrand get brand => _brand;

  IPadModel _iPadModel = IPadModel.notIPad;
  IPadModel get iPadModel => _iPadModel;

  DeviceCapabilities _capabilities = const DeviceCapabilities();
  DeviceCapabilities get capabilities => _capabilities;

  double _ramGB = 0;
  double get ramGB => _ramGB;

  // ── 真实 HDR 能力（来自 Android Display.getHdrCapabilities）──

  /// 是否已拿到真实 HDR 检测结果（区别于还没检测）。
  bool _hdrDetected = false;
  bool get hdrDetected => _hdrDetected;

  /// 设备真实支持的 HDR 类型（如 HDR10 / HDR10+ / DOLBY_VISION / HLG）。
  /// 未检测到或非 Android 时为空列表。
  List<String> _hdrTypes = const [];
  List<String> get hdrTypes => _hdrTypes;

  bool _hdr10 = false;
  bool get hdr10 => _hdr10;

  bool _hdr10Plus = false;
  bool get hdr10Plus => _hdr10Plus;

  bool _dolbyVision = false;
  bool get dolbyVision => _dolbyVision;

  bool _hlg = false;
  bool get hlg => _hlg;

  /// 峰值亮度（nit）。-1 表示拿不到。
  double _maxLuminance = -1;
  double get maxLuminance => _maxLuminance;

  bool _initialized = false;
  bool get initialized => _initialized;

  /// 客户端必须调一次 init
  Future<void> init({String? deviceModel, String? systemName}) async {
    if (_initialized) return;

    if (Platform.isIOS || (systemName != null && systemName.contains('iOS'))) {
      final model = deviceModel ?? 'iPad';
      if (model.contains('iPad')) {
        _brand = DeviceBrand.ipad;
        _iPadModel = _detectIPadModel(model);
      } else {
        _brand = DeviceBrand.apple;
      }
      _capabilities = _appleCapabilities(model);
    } else {
      final model = (deviceModel ?? '').toLowerCase();
      final manufacturer = model;

      if (manufacturer.contains('xiaomi') ||
          manufacturer.contains('redmi') ||
          manufacturer.contains('poco') ||
          manufacturer.contains('mi ') ||
          manufacturer.contains('mix ')) {
        _brand = DeviceBrand.xiaomi;
      } else if (manufacturer.contains('huawei') ||
          manufacturer.contains('honor') ||
          manufacturer.contains('hry') ||
          manufacturer.contains('hua')) {
        _brand = DeviceBrand.huawei;
      } else if (manufacturer.contains('oppo') ||
          manufacturer.contains('realme') ||
          manufacturer.contains('oneplus') ||
          manufacturer.contains('rmx') ||
          manufacturer.contains('cph')) {
        _brand = DeviceBrand.oppo;
      } else if (manufacturer.contains('vivo') ||
          manufacturer.contains('iqoo') ||
          manufacturer.contains('v2')) {
        _brand = DeviceBrand.vivo;
      } else if (manufacturer.contains('samsung') ||
          manufacturer.contains('sm-')) {
        _brand = DeviceBrand.samsung;
      }

      _capabilities = _androidCapabilities(_brand, model);

      // 真实 HDR 能力：用原生 Display.getHdrCapabilities() 覆盖
      // 「按品牌拍脑袋」的 supportHDR。必须在 init 里做（要 await 原生），
      // 拿到后 _androidCapabilities 里的硬编码值就被真实值取代。
      await _detectHdrCapabilities();
    }

    // 读取 RAM（Android 读 /proc/meminfo）
    _ramGB = await _readTotalRamGB();

    _initialized = true;
  }

  /// 用原生 API 检测设备真实 HDR 显示能力。
  ///
  /// **只检测一次**：首次启动调 `Display.getHdrCapabilities()`，把结果
  /// 缓存进 SharedPreferences；之后每次冷启动直接读缓存，不再调原生。
  /// 设备硬件能力不会变，重复检测纯属浪费（用户明确要求"检测一次就够了"）。
  ///
  /// 之前 [DeviceCapabilities.supportHDR] 是按品牌硬编码（任何小米都 true），
  /// 低端机也会被误判成 HDR 屏。现在用真实 API 覆盖：
  ///  - 支持 HDR10/HDR10+/杜比/HLG 的任一种 → 真正支持 HDR
  ///  - 拿不到（非 Android / API<24 / 异常）→ 回退到品牌猜测值
  Future<void> _detectHdrCapabilities() async {
    if (!Platform.isAndroid) return;

    // 先读缓存：检测过一次就不再调原生
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('hdr.detected') == true) {
        _hdrDetected = true;
        _hdr10 = prefs.getBool('hdr.hdr10') ?? false;
        _hdr10Plus = prefs.getBool('hdr.hdr10Plus') ?? false;
        _dolbyVision = prefs.getBool('hdr.dolbyVision') ?? false;
        _hlg = prefs.getBool('hdr.hlg') ?? false;
        _hdrTypes = prefs.getStringList('hdr.types') ?? const [];
        _maxLuminance = prefs.getDouble('hdr.maxLuminance') ?? -1;
        final anyHdr = _hdr10 || _hdr10Plus || _dolbyVision || _hlg;
        _capabilities = _capabilities.copyWithSupportHDR(anyHdr);
        debugPrint('[Device] HDR 能力（缓存）: '
            '${_hdrTypes.isEmpty ? "无" : _hdrTypes.join("/")} '
            '峰值=${_maxLuminance > 0 ? "${_maxLuminance.toInt()}nit" : "未知"}');
        return;
      }
    } catch (_) {}

    // 首次检测：调原生，成功后写缓存
    try {
      final caps = await NativeBridgeService.instance.getHdrCapabilities();
      if (caps == null) return;

      _hdrDetected = true;
      _hdr10 = caps['hdr10'] as bool? ?? false;
      _hdr10Plus = caps['hdr10Plus'] as bool? ?? false;
      _dolbyVision = caps['dolbyVision'] as bool? ?? false;
      _hlg = caps['hlg'] as bool? ?? false;

      final names = caps['supported'] as List<dynamic>? ?? const [];
      _hdrTypes = names.map((e) => e.toString()).toList();

      final lum = caps['maxLuminance'];
      _maxLuminance = (lum is num) ? lum.toDouble() : -1;

      // 用真实检测覆盖 capabilities.supportHDR
      final anyHdr = _hdr10 || _hdr10Plus || _dolbyVision || _hlg;
      _capabilities = _capabilities.copyWithSupportHDR(anyHdr);

      // 写缓存：下次冷启动直接读，不再调原生
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('hdr.detected', true);
        await prefs.setBool('hdr.hdr10', _hdr10);
        await prefs.setBool('hdr.hdr10Plus', _hdr10Plus);
        await prefs.setBool('hdr.dolbyVision', _dolbyVision);
        await prefs.setBool('hdr.hlg', _hlg);
        await prefs.setStringList('hdr.types', _hdrTypes);
        await prefs.setDouble('hdr.maxLuminance', _maxLuminance);
      } catch (_) {}

      debugPrint('[Device] HDR 检测: ${_hdrTypes.isEmpty ? "无" : _hdrTypes.join("/")}'
          ' 峰值=${_maxLuminance > 0 ? "${_maxLuminance.toInt()}nit" : "未知"}'
          ' supportHDR=$anyHdr');
    } catch (e) {
      debugPrint('[Device] HDR 检测失败: $e');
    }
  }

  /// 模型 RAM 门槛是否超出本机总 RAM
  bool isTooHeavy(double minRamGB) {
    if (_ramGB <= 0) return false;
    return _ramGB < minRamGB;
  }

  // ──────────── iPad Model Detection ────────────

  IPadModel _detectIPadModel(String model) {
    final m = model.toLowerCase();
    if (m.contains('ipad14,5') || m.contains('ipad14,6')) {
      return IPadModel.ipadPro2022;
    }
    if (m.contains('ipad14,3') || m.contains('ipad14,4')) {
      return IPadModel.ipadPro2022;
    }
    if (m.contains('ipad13') || m.contains('pro') && m.contains('2021')) {
      return IPadModel.ipadPro2021;
    }
    if (m.contains('ipad8,') || m.contains('pro') && m.contains('2020')) {
      return IPadModel.ipadPro2020;
    }
    if (m.contains('air')) return IPadModel.ipadAir;
    if (m.contains('mini')) return IPadModel.ipadMini;
    return IPadModel.ipad;
  }

  DeviceCapabilities _appleCapabilities(String model) {
    final m = model.toLowerCase();
    final isPro2022 = m.contains('ipad14,5') ||
        m.contains('ipad14,6') ||
        m.contains('ipad14,3') ||
        m.contains('ipad14,4');
    final isPro = m.contains('pro');
    final hasLidar = m.contains('ipad14,5') ||
        m.contains('ipad14,6') ||
        m.contains('ipad13,8') ||
        m.contains('ipad13,9') ||
        m.contains('ipad13,10') ||
        m.contains('ipad13,11') ||
        m.contains('ipad8,11') ||
        m.contains('ipad8,12');

    return DeviceCapabilities(
      hasNotch: !isPro,
      hasPunchHole: false,
      isGestureNavigation: true,
      supportHDR: isPro,
      has120Hz: isPro,
      supportPiP: true,
      supportStageManager: true,
      hasLidar: hasLidar,
      isM1OrAbove: isPro,
      cpuCores: isPro2022 ? 10 : 8,
      maxScreenWidth: m.contains('12.9') ? 1024 : 834,
      maxScreenHeight: m.contains('12.9') ? 1366 : 1194,
    );
  }

  DeviceCapabilities _androidCapabilities(DeviceBrand brand, String model) {
    final isXiaomi = brand == DeviceBrand.xiaomi;
    final isHuawei = brand == DeviceBrand.huawei;
    final isOppoVivo = brand == DeviceBrand.oppo || brand == DeviceBrand.vivo;
    final has120Hz = isXiaomi || isOppoVivo;

    return DeviceCapabilities(
      hasNotch: false,
      hasPunchHole: true,
      isGestureNavigation: true,
      supportHDR: isXiaomi || isHuawei || isOppoVivo,
      has120Hz: has120Hz,
      supportPiP: isXiaomi,
      supportStageManager: false,
      hasLidar: false,
      isM1OrAbove: false,
      cpuCores: 8,
      maxScreenWidth: 412,
      maxScreenHeight: 915,
    );
  }

  // ──────────── 便捷方法 ────────────

  bool get isXiaomi => _brand == DeviceBrand.xiaomi;
  bool get isHuawei => _brand == DeviceBrand.huawei;
  bool get isOppo => _brand == DeviceBrand.oppo;
  bool get isVivo => _brand == DeviceBrand.vivo;
  bool get isChineseBrand => isXiaomi || isHuawei || isOppo || isVivo;
  bool get isIPad => _brand == DeviceBrand.ipad;
  bool get isIPadPro =>
      _iPadModel == IPadModel.ipadPro2022 ||
      _iPadModel == IPadModel.ipadPro2021 ||
      _iPadModel == IPadModel.ipadPro2020;
  bool get isIPadPro2022 => _iPadModel == IPadModel.ipadPro2022;
  bool get isIPhone => _brand == DeviceBrand.apple;
  bool get supportStageManager => _capabilities.supportStageManager;
  bool get has120Hz => _capabilities.has120Hz;
  bool get hasLidar => _capabilities.hasLidar;

  // ── RAM ──

  Future<double> _readTotalRamGB() async {
    if (Platform.isAndroid) {
      try {
        final lines = await File('/proc/meminfo').readAsLines();
        for (final line in lines) {
          if (line.startsWith('MemTotal:')) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final kb = int.tryParse(parts[1]);
              if (kb != null) {
                return double.parse((kb / (1024 * 1024)).toStringAsFixed(1));
              }
            }
          }
        }
      } catch (_) {}
    }
    return 0;
  }
}

/// DeviceBrand 扩展属性
extension DeviceBrandExtension on DeviceBrand {
  String get displayName {
    switch (this) {
      case DeviceBrand.xiaomi:
        return '小米';
      case DeviceBrand.huawei:
        return '华为';
      case DeviceBrand.oppo:
        return 'OPPO';
      case DeviceBrand.vivo:
        return 'vivo';
      case DeviceBrand.samsung:
        return '三星';
      case DeviceBrand.apple:
        return 'iPhone';
      case DeviceBrand.ipad:
        return 'iPad';
      case DeviceBrand.other:
        return '其他';
    }
  }

  bool get isXiaomi => this == DeviceBrand.xiaomi;
  bool get isHuawei => this == DeviceBrand.huawei;
  bool get isChineseBrand =>
      isXiaomi ||
      isHuawei ||
      this == DeviceBrand.oppo ||
      this == DeviceBrand.vivo;
}
