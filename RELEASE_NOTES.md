# PerchPlay v1.1.8

修复 **iOS 画面发绿 / 发洋红**，新增 **HDR 输出模式**（Android）。

---

## 修复：iOS 所有视频发绿 / 发洋红

**现象**：iOS 上播放任何视频，整幅画面发绿或发洋红，与片源无关。

**根因**：上一个版本为了解决 Android 的偏色，在 HDR 和 SDR 两个分支都
无条件设置了 `target-prim=bt.709` / `target-trc=bt.1886`。

这两个参数在 **Android**（`vo=gpu`，OpenGL ES + SurfaceFlinger）下是
**必须的** —— 不设的话 mpv 用默认猜测做色彩空间转换，老片源的
bt.601 / bt.2020 会被推断错。

但 **iOS** 走的是完全不同的路径（`vo=libmpv`，mpv 自己渲染成 RGB
再经 Flutter 纹理回传）。这条路径下 mpv 已在内部完成 YUV→RGB，
再强行指定目标色彩空间会让它**多做一次转换**（矩阵套两遍），
结果就是整幅发绿 / 发洋红。

**修复**：三处全部改成按平台区分，只在 Android 上设置
（HDR 分支 / SDR 分支 / 打开新文件前的复位）。

---

## 新增：HDR 输出模式（Android）

新增 5 档 HDR 输出模式，走 GPU-Next 渲染管线 + hdr-toys 着色器，
由 libplacebo 做精确色彩转换：

| 档位 | 适用 |
|---|---|
| 关闭（SDR） | 默认，兼容性最好 |
| BT.2100 PQ | HDR10 / 杜比视界 PQ 片源 |
| BT.2100 HLG | HLG 片源（杜比 8.4 基础层） |
| BT.2020 | SDR 片源用广色域，颜色更艳 |
| 线性 HDR | HDR 显示器 / 专业监看 |

**入口**：播放页顶部栏的 HDR 按钮，或直接点文件名旁的 HDR / 杜比视界角标。
设置页「播放」分组里也有常驻入口。

**注意**：

- 默认关闭。开启后会重建渲染器，画面闪一下是正常的。
- 需要 Android + 带 libplacebo 的构建版本（本次已提供）。
  其它平台（含 iOS）选项会置灰 —— iOS 没有原生 Vulkan，暂时无法支持。
- 该版本的 APK 体积会比常规版大一些（多约 11 MB），是 libplacebo +
  shaderc + Vulkan 的成本。

---

## 其他

- 播放页 HDR 入口对 **SDR 片源也可用**（「BT.2020」档就是给 SDR 用的）
- 新增 31 项 HDR 模式回归测试

---

## 安装

- **Android**：下载 `PerchPlay-v1.1.8-arm64-v8a.apk`
- **iOS**：下载对应的 `.ipa`（ad-hoc 分发，需自行重签名）
