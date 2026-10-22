## PerchPlay v1.0.85 — 移除 AI 功能，单一纯净版本

本版本**彻底移除全部 AI 功能**，PerchPlay 回归为一个纯粹的本地视频播放器。

### 移除的 AI 功能

| 模块 | 说明 |
|------|------|
| 实时字幕（边播边转写） | 删除语音识别引擎（SenseVoice / sherpa-onnx） |
| 全片字幕生成 | 删除离线 ASR 批量转写 |
| AI 翻译 | 删除 Google / LLM / 本地 Opus-MT 三种翻译后端 |
| 模型管理 | 删除模型下载 / 切换 / 删除页面 |
| 双语字幕 | 删除 AI 双语对照显示 |

### 保留的全部功能

- 本地视频播放（21 种格式，HDR、高帧率、倍速、硬件解码）
- 内嵌字幕轨选择 + 外挂字幕（SRT / ASS / VTT）+ 双字幕同屏
- ASS 原生渲染开关、字幕字号/位置/透明度/描边可调
- 断点续播、播放队列、自动连播
- 手势控制（亮度/音量/快进/长按倍速）
- 影库扫描、自动分组播放列表、缩略图
- DLNA 投屏、NAS（SMB）、云盘（阿里云盘/百度/夸克/115）
- 后台播放、画中画、全屏沉浸

### 技术变更

- 删除依赖：`sherpa_onnx` / `onnxruntime` / `file_picker` / `archive` / `encrypt`
- 删除本地 patch：`local_packages/onnxruntime/`
- 删除 14 个 AI 服务文件 + `live_subtitle_provider.dart` + `ai_models_page.dart`
- 分支合并：删除 `standard` 分支，只保留单一 `master`

### 保留的非 AI 修复（合并自两分支）

- 播放进度恢复：退后台/锁屏自动保存（`WidgetsBindingObserver`）
- seek 竞态保护：`_seekToken` + `_pendingResumeLoadId` + 真实时长钳位
- 手势冲突修复：进度条拖动时抑制画面横向 seek（`_sliderDragging` → `blockSeek`）

### 验证结果

| 项目 | 结果 |
|------|------|
| `flutter analyze` | 0 errors / 0 warnings |
| `flutter test` | 234 passed |
| `flutter build apk --release` | ✅ 33.8 MB |

### 安装

- 架构：arm64-v8a
- 最低系统：Android 7.0 (API 24)
- 签名：debug key
