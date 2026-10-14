# VidFlow — 全功能本地视频播放器

一款基于 Flutter 构建的跨平台本地视频播放器，同时支持 Android 与 iOS / iPadOS。  
底层使用 **media_kit (libmpv)** 引擎，支持绝大多数视频/音频格式。  
UI 采用 **iOS 27 玻璃质感设计语言** — 全毛玻璃模糊、紫青色渐变、Spring 弹性动画。

---

## ✨ 功能列表

### 🎬 核心播放
- [x] 通用视频格式支持 (MP4 / MKV / AVI / MOV / WMV / FLV / WebM 等)
- [x] 硬件加速解码 (H.264 / H.265 / HEVC)
- [x] 倍速播放 (0.25x ~ 2.0x)
- [x] 多音轨切换 & 外挂字幕 (SRT / ASS / VTT)
- [x] 播放列表管理

### 🖐 手势控制
- [x] 左侧上下滑动 → 调节亮度
- [x] 右侧上下滑动 → 调节音量
- [x] 水平滑动 → 快进/快退 (±10s)
- [x] 双击 → 播放/暂停
- [x] 单击 → 显示/隐藏控制栏

### 📱 平台特性
- [x] 画中画 (PiP) — Android 8+ / iOS 14+
- [x] 后台音频播放
- [x] 锁屏控制 & 耳机线控
- [x] 记忆播放进度 (断点续播)
- [x] 观看历史

### 📂 文件管理
- [x] 自动扫描本地视频
- [x] 文件夹浏览器
- [x] 视频缩略图
- [x] 自定义播放列表

### 📐 响应式布局
- [x] 手机竖屏（< 600px）→ 底栏导航 + 全屏播放
- [x] 平板竖屏（600~900px）→ NavigationRail + 放大控件
- [x] 平板横屏 / 大屏（≥900px）→ 双栏 Master-Detail + 播放器分栏

---

## 🏷️ 品牌设备专项优化

### 🇨🇳 小米 / Redmi / POCO（MIUI / HyperOS）
| 优化项 | 说明 |
|--------|------|
| 电池优化白名单 | 自动引导 → 长按图标 → 应用信息 → 省电策略 → 无限制 |
| 悬浮窗权限 | 自动引导 → 权限管理 → 显示悬浮窗 → 允许 |
| 视频工具箱 | 支持画质增强 / MEMC 动态补偿 |
| 全面屏适配 | 自动适配挖孔区域 + 手势条安全区 |
| MIUI 自启动 | 引导至安全中心自启动管理页 |
| PiP 兼容 | 已适配 MIUI 画中画权限（需手动开启悬浮窗） |
| 后台保活 | 锁定任务卡片防止被杀 |

### 🇨🇳 华为 / 荣耀（EMUI / HarmonyOS）
| 优化项 | 说明 |
|--------|------|
| 电池优化 | 引导至 设置 → 应用启动管理 → 手动管理 |
| 自启动 | 手机管家 → 应用启动管理 → 开启自启动 |
| 悬浮窗 | 权限管理 → 悬浮窗 → 允许 |
| 后台播放 | 通过 ForegroundService + 通知栏锁屏控件保活 |

### 🇨🇳 OPPO / 一加 / realme（ColorOS）
| 优化项 | 说明 |
|--------|------|
| 电池优化 | 电池 → 应用耗电管理 → 允许后台运行 |
| 自启动 | 设置 → 应用管理 → 自启动管理 → 开启 |
| 悬浮窗 | 应用管理 → 悬浮窗管理 → 允许 |

### 🇨🇳 vivo / iQOO（OriginOS / Funtouch OS）
| 优化项 | 说明 |
|--------|------|
| 电池优化 | 电池 → 后台高耗电 → 允许 |
| 自启动 | i管家 → 权限管理 → 自启动 → 开启 |
| 悬浮窗 | 更多设置 → 权限管理 → 悬浮窗 → 允许 |

---

## 🍎 iPad Pro 2022（M2）专属优化

| 特性 | 说明 |
|------|------|
| **台前调度 (Stage Manager)** | 支持多窗口、分屏、Slide Over 浮窗模式 |
| **妙控键盘快捷键** | Space 暂停/播放 · ←→ 快进快退 · 0-9 跳转 · F 全屏 · S 字幕 · R 倍速 · P 画中画 · M 静音 · [ ] 切集 · Esc 退出 |
| **Apple Pencil 悬停** | M2 芯片专属：悬停预览进度条（800ms 自动隐藏发光条） |
| **120Hz ProMotion** | 自适应刷新率，播放时锁 120Hz 防掉帧 |
| **Liquid Retina XDR** | 1600nit 峰值亮度，HDR 内容完美呈现 |
| **LiDAR 场景仪** | 可用于 AR 空间计算功能（视频播放暂未启用） |
| **分屏自适应** | Full Screen 双栏 → SplitView 单栏 → Slide Over 紧凑模式 |

---

## 🏗️ 项目架构

```
lib/
├── main.dart                                  # 应用入口
├── core/
│   ├── theme/app_theme.dart                   # 暗色主题
│   ├── router/app_router.dart                 # GoRouter 路由
│   ├── constants/app_constants.dart           # 全局常量
│   └── responsive/
│       ├── breakpoints.dart                   # 响应式断点工具
│       └── adaptive_scaffold.dart             # 自适应导航外壳
├── models/
│   ├── video_model.dart                       # 视频数据模型 (Freezed)
│   ├── subtitle_model.dart                    # 字幕数据模型
│   └── playlist_model.dart                    # 播放列表模型
├── services/
│   ├── database_service.dart                  # SQLite 数据库
│   ├── video_scanner_service.dart             # 视频扫描
│   ├── thumbnail_service.dart                 # 缩略图生成
│   ├── subtitle_service.dart                  # 字幕解析 (SRT/VTT)
│   ├── device_info_service.dart               # 设备品牌/型号检测
│   ├── rom_optimization_service.dart          # 中国 ROM 权限引导
│   ├── ipad_optimization_service.dart         # iPad Pro 专属优化
│   └── native_bridge_service.dart             # MethodChannel 原生桥接
├── providers/
│   ├── library_provider.dart                  # 视频库状态 (Riverpod)
│   ├── player_provider.dart                   # 播放器状态管理
│   ├── playlist_provider.dart                 # 播放列表状态
│   └── permission_provider.dart               # 权限管理
├── pages/
│   ├── home/home_page.dart                    # 首页 + 视频网格 (响应式)
│   ├── player/player_page.dart                # 播放器 (响应式分栏)
│   ├── folders/folder_browser_page.dart       # 文件夹浏览 (双栏)
│   ├── playlist/playlist_page.dart            # 播放列表 (双栏)
│   ├── history/history_page.dart              # 观看历史 (双栏)
│   └── settings/settings_page.dart            # 设置 (双栏)
└── widgets/
    ├── keyboard_shortcut_handler.dart         # iPad 键盘 + Pencil 悬停
    └── player/
        ├── player_gesture_layer.dart          # 手势检测层
        ├── player_controls_overlay.dart       # 播放控制栏
        ├── subtitle_overlay.dart              # 字幕渲染
        ├── speed_selector.dart                # 倍速选择器
        └── subtitle_selector.dart             # 字幕选择器
```

---

## 🚀 快速开始

### 前置条件
- Flutter SDK >= 3.2.0
- Android Studio / Xcode
- Android NDK (用于 media_kit)

### 安装

```bash
# 1. 进入项目
cd video_player_app

# 2. 安装依赖
flutter pub get

# 3. 生成代码 (Freezed / Riverpod)
flutter pub run build_runner build --delete-conflicting-outputs

# 4. 运行
flutter run
```

### 平台特定配置

**Android** (`android/`):
- `AndroidManifest.xml` — 存储权限、PiP、前台服务 (mediaPlayback)、电池优化豁免、悬浮窗权限、分屏支持
- `MainActivity.kt` — ROM 检测 (MIUI/EMUI/ColorOS)、电池白名单引导、自启动引导、悬浮窗权限引导
- `BackgroundAudioService.kt` — 通知栏媒体控件
- `styles.xml` — 全面屏凹口适配 (shortEdges)

**iOS** (`ios/`):
- `Info.plist` — 后台音频、PiP、多窗口 (Stage Manager)、Apple Pencil、120Hz、HDR
- `AppDelegate.swift` — 音频会话、远程控制中心、iPad Pro 检测、键盘命令

---

## ⌨️ iPad 快捷键速查

| 按键 | 功能 |
|------|------|
| `Space` | 播放 / 暂停 |
| `→` | 快进 10 秒 |
| `←` | 快退 10 秒 |
| `↑` | 音量 +5% |
| `↓` | 音量 -5% |
| `F` | 进入/退出全屏 |
| `Esc` | 退出播放器 |
| `S` | 切换字幕 |
| `R` | 切换倍速 |
| `P` | 画中画 |
| `M` | 静音/取消静音 |
| `[` | 上一集 |
| `]` | 下一集 |
| `0–9` | 跳转到 0%–90% |

---

## 📦 技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Flutter 3.x |
| 播放引擎 | media_kit (libmpv) |
| 状态管理 | Riverpod |
| 路由 | GoRouter |
| 数据库 | SQLite (sqflite) |
| 代码生成 | Freezed + json_serializable |
| 权限 | permission_handler |
| 缩略图 | video_thumbnail |
| 响应式 | 自定义 Breakpoints + AdaptiveScaffold |
| 原生桥接 | MethodChannel (Android + iOS) |
| 设置持久化 | SharedPreferences |

---

## 🎨 UI 设计系统 (iOS 27 Glass Edition)

### 设计语言
- **毛玻璃 BackdropFilter** — 全页面实时模糊背景 (sigmaX/Y: 20-28)
- **紫青渐变** — 主色调 `#9B7EF0` → `#45E0D0`
- **大圆角** — 10px~32px 玻璃卡片
- **Spring 弹性动画** — mass=1, stiffness=180~300, damping=14~26
- **光泽高光** — 卡片顶部 10% 白色渐变模拟玻璃反光
- **微边框** — 0.5~1px 8% 白色描边

### 玻璃组件库 (`lib/widgets/glass/`)

| 组件 | 文件 | 说明 |
|------|------|------|
| `GlassCard` | `glass_card.dart` | 核心卡片：BackdropFilter + 悬浮缩放 + 选中态紫光 |
| `GlassPanel` | `glass_panel.dart` | 面板/Sheet：彩色着色 + 模糊 + 圆角 |
| `GlassButton` | `glass_button.dart` | 按钮：filled 渐变 / outlined 边框 / ghost 透明 |
| `GlassNavBar` | `glass_nav_bar.dart` | 导航底栏：毛玻璃 + 弹性选中动画 |
| `GlassSlider` | `glass_slider.dart` | 进度条/滑块：光泽轨道 + 放大拖拽 thumb |

### 动画系统 (`lib/core/theme/glass_theme.dart`)
- `GlassCurves` — springSmooth / springBouncy / springSubtle / iosDecelerate
- `GlassAnimations` — fadeSlideUp (淡入上浮) / scaleIn (缩放弹出)
- 交错入场：每项 delay = index/total * 0.25s，总时长 0.6s

### 页面改造状态

| 页面 | 状态 | 玻璃特性 |
|------|------|---------|
| 首页 | ✅ 已改造 | 网格 GlassCard + 交错入场 + 右侧详情面板 |
| 播放器 | ✅ 已改造 | 玻璃顶栏/底栏 BackdropFilter + GlassSlider 进度条 + 侧面板 |
| 文件夹 | ✅ 已改造 | GlassCard 网格/列表 + 面包屑路径 + 玻璃按钮 |
| 历史 | ✅ 已改造 | 玻璃列表 + mini 渐变进度条 + "继续"按钮 |
| 播放列表 | ✅ 已改造 | 玻璃卡片 + 新建按钮 |
| 设置 | ✅ 已改造 | 分区 GlassCard + 玻璃 Sheet Picker + 品牌优化专区 |
| 投屏 | ✅ 已改造 | 脉冲扫描指示器 + 分组设备列表 + 控制面板 |
| NAS | ✅ 已改造 | 连接列表 + 玻璃文件浏览器 + 毛玻璃对话框 |
| 导航栏 | ✅ 已改造 | 玻璃底栏(手机) / 毛玻璃 NavigationRail(平板) |

---

## 🔜 开发计划

- [x] DLNA / Chromecast / AirPlay 投屏
- [x] SMB / FTP / WebDAV 网络存储
- [x] iOS 27 玻璃质感 UI
- [ ] 均衡器 (EQ)
- [ ] AB 循环播放
- [ ] 视频截图
- [ ] 深色/浅色主题切换

---

## 📝 License

MIT