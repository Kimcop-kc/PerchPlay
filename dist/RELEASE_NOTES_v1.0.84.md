## PerchPlay v1.0.84 旗舰版

全功能本地视频播放器，含 AI 实时字幕 / 翻译 / 刮削 / 云盘 / SMB。

### 本次修复

**P0 — 翻译方向与 ASR 语言标签**
- 修复 SenseVoice 语言标签 `<|zh|>` `<|en|>` 被丢弃导致翻译方向判定错误
- 检测到英文语音时自动切换为「英译中」（先前会按用户原设目标语言，方向错乱）
- `TranslateService.loadFromSettings()` 真正读取持久化配置

**P1 — 播放进度与 seek 稳定性**
- `_pendingResumeLoadId` 守卫：快速切集时旧视频的 duration 事件不再把新视频 seek 到错误位置
- `loadVideo` 恢复进度时钳位到已知时长范围，避免 seek 越界
- 新增 `WidgetsBindingObserver`：退后台 / 锁屏时自动保存进度（先前只在退出页面时保存）

**P2 — 设置与交互一致性**
- 双语字幕行序统一为「中文 + 换行 + 外文」，修正英译中时"只中文"模式显示成英文的问题
- 新增 `translateSettingsTickProvider`：设置页切换翻译后端（Google / LLM / 离线）后即时生效，无需重启
- 批量生成字幕入口重新读取最新翻译设置

### 验证结果

| 项目 | 结果 |
|------|------|
| `flutter analyze` | 0 errors / 0 warnings |
| `flutter test` | 291 passed（新增 43 个回归测试） |
| `flutter build apk --release` | ✅ 53.2 MB |

### 安装

- 架构：arm64-v8a
- 最低系统：Android 7.0 (API 24)
- 签名：debug key（仓库未包含正式 keystore）

### 已知限制

- 未在真实 Android 设备上完成验收测试
- `dart_smb2` 在 Windows 上缺少 DLL，仅影响本地测试环境，不影响 APK
