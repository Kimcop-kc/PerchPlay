## PerchPlay v1.0.91 — 应用内更新

### 新增：应用内更新

设置 → 关于 → **检查更新**，可直接在应用内从 GitHub 下载并安装新版本：

1. 查询 GitHub 最新正式版（自动跳过预发布/草稿）
2. 比较版本号，优先选择 arm64-v8a APK
3. 下载到缓存目录（带超时保护）
4. 通过系统安装器安装（FileProvider 安全传递）

### 改进：从系统读取真实版本号

- 新增 `AppVersion` 服务（package_info_plus），启动时从系统读取真实版本
- 关于页与更新检查都用真实版本号，不再依赖硬编码常量
- 删除了会与 pubspec 脱节的 `AppConstants.appVersion` 硬编码

### 修复

- 修复 Kotlin 注释里 `/*.apk` 被误判为块注释开头，导致原生层编译失败的问题

### 验证结果

| 项目 | 结果 |
|------|------|
| `flutter analyze` | 0 errors / 0 warnings |
| `flutter test` | 262 passed |
| `flutter build apk --release` | ✅ 34.0 MB |

### 安装

- 架构：arm64-v8a
- 最低系统：Android 7.0 (API 24)
- 签名：debug key

### 说明

从本版本起，后续更新可以直接在应用内完成（设置 → 关于 → 检查更新）。
首次安装仍需手动装这个 APK。
