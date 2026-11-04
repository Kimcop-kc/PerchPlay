# PerchPlay

一个用 Flutter 写的本地视频播放器，同时支持 **Android / iOS / iPadOS**，播放内核是 [media_kit](https://github.com/media-kit/media-kit)（libmpv）。

![version](https://img.shields.io/badge/version-1.2.1-blue)
![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20iPadOS-green)
![license](https://img.shields.io/badge/license-MIT-orange)

---

## ✨ 特性

### 播放

- 21 种视频格式、硬件解码开关、倍速 0.25x–3.0x
- 断点续播、剧集连播队列、内嵌音轨切换
- 外挂字幕 `SRT / ASS / VTT`、双字幕同屏
- 手势：左滑亮度 · 右滑音量 · 横滑进度 · 双击暂停

### 画质

- **HDR 输出模式**（gpu-next + hdr-toys）
- **Anime4K 动漫放大**（S/M/L 三档，掉帧自动降档）

### 资源库

- MediaStore 秒扫 + 缩略图
- 按文件名自动分组播放列表（`S01E02` / `第02集` / `EP05`）
- TMDB 刮削海报与简介

### 投屏 · 网络存储

- **DLNA 投屏**：SSDP 发现、局域网转发代理、遥控音量/进度
- **云盘**：夸克 / 115 / 百度 / 阿里，同目录字幕自动加载
- **NAS**：WebDAV / FTP / SMB

### 其他

- 崩溃日志落盘，设置页一键复制
- 应用内检查更新

---

## 📥 下载

最新版安装包见 [Releases](https://github.com/Kimcop-kc/PerchPlay/releases)：

- Android：`PerchPlay-*-arm64-v8a.apk`
- iOS：`PerchPlay-*.ipa`（需自行重签名）

---

## 🔨 构建

```bash
flutter pub get
flutter run

# 发布
flutter build apk --release
flutter build ios --release
```

> Android 无 keystore 时回退 debug 签名；iOS 首次需在 Xcode 设置 Signing Team。

---

## 🧪 测试

```bash
flutter analyze --no-fatal-infos
flutter test
```

446 项测试。需要本地假服务时：

```bash
python tools/fake_dlna_renderer.py 8099
python tools/fake_nas.py
```

---

## 🛠 技术栈

Flutter 3.47 · media_kit · Riverpod · GoRouter · sqflite

---

## 📄 License

[MIT](LICENSE)
