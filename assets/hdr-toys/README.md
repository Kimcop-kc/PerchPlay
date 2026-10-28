# hdr-toys（内置副本）

本目录是 [natural-harmonia-gropius/hdr-toys](https://github.com/natural-harmonia-gropius/hdr-toys)
的着色器副本，用于 PerchPlay 的「HDR 输出模式」功能。

## 来源

- 上游：https://github.com/natural-harmonia-gropius/hdr-toys
- 许可：MIT（见同目录 `LICENSE`）
- 版本：master 分支，2026-10 快照

## 用途

这些 `.glsl` 是 **mpv 的 hook 式着色器**（依赖 libplacebo 的 shader
hook 机制）。它们负责把 HDR 片源（PQ / HLG）或广色域片源准确转换成
目标色彩空间，是 mpv 原生 tone-mapping 之外的另一种选择 —— 对
HDR10 / 杜比视界基础层这类片源，观感通常比 `tone-mapping=bt.2390`
更接近系统相册。

## 硬性要求

1. **必须 `vo=gpu-next`**（`gpu` / `libmpv` 后端都不支持 hook 着色器）
2. **必须 libmpv 编译时带 `-Dlibplacebo=enabled -Dvulkan=enabled
   -Dshaderc=enabled`**

media-kit 官方发布的 Android libmpv 这三项全是 `disabled`，所以官方库
用不了。本项目改用自建 libmpv（见仓库根目录 `tools/patch_libplacebo.sh`
与 `tools/build_android_libmpv.sh`）。

启动时若检测到 libmpv 不带 libplacebo，应把 HDR 输出模式强制回退到
「关闭」，否则 `glsl-shader` 会被静默忽略（画面正常但没有任何 HDR 效果，
容易误判成 bug）。

## 不要做的事

上游 README 明确要求：启用这些 shader 时**不要**再设置以下 mpv 参数，
否则会二次处理导致偏色或过曝：

- `target-peak`
- `icc-profile` / `icc-profile-auto`
- `tone-mapping`（hdr-toys 用 `clip`，主流程不要覆盖成 `bt.2390`）
- `gamut-mapping-mode`（用 `clip`）

## 目录结构

```
shaders/hdr-toys/
├── utils/               # 裁切、曝光、色域变换等基础工具
├── transfer-function/   # 传递函数互转（pq_inv / hlg_inv / bt1886 / bt1886_inv …）
├── tone-mapping/        # astra（tone-mapping 算法）
└── gamut-mapping/       # bottosson / clip 等色域映射
```

共 83 个 `.glsl`，约 404 KB。没有 `#include` 之类跨文件引用，
按目录整棵复制到磁盘即可被 mpv 加载。

## 各档位的 shader 链

见 `lib/services/hdr_output_mode.dart` 里 `HdrOutputMode.shaderChain`，
顺序必须与上游 `hdr-toys.conf` 保持一致（先线性化 → tone-map →
色域映射 → 回目标传递函数）。
