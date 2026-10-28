# Anime4K（内置副本）

本目录是 [bloc97/Anime4K](https://github.com/bloc97/Anime4K) 的着色器副本，
用于 PerchPlay 的「动漫放大」功能。

## 来源

- 上游：https://github.com/bloc97/Anime4K
- 许可：MIT（见同目录 `LICENSE`）
- 版本：master 分支，2026-10 快照（v4.x）

## 内容范围

**全档位**，共 33 个 `.glsl`，合计约 5.3 MB：

- `Restore_CNN` S/M/L/VL/UL（Mode A，针对模糊/压缩伪影）
- `Restore_CNN_Soft` S/M/L/VL/UL（Mode B，针对降采样伪影/锯齿）
- `Upscale_CNN_x2` S/M/L/VL/UL
- `Upscale_Denoise_CNN_x2` S/M/L/VL/UL（Mode C 起点）
- `GAN` 变体 x2_S/M、x3_L/VL、x4_UL/UUL
- 非 CNN 的 DoG 方案（`Deblur_DoG`、`Upscale_DoG_x2`）
- `Clamp_Highlights`、`AutoDownscalePre_x2/x4`

**排除**：`Experimental-Effects`（实验性，非放大用途）、
`3DGraphics` 变体（针对 3D 渲染画面，与动漫无关）。

## 硬性要求

与 hdr-toys 相同：需要 `vo=gpu-next` + libmpv 带 libplacebo / vulkan /
shaderc。只有本项目的自建 libmpv 满足（见仓库根目录
`tools/build_android_libmpv.sh`）。iOS 没有原生 Vulkan，暂不支持。

## 与 HDR 输出模式互斥

两者都往 mpv 的 `glsl-shader` 列表里塞文件、都假设独占 `MAIN` hook
阶段。叠加会让 shader 链互相干扰，且 GPU 负担翻倍。
代码里强制二选一，见 `lib/providers/player_provider.dart` 的
`_applyVideoFilters`。

## 上游的三条硬规则（测试锁住）

1. **同一个 shader 文件不能用两次**
   上游原话："You can only use each shader file once. Using the same
   file two or more times causes buggy behaviour and loss of performance."
   → 所以 Mode A（Restore → Upscale → Upscale）的第二次放大必须换变体。
2. **必须先 Restore/Denoise，再 Upscale**
   先放大再修复会让伪影更难处理，且放大后每个 shader 耗时变成 4 倍。
3. **`AutoDownscalePre` 只能放在两次 Upscale 之间**
   它的作用是把第一次放大后的结果先缩到屏宽，让第二次放大正好命中。

## 关于「低倍率自动跳过」

这些 shader 带 `//!WHEN OUTPUT.w MAIN.w / 1.200 >` 条件：放大倍数不到
1.2 倍时整个 shader 会被跳过。所以：

- 1080p 番在 1080p 屏 → 约 1.0 倍 → **几乎零开销**
- 480p 番在 1080p 屏 → 2.25 倍 → 真正开始干活（也正是需要的场景）

这也是为什么开这个功能不会拖慢普通高清片源。

## 自动降档

手机端性能无法预估（上游只给了 Vega64 桌面卡数据），所以实现上不靠
配置表，而是**实测**：见 `lib/services/anime4k_auto_downgrade.dart`。

每 3 秒采样 mpv 的 `frame-drop-count`，算这段时间内**新增**的丢帧
（不是总量）；连续两次超过预算（>3 帧/3秒）就降一档，最多降 4 档。

只降不升 —— 自动升档风险大（某次采样没掉帧不代表稳定，反复升降会让
画面抖）。升档交给用户手动。

## 档位与 shader 的对应

见 `lib/services/anime4k_mode.dart` 的 `shaderChain`。17 个档位
（含关闭），按「模式 × CNN 级别」组织，每档标注了相对 GPU 负载。
