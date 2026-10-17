import 'dart:io';

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

  bool _initialized = false;
  bool get initialized => _initialized;

  /// 客户端必须调一次 init
  Future<void> init({String? deviceModel, String? systemName}) async {
    if (_initialized) return;

    if (Platform.isIOS ||
        (systemName != null && systemName.contains('iOS'))) {
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
    }

    // 读取 RAM（Android 读 /proc/meminfo）
    _ramGB = await _readTotalRamGB();

    _initialized = true;
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
    final isPro2022 =
        m.contains('ipad14,5') || m.contains('ipad14,6') ||
        m.contains('ipad14,3') || m.contains('ipad14,4');
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
    final isOppoVivo =
        brand == DeviceBrand.oppo || brand == DeviceBrand.vivo;
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
  bool get isChineseBrand =>
      isXiaomi || isHuawei || isOppo || isVivo;
  bool get isIPad => _brand == DeviceBrand.ipad;
  bool get isIPadPro =>
      _iPadModel == IPadModel.ipadPro2022 ||
      _iPadModel == IPadModel.ipadPro2021 ||
      _iPadModel == IPadModel.ipadPro2020;
  bool get isIPadPro2022 => _iPadModel == IPadModel.ipadPro2022;
  bool get isIPhone => _brand == DeviceBrand.apple;
  bool get supportStageManager =>
      _capabilities.supportStageManager;
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
                return double.parse(
                    (kb / (1024 * 1024)).toStringAsFixed(1));
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