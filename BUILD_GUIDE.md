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
git clone https://github.com/Kimcop-kc/vidflow.git
cd vidflow

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

```bash
# 1. 安装 CocoaPods 依赖
cd ios && pod install && cd ..

# 2. 构建 (仅 macOS)
flutter build ios --release

# 3. 使用 Xcode 打开 Runner.xcworkspace 进行 Archive
open ios/Runner.xcworkspace
```

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