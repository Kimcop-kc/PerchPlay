# PerchPlay

一个用 Flutter 写的本地视频播放器，同时支持 **Android / iOS / iPadOS**。
播放内核是 **media_kit（libmpv）**，界面走玻璃拟态（毛玻璃 + 紫青渐变）风格。

当前版本：**1.0.85**

---

## 功能

### 播放
- 常见视频格式：`mp4 / mkv / avi / mov / wmv / flv / webm / m4v / mpg / mpeg / 3gp / ts / m2ts / vob / rmvb …`（共 21 种，见 `AppConstants.supportedVideoFormats`）
- 硬件解码开关（花屏/黑屏的机型可切软解）
- 倍速 0.25x ~ 2.0x
- 内嵌字幕轨选择；外挂字幕 `SRT / ASS / VTT`
- **双字幕同屏**（内嵌轨走 mpv 的第二字幕，外挂字幕自绘叠在下方，可中英对照）
- 断点续播（退出/切集自动落盘进度，仅在播到结尾时归零）
- 播放队列（上一集/下一集，剧集可连播）
- 视频详情：文件名、分辨率、编码、帧率、音轨、时长、大小、文件时间、所在文件夹、完整路径、内嵌字幕、解码方式、上次播放到
- 播放页顶栏：返回 / 文件名 / 详情 / 投屏 / 全屏 / 小窗（系统不支持小窗时该按钮不显示）

### 手势（播放页）
| 手势 | 作用 |
|---|---|
| 左侧上下滑 | 调亮度（线性，不会滑一点就过头） |
| 右侧上下滑 | 调音量 |
| 水平滑 | 快进/快退，**实时带动底部进度条**并显示目标时间与增量 |
| 双击 | 播放 / 暂停 |
| 单击 | 显示 / 隐藏控制栏（隐藏后单击即可唤回） |

### 资源库
- 扫描优先走 **系统媒体库索引（MediaStore）**，毫秒级出结果，并直接拿到时长/大小
- 拿不到媒体库时回退为文件系统遍历
- 视频缩略图（按显示尺寸解码，省内存）
- **按视频文件名自动分组播放列表**（只看文件名，不看所在文件夹）：
  - 明确季集标记 → 合成剧集列表并按季集排序：`S01E02`、`s01.e02`、`1x02`、`第1季第3集`、`第02集`、`EP05`、`[02]`、`Show.S01.01`（只有一集也会成列表）
  - `Show - 01 [1080p]`、`Show.02.1080p` 这类"末尾序号"写法：需要同一剧名至少 2 个不同集数才成列表（避免把 `Rocky 2` 这种片名带数字的电影当成剧集）
  - 跨文件夹的同名剧集会合并成一个列表（`S1/Show.S01E01` + `S2/Show.S02E01` → 「Show」）
  - **没有「电影」列表**：文件名里看不出剧集信息的（电影等）不进任何自动列表
  - 文件名里只有编号（`01.mp4`）不成列表
- **列表内容可自由增删**：从自动列表移除某集，下次扫描不会又长回来；手动加进去的也会保留（新集数照常自动补充）
- 播放列表详情页：点列表进去先看清单（序号/缩略图/时长/大小/上次看到），点哪一集从哪一集开始连播
- 列表可删除：手动列表直接删；自动列表删除后**不会再自动重建**，标题栏会出现「恢复自动列表」找回
- 长按视频卡片 → 添加到播放列表 / 从影库移除
- 文件夹浏览器、观看历史

### 投屏（DLNA）
- SSDP 发现局域网设备（Android 需要组播锁，已处理）+ **手动填 IP** 兜底
- 连接时解析设备描述里的真实 `AVTransport` 控制地址；SOAP 用显式 `Content-Length`；命令独立连接并失败重试
- **内置 HTTP 媒体服务**：把本地文件以 `http://<手机IP>:<端口>/…` 暴露给电视，支持 Range（拖进度必需）——电视读不到 `/storage/...`，缺这一环投屏必然失败
- 连接后可进投屏遥控面板

> **Chromecast / AirPlay 未实现**：Chromecast 需要 CASTV2（TLS + protobuf），AirPlay 需要原生层支持。界面上不会谎报"已连接"。

### NAS / 网络存储
- **WebDAV**（推荐：群晖/威联通都支持）、**FTP**
- **局域网自动发现**：打开 NAS 页即在后台扫描本网段特征端口，按 Server 头与页面内容识别品牌（群晖 / 威联通 / TrueNAS / OpenMediaVault / Unraid / 飞牛 / 极空间 / iStoreOS / WD / 铁威马 / Asustor …），并发 PROPFIND 判断 WebDAV 是否真的可用；**只有真的发现可用连接才显示**
- 只会列出「确实是 NAS」或「WebDAV 真的可用」的条目，路由器上裸露的 80/445 端口不会混进来

> **SMB / NFS 未实现**（界面上已标注"暂不支持"并给出改用 WebDAV 的指引）。之前 SMB 是用 HTTP 探测冒充的，已改为如实失败。

### 平台相关
| 能力 | Android | iOS / iPadOS |
|---|---|---|
| 画中画（小窗） | ✅ 可用（系统不支持时按钮自动隐藏，不再有"点了没反应"的按钮） | ❌ 未实现（按钮不显示） |
| 后台播放 | ✅ 前台服务 + 通知（受「后台播放」开关控制） | 声明了 `UIBackgroundModes: audio`（真机未验证） |
| 所有文件访问权限引导 | ✅ Android 11+ 首次自动跳系统开关页，设置/空库页也可再进 | ✅ 沙盒 Documents 扫描 + 「文件」App 多选导入 + 照片库视频扫描（`file_picker` / `photo_manager`） |
| 高刷新率 | ✅ 取该分辨率下最高的 display mode | ✅ 允许 >60fps（`CADisableMinimumFrameDurationOnPhone`） |
| 完整键盘快捷键 | ✅ 外接键盘 | ✅ 妙控键盘 |

### 键盘快捷键（全平台生效）
`Space` 播放/暂停 · `←/→` 快退/快进 10s · `↑/↓` 音量 ±5% · `0–9` 跳转到 0%~90% ·
`F` 全屏 · `S` 字幕 · `R` 倍速 · `P` 小窗 · `M` 静音 · `[` / `]` 上一集/下一集 · `Esc` 退出

---

## 界面

- 玻璃拟态：毛玻璃卡片/面板/导航栏 + 紫青渐变 + 大圆角 + 顶部高光
- **导航栏实时模糊可在设置里开关**（默认开启）：关闭只是不做实时模糊、外观不变，适合低端机或发热明显的场景
- Android 上 `BackdropFilter` 会按 GPU 兼容策略自动降级为半透明叠加（导航栏除外，它走真实模糊 + 开关）
- 响应式：手机（底栏导航 + 全屏播放）／平板竖屏（NavigationRail + 放大控件）／平板横屏（双栏 Master-Detail + 播放器分栏）
- 导航栏 6 个标签：首页 · 文件夹 · 列表 · 历史 · NAS · 设置（投屏不占底栏，从播放页进入）

---

## 项目结构

```
lib/
├── main.dart                                  应用入口
├── core/
│   ├── constants/app_constants.dart           全局常量（格式白名单/倍速/版本号）
│   ├── theme/app_theme.dart                   主题
│   ├── theme/glass_theme.dart                 玻璃设计系统（颜色/圆角/阴影/动画）
│   ├── router/app_router.dart                 GoRouter 路由（含播放列表详情子路由）
│   └── responsive/
│       ├── breakpoints.dart                   响应式断点
│       └── adaptive_scaffold.dart             自适应外壳（底栏 / NavigationRail）
├── models/                                    video / subtitle / playlist / nas / cast
├── services/
│   ├── database_service.dart                  SQLite（videos / playlists / playback_history）
│   ├── video_scanner_service.dart             MediaStore 扫描 + 文件系统回退
│   ├── thumbnail_service.dart                 缩略图
│   ├── subtitle_service.dart                  字幕解析 SRT/VTT/ASS
│   ├── media_namer_service.dart               文件名识别（剧集季集 / 电影名清洗）
│   ├── local_media_server.dart                投屏用内置 HTTP 服务（支持 Range）
│   ├── cast_discovery_service.dart            DLNA SSDP 发现 + 组播锁
│   ├── cast_control_service.dart              DLNA SOAP 控制
│   ├── nas_client_service.dart                WebDAV / FTP 客户端
│   ├── nas_discovery_service.dart             局域网 NAS 自动发现 + 品牌识别
│   ├── native_bridge_service.dart             MethodChannel 桥接
│   ├── app_settings_service.dart              设置持久化（SharedPreferences）
│   ├── device_info_service.dart               设备型号 / 系统 / 能力检测
│   └── ipad_optimization_service.dart         iPad 能力检测
├── providers/                                 library / player / playlist / permission /
│                                              cast / nas / ui_settings（Riverpod）
├── pages/
│   ├── home/home_page.dart                    首页网格 + 悬浮小窗
│   ├── player/player_page.dart                播放器（全屏 + 平板分栏）
│   ├── folders/ folder_browser_page.dart      文件夹浏览
│   ├── playlist/playlist_page.dart            播放列表
│   ├── playlist/playlist_detail_page.dart     列表详情（看清单再播）
│   ├── history/history_page.dart              观看历史
│   ├── cast/cast_page.dart                    投屏遥控面板
│   ├── nas/nas_browser_page.dart              NAS 浏览
│   └── settings/settings_page.dart            设置
└── widgets/
    ├── keyboard_shortcut_handler.dart         键盘快捷键（全平台）
    ├── glass/                                 GlassCard / GlassPanel / GlassButton /
    │                                          GlassNavBar / GlassSlider / SafeBackdropFilter
    └── player/                                player_gesture_layer / subtitle_overlay

test/                                          21 项单元/集成测试
tools/                                         本地联调用的假服务（见下方"测试"）
.github/workflows/                             CI：Android APK+AAB / iOS IPA / 代码检查
android/ · ios/                                平台工程（iOS 含 Xcode 工程与 Podfile）
```

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

Android 的 `release` 构建：本仓库提供默认回退（无 keystore 时用 debug 签名，保证 clone 后可直接构建）。正式发布需在 `android/key.properties` 里指向你自己的 keystore（该文件已被 `.gitignore` 忽略，不会进仓库）。
iOS 首次在 Xcode 里需要设置 **Signing Team**（Bundle ID 已与 Android 统一为 `com.perchplay.player`），然后打开 `Runner.xcworkspace`（不是 `.xcodeproj`）。

### 权限说明（Android）
- Android 13+：`READ_MEDIA_VIDEO`（弹窗授权）
- Android 11+：可另开「所有文件访问权限」，扫描更完整（首次会引导，之后可在设置或空库页进入）

---

## 测试与 CI

```bash
flutter analyze --no-fatal-infos
flutter test
```

- 当前 **24 项测试**（21 通过 / 3 项在缺少本地假服务时自动跳过，不算失败）；需要跑全量时先起假服务：
  ```bash
  python tools/fake_dlna_renderer.py 8099   # 投屏：假 DLNA 渲染器，记录 SOAP 请求
  python tools/fake_nas.py                  # NAS：:5000 群晖页面 + :5005 WebDAV
  ```
- 覆盖内容：本地媒体服务 Range 请求、DLNA「解析 controlURL → SetAVTransportURI → Play」、NAS 品牌与 WebDAV 识别、文件名分类、设置持久化迁移。

CI（GitHub Actions）三个工作流均已通过：

| 工作流 | 内容 |
|---|---|
| `CI — 代码检查` | `flutter pub get` + `analyze` + `test` |
| `Android — 构建 APK + AAB` | analyze/test 快速失败 → 分 ABI APK + AAB → 上传产物（tag 时发 Release） |
| `iOS — 构建 IPA` | `macos-15` runner → `pod install`（含 CDN 重试 + media_kit symlink 修复）→ `flutter build ios --no-codesign` → ad-hoc 签名打包 IPA。仅手动触发（`workflow_dispatch`），需配 Apple 签名证书做真机安装、可加自动触发 |

---

## 技术栈

| 类别 | 使用 |
|---|---|
| 框架 | Flutter 3.22 / Dart 3.4 |
| 播放引擎 | media_kit 1.2.0（libmpv） |
| 状态管理 | Riverpod 2.5 |
| 路由 | GoRouter 14 |
| 数据库 | sqflite（SQLite） |
| 设置持久化 | shared_preferences |
| 权限 | permission_handler |
| 缩略图 | flutter_video_thumbnail_plus |
| 原生桥接 | MethodChannel（Android Kotlin / iOS Swift） |

---

## 尚未实现

- Chromecast / AirPlay 投屏（现在只有 DLNA）
- SMB / NFS 网络存储（现在只有 WebDAV / FTP）
- iOS 画中画
- 音轨切换 UI（现在详情里能看到音轨信息）
- AB 循环、视频截图、均衡器、深浅色主题切换

---

## License

MIT
