# 变更日志

## [1.1.1] — 2026-10-23

### iOS 本地文件扫描（新功能）

- 扫描沙盒 Documents（配合「文件」App 文件共享）
- 「文件」App 多选导入视频到沙盒
- 照片库视频扫描并导出为本地文件
- 文件夹浏览器 / 字幕候选目录适配 iOS 沙盒路径

### 播放性能

- 高码率/大文件起播更快：本地缓冲 32MB→64MB、降低 probe 开销、预读 10s→2s
- 卡顿掉帧修复：`framedrop=decoder+vo`、`video-sync=audio`、关闭插值
- SDR 片源不再白白消耗 HDR 色调映射开销（原来无条件开启逐帧直方图计算）
- 解码参数（hwdec / 解码线程）改到 open 之前应用，首播才真正生效

### 倍速

- 修复高倍速点不动：配置 `scaletempo2` + 音调校正，倍速上限 2.0x → 3.0x
- 修复换片后倍速被重置为默认值

### 复播黑屏

- open 前先 `stop()` 清理旧渲染上下文
- 播放页同一视频不再重复 open（小窗/后台返回的关键路径）

### 其他

- 刷新/导入慢：修复相册无限重导 bug（改用资产 ID 索引）、后台异步导出、并发复制、单次 stat
- 补齐 libsmb2 的 Linux / Windows 预编译库
- iOS 最低部署目标统一为 15.0

## [1.0.0] — 2025-07-15

### 🎨 iOS 27 Glass Edition

**设计语言全面升级**

- 全页面毛玻璃 BackdropFilter 实时模糊效果 (sigmaX/Y: 20–28)
- 紫青渐变主色调 (#9B7EF0 → #45E0D0)
- 大圆角玻璃卡片 (10px–32px) + 光泽高光
- Spring 弹性动画系统 (mass=1, stiffness=180–300, damping=14–26)
- 5 个可复用玻璃组件：GlassCard / GlassPanel / GlassButton / GlassNavBar / GlassSlider
- 交错入场动画 (fadeSlideUp / scaleIn)

### ⚡ 核心功能

- 🎬 全格式视频播放 (MP4/MKV/AVI/MOV/WMV/FLV/WebM/TS)
- 🖐 手势控制 (亮度/音量/快进/双击暂停)
- 📜 外挂字幕 (SRT/ASS/VTT/内嵌) + 多音轨
- ⚡ 倍速播放 (0.25x–2.0x，15 级)
- 📋 播放列表管理
- 📁 本地文件夹浏览
- 📜 观看历史 + 断点续播
- 🖼 画中画 (PiP) Android/iOS
- 🎧 后台音频播放 + 锁屏控制

### 📺 投屏

- 🔍 SSDP 组播扫描 DLNA/UPnP 设备
- 🔍 HTTP 端口探测 Chromecast (8008) / AirPlay (7000)
- 🎮 DLNA SOAP 协议控制 (Play/Pause/Stop/Seek/SetVolume)
- 📱 Chromecast HTTP JSON WebReceiver
- 📱 AirPlay RTSP 协议支持

### 💾 NAS 网络存储

- 📂 SMB/CIFS 协议支持 (HTTP 探测 + 播放)
- 📂 FTP 协议 (PASV 模式目录列表 + UNIX ls 解析)
- 📂 WebDAV 协议 (PROPFIND XML 解析 + Basic Auth)
- 🔗 自动生成带认证的播放 URL
- 📁 远程文件浏览器 + 路径面包屑导航

### 📱 中国手机品牌优化

- 🇨🇳 小米 MIUI/HyperOS — 电池优化白名单 + 自启动管理
- 🇨🇳 华为 EMUI/HarmonyOS — 电池优化 + 悬浮窗权限
- 🇨🇳 OPPO ColorOS — 电池优化 + 自启动
- 🇨🇳 vivo OriginOS — 电池优化 + 悬浮窗
- 📐 挖孔屏安全区域适配 (MIUI 状态栏偏移)

### 🍎 iPad Pro 2022 (M2) 专属

- 🖥 Stage Manager 台前调度 (分屏/侧拉/全屏)
- 🔄 120Hz ProMotion 高刷新率锁定
- ⌨️ 妙控键盘 15 个全局快捷键
- ✏️ Apple Pencil 悬停检测 (M2 独占)
- 🌈 Liquid Retina XDR HDR 支持
- 💡 LiDAR 传感器检测

### 🏗 架构

- Flutter 3.x + Dart 3
- media_kit (libmpv) 播放引擎
- Riverpod 状态管理
- GoRouter 声明式路由
- Freezed 不可变数据模型
- SQLite (sqflite) 本地持久化
- MethodChannel 原生桥接 (Android Kotlin + iOS Swift)
- 响应式布局 (3 断点：手机 / 平板 / 大屏)

---

## 版本号规则

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)：

- `MAJOR` — 破坏性 API 变更
- `MINOR` — 向后兼容的新功能
- `PATCH` — 向后兼容的 Bug 修复

## 发布链接

- GitHub Releases: https://github.com/Kimcop-kc/PerchPlay/releases
- 问题跟踪: https://github.com/Kimcop-kc/PerchPlay/issues