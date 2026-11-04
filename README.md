# PerchPlay

全功能本地视频播放器，Flutter 编写，支持 **Android / iOS / iPadOS**。播放内核
[media_kit](https://github.com/media-kit/media-kit)（libmpv），界面为玻璃拟态风格。

当前版本 **1.2.1**。

---

## 功能

### 播放

- 21 种常见视频格式（`mp4 / mkv / avi / mov / ts / rmvb …`）
- 硬件解码开关、倍速 0.25x–3.0x、断点续播、播放队列连播
- 内嵌音轨切换、内嵌/外挂字幕（`SRT / ASS / VTT`）、**双字幕同屏**
- 视频详情：分辨率、编码、帧率、音轨、时长、大小、完整路径等
- 播放页手势：左侧滑调亮度 · 右侧滑调音量 · 水平滑快进快退 · 双击播放/暂停
- 全平台键盘快捷键：`Space` 播放 · `←/→` 快退/快进 · `↑/↓` 音量 · `F` 全屏 等

### 画质增强

- **HDR 输出模式**（gpu-next + hdr-toys）：HDR 片源直通输出
- **Anime4K 动漫放大**（S/M/L 三档，掉帧自动降档）
- 两者互斥，均需自建 libplacebo 版 libmpv（见 CI）

### 资源库

- MediaStore 秒扫 + 文件系统回退，视频缩略图
- **按文件名自动分组播放列表**（识别 `S01E02` / `第02集` / `EP05` 等季集标记）
- 列表内容可自由增删，删除的自动列表可恢复
- TMDB 刮削（海报/简介/评分）、文件夹浏览、观看历史

### 投屏（DLNA）

- SSDP 局域网发现 + 手动填 IP，解析真实 controlURL
- 内置 HTTP 媒体服务把本地文件暴露给电视（支持 Range）
- 远程视频（NAS/网盘）经局域网转发代理投屏，投屏遥控含音量/快进快退

> Chromecast / AirPlay 未实现，界面上不会谎报「已连接」。

### 网络存储

- **云盘**：夸克 / 115 / 百度 / 阿里（内嵌 WebView 登录，直链播放走本地串流代理）
- **NAS**：WebDAV / FTP / SMB（局域网自动发现品牌识别）
- 网盘视频自动加载同目录外挂字幕（复用播放鉴权）

### 其他

- 崩溃日志（Dart 落盘 + Android/iOS 原生捕获），「设置 → 诊断日志」一键复制
- 应用内检查更新（GitHub 直下 APK + 网盘下载通道）

---

## 快速开始

```bash
flutter pub get
flutter run                # 连接设备/模拟器后
```

构建：

```bash
flutter build apk --release          # 通用 APK
flutter build apk --split-per-abi    # 分 ABI
flutter build appbundle --release    # Google Play 用 AAB
flutter build ios --release          # iOS（需 macOS + Xcode）
```

- Android release 构建无 keystore 时回退 debug 签名，clone 后可直接构建；
  正式发布需在 `android/key.properties` 配置 keystore（已 gitignore）。
- iOS 首次需在 Xcode 设置 **Signing Team**，打开 `Runner.xcworkspace`。

### 权限（Android）

- Android 13+：`READ_MEDIA_VIDEO`（弹窗授权）
- Android 11+：可另开「所有文件访问权限」扫描更完整

---

## 测试与 CI

```bash
flutter analyze --no-fatal-infos
flutter test
```

446 项测试（3 项在缺本地假服务时自动跳过）。需跑全量时先起假服务：

```bash
python tools/fake_dlna_renderer.py 8099   # 投屏：假 DLNA 渲染器
python tools/fake_nas.py                  # NAS：假 WebDAV/群晖
```

CI（GitHub Actions）：

| 工作流 | 触发 | 内容 |
|---|---|---|
| `CI — 代码检查` | push/PR 到 master | analyze + test |
| `Android — 构建 + 自动发版` | push `v*` tag / 手动 | 构建 APK，tag 时发 Release |
| `Android — 构建 APK（可选 libplacebo）` | 手动 | 可选自建 libmpv |
| `iOS — 构建 IPA` | 手动 | ad-hoc IPA |
| `Android — libplacebo 版 libmpv 构建` | 手动 | 构建 gpu-next 内核 |

---

## 技术栈

Flutter 3.47 · media_kit（libmpv）· Riverpod · GoRouter · sqflite · shared_preferences

---

## 尚未实现

- Chromecast / AirPlay 投屏（现仅 DLNA）
- iOS 画中画
- NFS 网络存储
- AB 循环、视频截图、均衡器、深浅色主题切换

---

## License

MIT
