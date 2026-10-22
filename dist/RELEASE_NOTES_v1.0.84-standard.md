## PerchPlay v1.0.84 纯净版

无 AI 模块的轻量版本：本地播放 / 字幕 / 刮削 / 云盘 / SMB 全部保留，移除语音识别与翻译。

### 本次修复（从旗舰版移植的非 AI 部分）

**P1 — 播放进度与 seek 稳定性**
- `_pendingResumeLoadId` 守卫：快速切集时旧视频的 duration 事件不再把新视频 seek 到错误位置
- `loadVideo` 恢复进度时钳位到已知时长范围，避免 seek 越界
- 新增 `WidgetsBindingObserver`：退后台 / 锁屏时自动保存进度（先前只在退出页面时保存）

**字幕相关说明**
- 字幕显示/隐藏、内嵌/外挂切换、ASS 原生渲染、字号/位置/透明度/描边等非 AI 逻辑
  与旗舰版**代码完全一致**（`player_provider.dart`、`subtitle_overlay.dart`、
  `subtitle_service.dart`、`app_settings_service.dart` 逐字节相同），本身已无缺陷
- 旗舰版独有的双语行序修复（P2.3）与翻译热重载（P2.6）依赖 AI 模块，纯净版不适用

### 验证结果

| 项目 | 结果 |
|------|------|
| `flutter analyze` | 0 errors / 0 warnings |
| `flutter test` | 234 passed（含 21 个新增回归测试） |
| `flutter build apk --release` | ✅ 34.4 MB |

### 安装

- 架构：arm64-v8a
- 最低系统：Android 7.0 (API 24)
- 签名：debug key（仓库未包含正式 keystore）

### 已知限制

- 未在真实 Android 设备上完成验收测试
