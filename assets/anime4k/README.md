# Anime4K（内置副本）

本目录是 [bloc97/Anime4K](https://github.com/bloc97/Anime4K) 的着色器子集，
用于 PerchPlay 的「动漫放大」功能。

## 来源

- 上游：https://github.com/bloc97/Anime4K
- 许可：MIT（见同目录 `LICENSE`）
- 版本：master 分支，2026-10 快照（v4.x）

## 为什么只取这 15 个文件

上游有 S/M/L/VL/UL/UUL 六档 CNN 和多种 GAN 变体。本项目只取 **S/M/L**
三档 + 非 CNN 的 DoG 方案，理由：

1. **体积**：`Upscale_CNN_x2_UL` 单个 283 KB，`GAN_x4_UUL` 1 MB。
   手机 GPU 上必然掉帧，白白让 APK 变大。
2. **性能**：官方数据基于 Vega64 桌面显卡，`UL` 在 1080p→4K 就已吃满
   24fps 的 41ms 预算。手机 GPU 大约是它 1/5~1/15。

## 硬性要求

与 hdr-toys 相同：需要 `vo=gpu-next` + libmpv 带 libplacebo / vulkan /
shaderc。只有本项目的自建 libmpv 满足（见仓库根目录
`tools/build_android_libmpv.sh`）。iOS 没有原生 Vulkan，暂不支持。

## 与 HDR 输出模式互斥

两者都往 mpv 的 `glsl-shader` 列表里塞文件、都假设独占 `MAIN` hook
阶段。叠加会让 shader 链互相干扰（Anime4K 的 `//!WHEN` 条件按放大倍数
判断，HDR 的传递函数转换会改变管线宽度），且 GPU 负担翻倍。
所以代码里强制二选一，见 `lib/providers/player_provider.dart` 的
`_applyVideoFilters`。

## 上游的两条硬规则（代码里有测试锁住）

1. **同一个 shader 文件不能用两次**
   上游原话："You can only use each shader file once. Using the same
   file two or more times causes buggy behaviour and loss of performance."
   → 所以 Mode A（Restore → Upscale → Upscale）的第二次放大必须换变体。
2. **必须先 Restore/Denoise，再 Upscale**
   先放大再修复会让伪影更难处理，且放大后每个 shader 耗时变成 4 倍。

## 关于「低倍率自动跳过」

这些 shader 带 `//!WHEN OUTPUT.w MAIN.w / 1.200 >` 条件：放大倍数不到
1.2 倍时整个 shader 会被跳过。所以：

- 1080p 番在 1080p 屏 → 约 1.0 倍 → **几乎零开销**
- 480p 番在 1080p 屏 → 2.25 倍 → 真正开始干活（也正是需要的场景）

这也是为什么开这个功能不会拖慢普通高清片源。

## 文件清单

```
Anime4K_Clamp_Highlights.glsl          2.7 KB  防 overshoot / ringing
Anime4K_Restore_CNN_S/M/L.glsl        16.7/35.1/68.3 KB   Mode A 修复
Anime4K_Restore_CNN_Soft_S/M.glsl     16.8/35.2 KB        Mode B 修复
Anime4K_Upscale_CNN_x2_S/M/L.glsl     18.2/36.8/71.7 KB   放大 x2
Anime4K_Upscale_Denoise_CNN_x2_S/M    18.2/36.8 KB        Mode C 起点
Anime4K_Deblur_DoG.glsl                4.4 KB  非 CNN 去模糊
Anime4K_Upscale_DoG_x2.glsl            3.9 KB  非 CNN 放大
Anime4K_AutoDownscalePre_x2/x4.glsl    1.5 KB  两次放大之间先缩到屏宽
```
