import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path_provider/path_provider.dart';

/// HDR 输出模式。
///
/// ## 背景
///
/// Flutter 的 video_controller 纹理回传路径（`vo=libmpv`）拿到的永远是
/// 已经转成 RGB 的 SDR 帧，**无法做真正的 HDR 输出**。要做 HDR 直通，
/// 必须让 mpv 自己用 `vo=gpu-next` 渲到 Surface，并且由 libplacebo
/// 负责色彩管线。
///
/// 但 media-kit 官方预编译的 libmpv 在构建时显式关闭了 libplacebo：
///   `-Dvulkan=disabled -Dlibplacebo=disabled -Dshaderc=disabled`
/// 所以官方库只能用 `gpu`（OpenGL ES），做不了 HDR 直通。
///
/// 我们自建的 libmpv 打开了这些选项（见 tools/patch_libplacebo.sh），
/// 因此可以：
///   1. 用 `vo=gpu-next` 建立 Vulkan 渲染管线
///   2. 加载 hdr-toys 的 GLSL hook 着色器做精确色彩转换
///   3. 配合 `target-colorspace-hint=yes` 向系统声明 HDR 输出
///
/// ## 各档位的含义
///
/// 这些档位对应 hdr-toys 的 5 个 profile（见 hdr-toys.conf）：
///
/// | 档位 | target-prim | target-trc | shader 链 |
/// |------|-------------|------------|-----------|
/// | off（关闭） | 不做干预，走 mpv 默认 SDR 映射 | | |
/// | bt2100Pq | bt.2020 | pq | pq_inv → astra → bottosson → bt1886 |
/// | bt2100Hlg | bt.2020 | hlg | hlg_inv → astra → bottosson → bt1886 |
/// | bt2020 | bt.2020 | bt.1886 | bt1886_inv → bottosson → bt1886 |
/// | linear | bt.2020 | linear | clip_black → clip_alpha → astra → bottosson → bt1886 |
///
/// ⚠ 重要：hdr-toys 的 README 明确要求**不要**设置 `target-peak`、
/// `icc-profile`，否则色彩会被二次处理。所以启用任何 HDR 档位时，
/// 必须清掉主流程里设置的那些 SDR 映射参数（见 PlayerNotifier）。
enum HdrOutputMode {
  /// 关闭：不启用 gpu-next / 不做 HDR 直通，走现有 SDR 映射逻辑。
  off,

  /// BT.2100 PQ（HDR10 标准输出）
  bt2100Pq,

  /// BT.2100 HLG（广播 HDR 标准，杜比 8.4 基础层）
  bt2100Hlg,

  /// BT.2020 + SDR 伽马（广色域 SDR）
  bt2020,

  /// 线性光（给 HDR 显示器/后期监看用，最激进）
  linear,
}

/// HDR 输出模式在当前平台是否可用。
///
/// ## 为什么只有 Android
///
/// 这套功能依赖三件事同时成立：
///   1. libmpv 编译时带 `-Dlibplacebo=enabled -Dvulkan=enabled
///      -Dshaderc=enabled`
///   2. 渲染后端能建 `vo=gpu-next`（需要 Vulkan）
///   3. hdr-toys 的 hook 着色器能被 libplacebo 执行
///
/// 目前只有 **Android** 满足：
///   - 自建 libmpv（tools/build_android_libmpv.sh）打开了这三项，
///     Android 设备自带 Vulkan loader（libvulkan.so 是系统库）。
///
/// iOS 不满足，且有硬性障碍：
///   - media_kit 的 iOS libmpv 同样关闭了 libplacebo
///   - 即使打开，iOS **没有原生 Vulkan**，必须引入 MoltenVK
///     （Vulkan → Metal 翻译层），构建链完全不同（Nix + macOS runner），
///     且 MoltenVK 对 libplacebo 的 compute shader 支持并不完整
///   - iOS 上 media_kit 走 `vo=libmpv`（纹理回传），本身做不了 HDR 直通
///
/// 所以 iOS / 桌面一律不允许切到非 off 档：切了只会黑屏或毫无效果。
bool get hdrOutputModeSupported {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

/// [HdrOutputMode] 的扩展：把 Dart 枚举映射到 mpv 参数 + shader 文件列表。
extension HdrOutputModeX on HdrOutputMode {
  /// 存储用的稳定标识（不随枚举顺序变化）。
  String get id => switch (this) {
        HdrOutputMode.off => 'off',
        HdrOutputMode.bt2100Pq => 'bt2100_pq',
        HdrOutputMode.bt2100Hlg => 'bt2100_hlg',
        HdrOutputMode.bt2020 => 'bt2020',
        HdrOutputMode.linear => 'linear',
      };

  /// 界面上显示的名字。
  String get label => switch (this) {
        HdrOutputMode.off => '关闭（SDR）',
        HdrOutputMode.bt2100Pq => 'BT.2100 PQ（HDR10）',
        HdrOutputMode.bt2100Hlg => 'BT.2100 HLG（广播 HDR）',
        HdrOutputMode.bt2020 => 'BT.2020（广色域 SDR）',
        HdrOutputMode.linear => '线性 HDR',
      };

  /// 设置页右侧显示的精简名字（放不下完整 label）。
  String get shortLabel => switch (this) {
        HdrOutputMode.off => '关闭',
        HdrOutputMode.bt2100Pq => 'BT.2100 PQ',
        HdrOutputMode.bt2100Hlg => 'BT.2100 HLG',
        HdrOutputMode.bt2020 => 'BT.2020',
        HdrOutputMode.linear => '线性 HDR',
      };

  /// 一句话说明，给设置页做副标题。
  String get description => switch (this) {
        HdrOutputMode.off => '不做 HDR 直通，兼容性最好',
        HdrOutputMode.bt2100Pq => '片源是 HDR10/PQ 时最准确',
        HdrOutputMode.bt2100Hlg => '适合 HLG 片源（杜比 8.4 基础层）',
        HdrOutputMode.bt2020 => 'SDR 片源用广色域，颜色更艳',
        HdrOutputMode.linear => '给 HDR 显示器/专业监看，可能过曝',
      };

  /// 是否需要 gpu-next + libplacebo。
  bool get needsGpuNext => this != HdrOutputMode.off;

  /// 当前平台能否使用这个档位。
  ///
  /// 非 Android 一律返回 false（看文件顶部 [hdrOutputModeSupported] 说明）。
  bool get isAvailable => !needsGpuNext || hdrOutputModeSupported;

  /// 目标色域（mpv `target-prim`）。null 表示不干预。
  String? get targetPrim => switch (this) {
        HdrOutputMode.off => null,
        HdrOutputMode.bt2100Pq => 'bt.2020',
        HdrOutputMode.bt2100Hlg => 'bt.2020',
        HdrOutputMode.bt2020 => 'bt.2020',
        HdrOutputMode.linear => 'bt.2020',
      };

  /// 目标传递函数（mpv `target-trc`）。null 表示不干预。
  String? get targetTrc => switch (this) {
        HdrOutputMode.off => null,
        HdrOutputMode.bt2100Pq => 'pq',
        HdrOutputMode.bt2100Hlg => 'hlg',
        HdrOutputMode.bt2020 => 'bt.1886',
        HdrOutputMode.linear => 'linear',
      };

  /// 是否向系统声明「我要输出 HDR」（mpv `target-colorspace-hint`）。
  ///
  /// 只有 PQ / HLG 是真正的 HDR 传递函数，需要系统做 HDR 合成；
  /// bt.2020（SDR 伽马）和 linear 都不该开，否则系统会误判。
  bool get colorspaceHint =>
      this == HdrOutputMode.bt2100Pq || this == HdrOutputMode.bt2100Hlg;

  /// hdr-toys 的 shader 相对路径链（按 mpv 的加载顺序）。
  ///
  /// 顺序很关键：先从源色彩空间转到线性，再 tone-map，再转回目标
  /// 传递函数。顺序错了会出现重复 tone-map 或 gamma 叠两次。
  List<String> get shaderChain => switch (this) {
        HdrOutputMode.off => const [],
        // PQ 输入：PQ→线性 → 色调映射 → 色域映射 → 线性→BT.1886 输出
        HdrOutputMode.bt2100Pq => const [
            'utils/clip_both.glsl',
            'transfer-function/pq_inv.glsl',
            'tone-mapping/astra.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
          ],
        // HLG 输入：结构同 PQ，只是第一步换成 hlg_inv
        HdrOutputMode.bt2100Hlg => const [
            'utils/clip_both.glsl',
            'transfer-function/hlg_inv.glsl',
            'tone-mapping/astra.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
          ],
        // 广色域 SDR：先反 gamma 到线性，色域映射，再回 BT.1886
        HdrOutputMode.bt2020 => const [
            'transfer-function/bt1886_inv.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
          ],
        // 线性光：裁掉黑/alpha，tone-map，色域映射，最后回 BT.1886
        HdrOutputMode.linear => const [
            'utils/clip_black.glsl',
            'utils/clip_alpha.glsl',
            'tone-mapping/astra.glsl',
            'gamut-mapping/bottosson.glsl',
            'transfer-function/bt1886.glsl',
          ],
      };

  /// 各档位附带的 `glsl-shader-opts-append` 参数。
  ///
  /// 这些值来自 hdr-toys.conf 的官方推荐配置，改动前请对照上游。
  List<String> get shaderOpts => switch (this) {
        HdrOutputMode.off => const [],
        HdrOutputMode.bt2100Pq => const ['auto_exposure_limit_positive=1.02'],
        HdrOutputMode.bt2100Hlg => const [],
        HdrOutputMode.bt2020 => const [],
        HdrOutputMode.linear => const [
            'spatial_stable_level=0',
            'temporal_stable_duration=0',
            'enable_metering=1',
          ],
      };

  static HdrOutputMode fromId(String? id) {
    if (id == null) return HdrOutputMode.off;
    for (final m in HdrOutputMode.values) {
      if (m.id == id) return m;
    }
    return HdrOutputMode.off;
  }
}

/// 把 hdr-toys 的 shader 从 Flutter assets 释放到磁盘，并返回可用路径。
///
/// ## 为什么需要「释放到磁盘」
///
/// mpv 的 `glsl-shader` 参数只接受**文件系统路径**，不认 Flutter 的
/// asset 虚拟路径（`flutter_assets/...` 在 Android 上是 APK 内的 zip
/// 条目，mpv 的 fopen 读不到）。
///
/// 而且 hdr-toys 的 shader 之间有 `//!include` 之类的相对引用，
/// 必须保留目录结构，不能把 83 个 .glsl 平铺到一个目录。
///
/// 所以做法是：首次启用时把整个 `assets/hdr-toys/shaders/` 目录树
/// 解压到应用支持目录，之后复用（用版本号文件判断是否已释放）。
class HdrShaderInstaller {
  HdrShaderInstaller._();

  static final HdrShaderInstaller instance = HdrShaderInstaller._();

  /// 与 assets 内容对应；shader 更新时改这个值即可触发重新释放。
  static const String _version = '1';

  Directory? _root;

  /// shader 根目录（`.../hdr-toys/shaders/hdr-toys`）。
  ///
  /// 注意多一层 `hdr-toys`：assets 里的结构是
  ///   assets/hdr-toys/shaders/hdr-toys/{utils,transfer-function,...}
  /// 而 mpv 的 shader 路径要指到具体 .glsl 文件。
  Directory? get root => _root;

  /// 是否已成功释放。
  bool get isReady => _root != null;

  /// 确保 shader 已释放到磁盘。重复调用是安全的。
  ///
  /// 返回 shader 根目录；失败返回 null（调用方应回退到「关闭 HDR」）。
  Future<Directory?> ensureInstalled() async {
    if (_root != null) return _root;

    // gpu-next / hdr-toys 只在我们自建的 libmpv 上有意义，
    // 其它平台（iOS/桌面）暂时不启用，避免误伤现有稳定逻辑。
    if (!Platform.isAndroid) {
      debugPrint('[HDR] 非 Android 平台，跳过 shader 安装');
      return null;
    }

    try {
      final support = await getApplicationSupportDirectory();
      final base = Directory('${support.path}/hdr-toys');
      final marker = File('${base.path}/.version');

      // 版本一致且目标目录存在 → 直接复用
      if (await marker.exists()) {
        final v = (await marker.readAsString()).trim();
        final target = Directory('${base.path}/shaders/hdr-toys');
        if (v == _version && await target.exists()) {
          _root = target;
          debugPrint('[HDR] 复用已释放的 shader: ${target.path}');
          return target;
        }
      }

      // 重新释放
      if (await base.exists()) {
        await base.delete(recursive: true);
      }
      await base.create(recursive: true);

      final target = Directory('${base.path}/shaders/hdr-toys');
      final count = await _copyAssetTree(
        'assets/hdr-toys/shaders/hdr-toys',
        target,
      );

      if (count == 0) {
        debugPrint('[HDR] ⚠ 没有释放出任何 shader，检查 pubspec assets 配置');
        return null;
      }

      await marker.writeAsString(_version);
      _root = target;
      debugPrint('[HDR] 已释放 $count 个 shader 到 ${target.path}');
      return target;
    } catch (e, st) {
      debugPrint('[HDR] 释放 shader 失败: $e\n$st');
      return null;
    }
  }

  /// 递归复制 asset 目录树，返回复制的文件数。
  Future<int> _copyAssetTree(String assetDir, Directory dest) async {
    // Flutter 没有「列 asset 目录」的 API，只能靠预生成的清单。
    // 见 tool 里生成的 hdr_toys_manifest.dart；
    // 这里用 AssetManifest 更稳（Flutter 3.7+ 提供）。
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest
        .listAssets()
        .where((a) => a.startsWith('$assetDir/') && a.endsWith('.glsl'))
        .toList();

    var n = 0;
    for (final a in assets) {
      try {
        final data = await rootBundle.load(a);
        final rel = a.substring(assetDir.length + 1);
        final out = File('${dest.path}/$rel');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        n++;
      } catch (e) {
        debugPrint('[HDR] 复制 $a 失败: $e');
      }
    }
    return n;
  }
}
