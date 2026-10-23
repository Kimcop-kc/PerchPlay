# 构建与发布指南

## 环境要求

| 工具 | 版本 |
|------|------|
| Flutter SDK | ≥ 3.22 |
| Dart SDK | ≥ 3.4 |
| Android Studio | ≥ 2023.2 (Koala) |
| Xcode | ≥ 15.0 (macOS, iOS 构建必需) |
| JDK | 17 (Android 构建) |
| CocoaPods | ≥ 1.14 (iOS) |

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/Kimcop-kc/PerchPlay.git
cd PerchPlay

# 2. 安装依赖
flutter pub get

# 3. 生成代码 (Freezed / json_serializable)
dart run build_runner build --delete-conflicting-outputs

# 4. 运行开发版
flutter run                # 自动选择已连接设备
flutter run -d <device_id> # 指定设备
```

## Android 构建

### 开发版 APK

```bash
flutter build apk --debug
# 输出: build/app/outputs/flutter-apk/app-debug.apk
```

### 正式版 APK (分 ABI)

```bash
flutter build apk --split-per-abi --release
# 输出:
#   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
#   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#   build/app/outputs/flutter-apk/app-x86_64-release.apk
```

### 正式版 App Bundle (Google Play)

```bash
flutter build appbundle --release
# 输出: build/app/outputs/bundle/release/app-release.aab
```

### 签名配置

在 `android/key.properties` 中配置签名信息：

```properties
storePassword=<密码>
keyPassword=<密码>
keyAlias=upload
storeFile=<keystore 路径>
```

## iOS 构建

> iOS 构建必须在 **macOS + Xcode + CocoaPods** 环境才能完成（产出 .app/.ipa）。仓库内已配置
> GitHub Actions 工作流 `.github/workflows/build-ios.yml` 在 macOS runner 上执行无签名构建并打包 IPA。

```bash
# 1. 安装 CocoaPods 依赖（首次需联网下载 media_kit 的 libmpv 预编译包）
cd ios && pod install && cd ..

# 2. 构建 (仅 macOS)
flutter build ios --release

# 3. 使用 Xcode 打开 Runner.xcworkspace 进行 Archive
open ios/Runner.xcworkspace
```

### iOS 构建的关键前置（容易踩坑）

- **dart_smb2** 使用新的 code-assets 构建钩子（`hooks.user_defines.dart_smb2.libsmb2`）。
  仓库把预编译库放在 `third_party/libsmb2/`，其中必须包含**对应平台的产物**：
  - Android：`libsmb2_android-*.so`（已有）
  - **iOS/iPadOS：`libsmb2_ios.xcframework.zip`（已补，SHA-256 与 dart_smb2 包内清单一致 `a1f0b15b…38f63`）**
  - Linux / Windows：`libsmb2_linux-x86_64.so`、`libsmb2_windows-x86_64.dll`（已补，
    供 GitHub Actions 的 ubuntu runner 与本地 Windows 跑 `flutter test` 使用）
  - macOS：`libsmb2_macos.xcframework.zip`（如需构建 macOS 客户端需补充）
  - 若缺对应文件，构建/测试会报
    `dart_smb2: ... which has no libsmb2_ios.xcframework.zip`（或对应平台的 DLL/SO）。
- **media_kit iOS** 的 podspec 内含 `system("make")`，首次 `pod install` 会从
  GitHub（media-kit/libmpv-darwin-build）下载预编译的 libmpv xcframework（v0.6.0），需要能访问
  GitHub Release。
- **最低 iOS 版本为 15.0**：Flutter 3.47+ 的 `Flutter.podspec` 与官方 Podfile 模板要求
  `platform :ios, '15.0'`。`Podfile`、`Runner.xcodeproj` 的 `IPHONEOS_DEPLOYMENT_TARGET`、
  `ios/Flutter/AppFrameworkInfo.plist` 的 `MinimumOSVersion` 已统一为 15.0。若降回 12.0，
  `pod install` 会报 `pod "Flutter" ... required a higher minimum deployment target`。
- 各 iOS 插件最低部署版本均 ≤ 项目的 iOS 15.0（permission_handler_apple 12.0、
  media_kit_libs_ios_video 9.0），`Info.plist` 与 `Podfile` 已配置完整权限。
- iOS Bundle ID 现为 `com.vidflow.vidflow`（沿自旧名 VidFlow），与 Android 包名
  `com.perchplay.player` 不一致；上架前建议在 `Runner.xcodeproj` 里统一。

### iOS 本地文件访问（沙盒模型）

iOS 没有 Android 那样的全局存储扫描，App 只能访问自己的容器目录。本项目通过三条途径
让 iOS 也能扫描/导入本地视频（实现见 `lib/services/local_media_import_service.dart`）：

| 途径 | 说明 | 用户操作 |
|---|---|---|
| **沙盒 Documents 扫描** | 扫描 `getApplicationDocumentsDirectory()`。配合 Info.plist 的 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，该目录会显示在系统「文件」App →「我的 iPhone」→ PerchPlay | 把视频拖进「文件」App 里 PerchPlay 文件夹，回到 App 点「扫描视频」 |
| **「文件」App 多选导入** | `file_picker` 打开 UIDocumentPicker（`FileType.custom` + 支持的视频扩展名），选中后复制到 `Documents/Imported/` | 文件夹页右上角「导入视频」按钮 / 空库页按钮 |
| **照片库视频扫描** | `photo_manager` 枚举 `RequestType.video` 资产，导出为 `Documents/Imported/PhotoLibrary/` 下的真实文件 | 首次会弹照片库权限；授权后点「扫描视频」即自动导出并入库 |

> 为什么照片库要**导出成真实文件**而不是直接播：`photo_manager` 的 `AssetEntity.file`
> 在 iOS 上返回的是应用缓存临时文件，且 media_kit 播这类路径有「只有音频无画面」的
> 已知问题（[media-kit#1192](https://github.com/media-kit/media-kit/issues/1192)）。
> 复制到 Documents 后路径稳定，也便于缩略图/字幕等后续处理。

权限相关：
- `Info.plist` 需有 `NSPhotoLibraryUsageDescription`（已配置）。
- `Podfile` 的 `post_install` 中 `PERMISSION_PHOTOS=1` / `PERMISSION_MEDIA_LIBRARY=1`
  已启用（permission_handler 的 iOS 权限宏）。
- `permission_provider` 在 iOS 上用 `Permission.photos`，与 photo_manager 请求的是
  同一个 PHPhotoLibrary 权限，不会重复弹窗冲突。

### IPA 导出

1. Xcode → Product → Archive
2. Distribute App → Ad Hoc / App Store Connect
3. 导出 .ipa 文件

## 发布前检查清单

- [ ] `flutter analyze` — 无警告
- [ ] `flutter test` — 所有测试通过
- [ ] 版本号已更新 (`pubspec.yaml` → `version`)
- [ ] CHANGELOG.md 已更新
- [ ] android/app/build.gradle → `versionCode` / `versionName` 已同步
- [ ] ios/Runner.xcodeproj → Marketing Version / Build 已同步
- [ ] Git Tag 已创建 (`git tag v1.0.0`)
- [ ] 所有提交已推送 (`git push --tags`)

## 版本号同步

发布时需同步更新以下文件的版本号：

| 文件 | 字段 |
|------|------|
| `pubspec.yaml` | `version: 1.0.0+1` |
| `android/app/build.gradle` | `versionCode 1` / `versionName "1.0.0"` |
| `ios/Runner.xcodeproj` | MARKETING_VERSION = 1.0.0 / CURRENT_PROJECT_VERSION = 1 |
| `CHANGELOG.md` | `## [1.0.0]` |

## 依赖代码生成

本项目使用 Freezed + json_serializable，修改模型后需重新生成：

```bash
dart run build_runner build --delete-conflicting-outputs
# 或监听模式:
dart run build_runner watch --delete-conflicting-outputs
```

## 常见问题

### Android 构建失败

```bash
# 清理
cd android && ./gradlew clean && cd ..
flutter clean
flutter pub get
flutter build apk
```

### iOS Pod 安装失败

```bash
cd ios
pod deintegrate
pod cache clean --all
pod install
cd ..
```

### media_kit 编译失败

```bash
# 重新初始化 media_kit 依赖
flutter clean
flutter pub get
cd android && ./gradlew clean && cd ..
```