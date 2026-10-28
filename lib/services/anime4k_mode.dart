import 'dart:io';

import 'package:flutter/foundation.dart';

/// Anime4K 动漫放大模式。
///
/// ## 为什么单独做一个而不是塞进 HDR 输出模式
///
/// 两者都是 mpv 的 GLSL hook 着色器、都要求 `vo=gpu-next` + libplacebo，
/// 但**用途完全不同**：
///   - HDR 输出模式：调整色彩空间（转色域/传递函数）
///   - Anime4K：放大 + 修复线条（不改色彩）
///
/// 理论上可以叠加，但叠加后 GPU 负担翻倍、且两者的 `//!WHEN` 条件会互相
/// 干扰（Anime4K 假设自己独占 MAIN hook）。所以做成**互斥的两个功能**：
/// 开了 Anime4K 就不能开 HDR 输出模式，反之亦然。UI 上明确提示。
///
/// ## 档位怎么定的
///
/// 上游 Anime4K 有 S/M/L/VL/UL/UUL 六档 CNN（每档耗时翻倍），以及
/// GAN 和实验性的 3DGraphics 变体。手机 GPU 只敢取 **S/M/L 三档**：
///   - VL(143KB)/UL(283KB)/UUL(1MB) 单个 shader 就比整个 APK 的代码还大，
///     且官方数据（Vega64 桌面卡）显示 UL 在 1080p→4K 已经吃满 24fps 预算，
///     手机基本不可能实时。
///   - GAN 变体同理，且它的目标是大屏高分辨率，不是手机。
///
/// 另外提供一档 **非 CNN** 的极轻量方案（DoG 系列，合计 8KB），
/// 几乎不耗 GPU，适合低端机或高帧率片源。
///
/// ## 模式（Mode A/B/C）怎么选的
///
/// 上游有 A/B/C 三种，区别是初始 Restore 的类型：
///   A = Restore          → 模糊多的片源（老 SD 番、DVD）★ 本功能主场景
///   B = Restore_Soft     → 降采样伪影/锯齿多的片源
///   C = Upscale_Denoise  → 几乎无损伤的片源（PSNR 最高但观感一般）
///
/// 用户说「老番分辨率太低想放大」，正好是 Mode A 的最佳场景，所以
/// 主推 A；B/C 作为可选项留给不同片源。
enum Anime4kMode {
  /// 关闭
  off,

  /// 极轻量：DoG 放大 + 轻微去模糊（非 CNN，几乎不耗 GPU）
  light,

  /// Mode A + S 档（推荐：老番修复效果明显，手机可实时）
  standard,

  /// Mode A + M 档（画质更好，中端机以上）
  high,

  /// Mode A + L 档（最清晰，仅旗舰机 / 低帧率片源）
  ultra,

  /// Mode B + S 档（适合降采样/锯齿多的片源）
  restoreSoft,

  /// Mode C + S 档（片源本身很干净，只做放大+降噪）
  clean,
}

/// Anime4K 的平台可用性。
///
/// 与 HDR 输出模式相同：需要 `vo=gpu-next` + libplacebo，只有 Android
/// 的自建 libmpv 满足（见 tools/build_android_libmpv.sh）。
/// iOS / 桌面暂不支持。
bool get anime4kSupported {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

extension Anime4kModeX on Anime4kMode {
  /// 持久化用的稳定标识。
  String get id => switch (this) {
        Anime4kMode.off => 'off',
        Anime4kMode.light => 'light',
        Anime4kMode.standard => 'standard',
        Anime4kMode.high => 'high',
        Anime4kMode.ultra => 'ultra',
        Anime4kMode.restoreSoft => 'restore_soft',
        Anime4kMode.clean => 'clean',
      };

  String get label => switch (this) {
        Anime4kMode.off => '关闭',
        Anime4kMode.light => '极轻量',
        Anime4kMode.standard => '标准（推荐）',
        Anime4kMode.high => '高画质',
        Anime4kMode.ultra => '最高画质',
        Anime4kMode.restoreSoft => '柔化修复',
        Anime4kMode.clean => '纯净片源',
      };

  String get shortLabel => switch (this) {
        Anime4kMode.off => '关闭',
        Anime4kMode.light => '极轻量',
        Anime4kMode.standard => '标准',
        Anime4kMode.high => '高画质',
        Anime4kMode.ultra => '最高',
        Anime4kMode.restoreSoft => '柔化',
        Anime4kMode.clean => '纯净',
      };

  String get description => switch (this) {
        Anime4kMode.off => '不做放大处理',
        Anime4kMode.light => '非 CNN，几乎不耗 GPU；适合低端机',
        Anime4kMode.standard => '修复模糊+压缩伪影，手机可实时；适合老番',
        Anime4kMode.high => '效果更好，需中端以上 GPU',
        Anime4kMode.ultra => '最清晰，仅旗舰机或低帧率片源',
        Anime4kMode.restoreSoft => '适合降采样、锯齿明显的片源',
        Anime4kMode.clean => '片源干净，只做放大+降噪',
      };

  bool get needsGpuNext => this != Anime4kMode.off;

  /// 当前平台能否用。
  bool get isAvailable => !needsGpuNext || anime4kSupported;

  /// 该档位用到的 shader 文件名（按执行顺序）。
  ///
  /// ## 顺序规则（来自上游 Advanced 文档）
  ///
  /// 1. `Clamp_Highlights` 放最前（防 overshoot / ringing）
  /// 2. 必须**先 Restore / Denoise，再 Upscale** —— 先放大再修复会让
  ///    伪影更难处理，且放大后每个 shader 的耗时变成 4 倍
  /// 3. 整个管线至少放大 4x（模式定义要求）
  /// 4. `AutoDownscalePre` 放在两次 Upscale 之间
  /// 5. **同一个 shader 文件不能用两次** —— 上游原话：
  ///    "You can only use each shader file once. Using the same file two
  ///     or more times causes buggy behaviour and loss of performance."
  ///    所以 Mode A（Restore → Upscale → Upscale）的第二次放大**必须**
  ///    换一个变体文件，不能复用同一份。
  ///
  /// ## 变体递降策略
  ///
  /// 第 5 条决定了链里要有两个不同的 Upscale 文件。上游建议「第二次用
  /// 比第一次低两档的变体」（因为放大后耗时 4 倍，降档能抵消）。
  /// 这里按档位选：
  ///   - standard(S) → 第二次用 DoG（非 CNN，最省）
  ///   - high(M)     → 第二次用 S
  ///   - ultra(L)    → 第二次用 M
  ///
  /// ## 关于 `//!WHEN` 自动跳过
  ///
  /// 这些 shader 带 `//!WHEN OUTPUT.w MAIN.w / 1.200 >` 条件：放大倍数
  /// 不到 1.2 倍时**整个 shader 会被跳过**。所以 1080p 番在 1080p 屏上
  /// 播时几乎零开销，只有低分辨率老番才真正付 GPU 代价。
  List<String> get shaderChain => switch (this) {
        Anime4kMode.off => const [],
        // 极轻量：DoG 是非 CNN（几个卷积核），放大 x2 + 轻微去模糊
        Anime4kMode.light => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Deblur_DoG.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        // Mode A + S：Restore(S) → Upscale(S) → AutoDownscale → Upscale(DoG)
        // 第二次放大用 DoG：S 已经是最低 CNN 档，不能再降，用非 CNN 替代
        Anime4kMode.standard => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_S.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        // Mode A + M：Restore(M) → Upscale(M) → 降两档到 DoG
        // （M 的两档以下是「非 CNN」，比 S 更省；上游建议降两档抵消 4x 开销）
        Anime4kMode.high => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_M.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
          ],
        // Mode A + L：Restore(L) → Upscale(L) → 降两档到 M
        Anime4kMode.ultra => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_L.glsl',
            'Anime4K_Upscale_CNN_x2_L.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
          ],
        // Mode B + S：Restore_Soft(S) → Upscale(S) → 降级到 DoG
        Anime4kMode.restoreSoft => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_Soft_S.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        // Mode C + S：Upscale_Denoise(S) → Upscale(DoG)
        // Mode C 以 Upscale_Denoise 开头（等价于 Denoise + Upscale 一体）
        Anime4kMode.clean => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
      };

  /// 相对 GPU 负载（1 = 极轻量，仅用于 UI 提示，不是精确基准）。
  ///
  /// 依据上游说明「每上一档 CNN，耗时翻倍」估算。
  int get gpuWeight => switch (this) {
        Anime4kMode.off => 0,
        Anime4kMode.light => 1,
        Anime4kMode.standard => 4,
        Anime4kMode.high => 8,
        Anime4kMode.ultra => 16,
        Anime4kMode.restoreSoft => 4,
        Anime4kMode.clean => 3,
      };

  static Anime4kMode fromId(String? id) {
    if (id == null) return Anime4kMode.off;
    for (final m in Anime4kMode.values) {
      if (m.id == id) return m;
    }
    return Anime4kMode.off;
  }
}
