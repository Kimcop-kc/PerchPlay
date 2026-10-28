import 'dart:io';

import 'package:flutter/foundation.dart';

/// Anime4K 动漫放大档位。
///
/// ## 这套东西是干什么的
///
/// Anime4K 是一组 mpv 的 GLSL hook 着色器，用 CNN 做**实时放大 + 线条
/// 修复**。它的目标场景是「1080p 动漫放到 4K 屏幕」，但对本项目更有价值
/// 的是另一个方向：**480p/720p 老番在手机上放大**——那类片源模糊严重、
/// 压缩弥散明显，正是 Mode A 最擅长的情况。
///
/// ## 与 HDR 输出模式互斥
///
/// 两者都往 mpv 的 `glsl-shader` 列表塞文件、都假设独占 `MAIN` hook
/// 阶段。叠加会让 shader 链互相干扰（Anime4K 的 `//!WHEN` 条件按放大
/// 倍数判断，HDR 的传递函数转换会改变管线宽度），且 GPU 负担翻倍。
/// 所以代码里强制二选一（见 PlayerNotifier._applyVideoFilters）。
///
/// ## 档位怎么组织的
///
/// 上游有 S/M/L/VL/UL/UUL 六档 CNN，外加 GAN 变体。命名规律：
/// **每上一档，耗时翻倍**（官方原话）。
///
/// 本项目按「模式 × CNN 档」组合出档位，而不是把 6 档全铺开：
///   - Mode A（Restore）      → 老番/模糊片源 ★ 主场景
///   - Mode B（Restore_Soft） → 降采样伪影/锯齿
///   - Mode C（Upscale_Denoise）→ 片源干净时
///
/// 每档的 CNN 级别从 S 递增到 UUL，用户按自己的 GPU 选。
///
/// ## 关于「低倍率自动跳过」
///
/// 这些 shader 带 `//!WHEN OUTPUT.w MAIN.w / 1.200 >` 条件：放大倍数
/// 不到 1.2 倍时**整个 shader 会被跳过**。所以：
///   - 1080p 番在 1080p 屏 → 约 1.0 倍 → 几乎零开销
///   - 480p 番在 1080p 屏 → 2.25 倍 → 真正开始干活
/// 这也是为什么开这个功能不会拖慢普通高清片源。
enum Anime4kMode {
  /// 关闭
  off,

  /// 极轻量：非 CNN（DoG），几乎不耗 GPU
  light,

  // ── Mode A：Restore（老番/模糊片源，推荐）──
  /// Mode A + S 档
  modeAS,

  /// Mode A + M 档
  modeAM,

  /// Mode A + L 档
  modeAL,

  /// Mode A + VL 档
  modeAVL,

  /// Mode A + UL 档
  modeAUL,

  // ── Mode B：Restore_Soft（降采样伪影/锯齿）──
  /// Mode B + S 档
  modeBS,

  /// Mode B + M 档
  modeBM,

  /// Mode B + L 档
  modeBL,

  // ── Mode C：Upscale_Denoise（片源干净）──
  /// Mode C + S 档
  modeCS,

  /// Mode C + M 档
  modeCM,

  /// Mode C + L 档
  modeCL,

  // ── GAN：上游高质量变体（极耗 GPU）──
  /// GAN + S 档放大
  ganS,

  /// GAN + M 档放大
  ganM,

  /// GAN + L 档 x3 放大
  ganL,

  /// GAN + UUL 档 x4 放大（最高画质，旗舰机专用）
  ganUUL,
}

/// Anime4K 的平台可用性。
///
/// 需要 `vo=gpu-next` + libplacebo，只有 Android 的自建 libmpv 满足
/// （见 tools/build_android_libmpv.sh）。iOS 没有原生 Vulkan，暂不支持。
bool get anime4kSupported {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

extension Anime4kModeX on Anime4kMode {
  /// 持久化用的稳定标识。**不要改**，否则老用户的设置会失效。
  String get id => switch (this) {
        Anime4kMode.off => 'off',
        Anime4kMode.light => 'light',
        Anime4kMode.modeAS => 'a_s',
        Anime4kMode.modeAM => 'a_m',
        Anime4kMode.modeAL => 'a_l',
        Anime4kMode.modeAVL => 'a_vl',
        Anime4kMode.modeAUL => 'a_ul',
        Anime4kMode.modeBS => 'b_s',
        Anime4kMode.modeBM => 'b_m',
        Anime4kMode.modeBL => 'b_l',
        Anime4kMode.modeCS => 'c_s',
        Anime4kMode.modeCM => 'c_m',
        Anime4kMode.modeCL => 'c_l',
        Anime4kMode.ganS => 'gan_s',
        Anime4kMode.ganM => 'gan_m',
        Anime4kMode.ganL => 'gan_l',
        Anime4kMode.ganUUL => 'gan_uul',
      };

  String get label => switch (this) {
        Anime4kMode.off => '关闭',
        Anime4kMode.light => '极轻量',
        Anime4kMode.modeAS => '标准（A + S）',
        Anime4kMode.modeAM => '较好（A + M）',
        Anime4kMode.modeAL => '高画质（A + L）',
        Anime4kMode.modeAVL => '很高（A + VL）',
        Anime4kMode.modeAUL => '极高（A + UL）',
        Anime4kMode.modeBS => '柔化（B + S）',
        Anime4kMode.modeBM => '柔化（B + M）',
        Anime4kMode.modeBL => '柔化（B + L）',
        Anime4kMode.modeCS => '纯净（C + S）',
        Anime4kMode.modeCM => '纯净（C + M）',
        Anime4kMode.modeCL => '纯净（C + L）',
        Anime4kMode.ganS => 'GAN 初阶',
        Anime4kMode.ganM => 'GAN 中阶',
        Anime4kMode.ganL => 'GAN 高阶（x3）',
        Anime4kMode.ganUUL => 'GAN 极致（x4）',
      };

  String get shortLabel => switch (this) {
        Anime4kMode.off => '关闭',
        Anime4kMode.light => '极轻量',
        Anime4kMode.modeAS => 'A+S',
        Anime4kMode.modeAM => 'A+M',
        Anime4kMode.modeAL => 'A+L',
        Anime4kMode.modeAVL => 'A+VL',
        Anime4kMode.modeAUL => 'A+UL',
        Anime4kMode.modeBS => 'B+S',
        Anime4kMode.modeBM => 'B+M',
        Anime4kMode.modeBL => 'B+L',
        Anime4kMode.modeCS => 'C+S',
        Anime4kMode.modeCM => 'C+M',
        Anime4kMode.modeCL => 'C+L',
        Anime4kMode.ganS => 'GAN-S',
        Anime4kMode.ganM => 'GAN-M',
        Anime4kMode.ganL => 'GAN-L',
        Anime4kMode.ganUUL => 'GAN-UUL',
      };

  String get description => switch (this) {
        Anime4kMode.off => '不做放大处理',
        Anime4kMode.light => '非 CNN，几乎不耗 GPU；低端机首选',
        Anime4kMode.modeAS => '修复模糊+压缩伪影，手机基本都能实时；老番推荐',
        Anime4kMode.modeAM => '比 S 档清晰一倍耗时；中端机以上',
        Anime4kMode.modeAL => '更清晰；需较强 GPU',
        Anime4kMode.modeAVL => '很清晰；仅旗舰机，注意发热',
        Anime4kMode.modeAUL => '最难同时最清晰；通常只有低帧率片源能跑',
        Anime4kMode.modeBS => '适合降采样、锯齿明显的片源',
        Anime4kMode.modeBM => '柔化 + 更高画质',
        Anime4kMode.modeBL => '柔化 + 最高画质；需强 GPU',
        Anime4kMode.modeCS => '片源干净，只做放大+降噪',
        Anime4kMode.modeCM => '纯净 + 更高画质',
        Anime4kMode.modeCL => '纯净 + 最高画质',
        Anime4kMode.ganS => 'GAN 变体，观感更自然但很耗 GPU',
        Anime4kMode.ganM => 'GAN 中阶，仅旗舰机可试',
        Anime4kMode.ganL => 'GAN x3 放大，极耗 GPU',
        Anime4kMode.ganUUL => '最高档，基本只能用于截图或极低帧率',
      };

  bool get needsGpuNext => this != Anime4kMode.off;

  /// 当前平台能否用。
  bool get isAvailable => !needsGpuNext || anime4kSupported;

  /// 该档位用到的 shader 文件名（按执行顺序）。
  ///
  /// ## 上游的硬规则（测试全部锁住）
  ///
  /// 1. `Clamp_Highlights` 放最前（防 overshoot / ringing）
  /// 2. **必须先 Restore / Denoise，再 Upscale** —— 先放大再修复会让
  ///    伪影更难处理，且放大后每个 shader 耗时变成 4 倍
  /// 3. `AutoDownscalePre` 放在两次 Upscale 之间
  /// 4. **同一个 shader 文件不能用两次** —— 上游原话：
  ///    "You can only use each shader file once. Using the same file two
  ///     or more times causes buggy behaviour and loss of performance."
  ///    所以 Mode A（Restore → Upscale → Upscale）的第二次放大必须换变体。
  ///
  /// ## 第二次放大为什么降档
  ///
  /// 规则 4 要求两个不同的 Upscale 文件。上游建议「第二次用低两档的变体」
  /// ——因为放大后像素数变为 4 倍，shader 耗时也变 4 倍，降档能抵消。
  ///
  /// ## GAN 档的特殊性
  ///
  /// GAN 变体自带 x2/x3/x4 的放大倍数（文件名里带），不需要两次 x2
  /// 叠加。所以 GAN 链更短：Restore(GAN) → Upscale(GAN, xN)。
  List<String> get shaderChain => switch (this) {
        Anime4kMode.off => const [],

        // 极轻量：DoG 是非 CNN，放大 x2 + 轻微去模糊
        Anime4kMode.light => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Deblur_DoG.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],

        // ── Mode A ──
        Anime4kMode.modeAS => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_S.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        Anime4kMode.modeAM => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_M.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
          ],
        Anime4kMode.modeAL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_L.glsl',
            'Anime4K_Upscale_CNN_x2_L.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
          ],
        Anime4kMode.modeAVL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_VL.glsl',
            'Anime4K_Upscale_CNN_x2_VL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_L.glsl',
          ],
        Anime4kMode.modeAUL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_UL.glsl',
            'Anime4K_Upscale_CNN_x2_UL.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_VL.glsl',
          ],

        // ── Mode B（Restore_Soft）──
        Anime4kMode.modeBS => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_Soft_S.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        Anime4kMode.modeBM => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_Soft_M.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
          ],
        Anime4kMode.modeBL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_CNN_Soft_L.glsl',
            'Anime4K_Upscale_CNN_x2_L.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
          ],

        // ── Mode C（Upscale_Denoise 开头，自带放大）──
        Anime4kMode.modeCS => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_DoG_x2.glsl',
          ],
        Anime4kMode.modeCM => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_S.glsl',
          ],
        Anime4kMode.modeCL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Upscale_Denoise_CNN_x2_L.glsl',
            'Anime4K_AutoDownscalePre_x2.glsl',
            'Anime4K_Upscale_CNN_x2_M.glsl',
          ],

        // ── GAN（自带 x2/x3/x4，不必两次 x2 叠加）──
        Anime4kMode.ganS => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_GAN_UL.glsl',
            'Anime4K_Upscale_GAN_x2_S.glsl',
          ],
        Anime4kMode.ganM => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_GAN_UL.glsl',
            'Anime4K_Upscale_GAN_x2_M.glsl',
          ],
        Anime4kMode.ganL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_GAN_UL.glsl',
            'Anime4K_Upscale_GAN_x3_L.glsl',
          ],
        Anime4kMode.ganUUL => const [
            'Anime4K_Clamp_Highlights.glsl',
            'Anime4K_Restore_GAN_UUL.glsl',
            'Anime4K_Upscale_GAN_x4_UUL.glsl',
          ],
      };

  /// 相对 GPU 负载（仅用于 UI 提示与自动降档排序）。
  ///
  /// 依据上游「每上一档 CNN 耗时翻倍」估算，以 S 为基准 4。
  /// **不是精确基准**，真实性能受显存带宽、驱动优化、发热影响。
  int get gpuWeight => switch (this) {
        Anime4kMode.off => 0,
        Anime4kMode.light => 1,
        Anime4kMode.modeAS => 4,
        Anime4kMode.modeAM => 8,
        Anime4kMode.modeAL => 16,
        Anime4kMode.modeAVL => 32,
        Anime4kMode.modeAUL => 64,
        Anime4kMode.modeBS => 4,
        Anime4kMode.modeBM => 8,
        Anime4kMode.modeBL => 16,
        Anime4kMode.modeCS => 3,
        Anime4kMode.modeCM => 6,
        Anime4kMode.modeCL => 12,
        // GAN 明显比同档 CNN 重，按 4 倍估
        Anime4kMode.ganS => 64,
        Anime4kMode.ganM => 128,
        Anime4kMode.ganL => 256,
        Anime4kMode.ganUUL => 512,
      };

  /// 自动降档时的下一档（null 表示已是最低档）。
  ///
  /// 降档策略：**在同一模式内降一级**，降到 S 后回退到「极轻量」。
  /// 不跨模式跳（A 降到 B 会改变画质风格，用户会困惑）。
  Anime4kMode? get lowerTier => switch (this) {
        Anime4kMode.off => null,
        Anime4kMode.light => null,
        Anime4kMode.modeAS => Anime4kMode.light,
        Anime4kMode.modeAM => Anime4kMode.modeAS,
        Anime4kMode.modeAL => Anime4kMode.modeAM,
        Anime4kMode.modeAVL => Anime4kMode.modeAL,
        Anime4kMode.modeAUL => Anime4kMode.modeAVL,
        Anime4kMode.modeBS => Anime4kMode.light,
        Anime4kMode.modeBM => Anime4kMode.modeBS,
        Anime4kMode.modeBL => Anime4kMode.modeBM,
        Anime4kMode.modeCS => Anime4kMode.light,
        Anime4kMode.modeCM => Anime4kMode.modeCS,
        Anime4kMode.modeCL => Anime4kMode.modeCM,
        Anime4kMode.ganS => Anime4kMode.modeAS,
        Anime4kMode.ganM => Anime4kMode.ganS,
        Anime4kMode.ganL => Anime4kMode.ganM,
        Anime4kMode.ganUUL => Anime4kMode.ganL,
      };

  /// 是否属于「高负载」档（自动降档时会优先提示用户）。
  bool get isHeavy => gpuWeight >= 16;

  static Anime4kMode fromId(String? id) {
    if (id == null) return Anime4kMode.off;
    for (final m in Anime4kMode.values) {
      if (m.id == id) return m;
    }
    return Anime4kMode.off;
  }
}
