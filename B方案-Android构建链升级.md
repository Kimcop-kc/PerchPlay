# B 方案：Android 构建链完整升级（留待后续）

> 状态：**未执行**。记录完整步骤，供日后需要 `media_kit_libs_android_video 1.3.8`、
> `ffmpeg_kit` 等需要高 compileSdk / 高 AGP 的依赖时按此升级。

## 为什么现在不做

当前项目用 AGP 7.3.0 + Gradle 7.6.3 + Kotlin 1.7.10（Flutter 3.22 时代的配置）。
这些旧版本无法解析 compileSdk 36（`media_kit_libs_android_video 1.3.8` 需要）。
升级会动整套构建链，且需要真机反复 `gradlew` 排错 —— 本项目开发者当前无 macOS
（iOS 没法验证），且沙箱环境跑不了 `flutter build`，盲改风险高。

## 升级目标版本（对应系统已装 Flutter 3.47.7）

| 组件 | 当前 | 目标 |
|---|---|---|
| Flutter | 3.22（项目假设） | 3.47.7（系统已装） |
| Dart | 3.4.4 | 3.13.5 |
| AGP | 7.3.0 | 9.1.0（Flutter 3.47 模板默认） |
| Kotlin Gradle Plugin | 1.7.10 | 2.4.0 |
| Gradle | 7.6.3 | 8.11+（AGP 9 要求 Gradle 8.x） |
| media_kit_libs_android_video | 1.3.7 | 1.3.8（compileSdk 36） |

## 步骤

1. **备份** 当前 `android/` 目录（或 git commit 留点）。
2. `android/gradle/wrapper/gradle-wrapper.properties`：
   `gradle-7.6.3-all.zip` → `gradle-8.11.1-all.zip`
3. `android/settings.gradle`：把
   - `com.android.application` 版本 `7.3.0` → `9.1.0`
   - `org.jetbrains.kotlin.android` 版本 `1.7.10` → `2.4.0`
4. `pubspec.yaml`：
   - `media_kit_libs_android_video: 1.3.7` → `1.3.8`
   - 如要 ffmpeg 转码：重新加 `ffmpeg_kit_flutter_audio`（但该包已断更，慎用；
     本项目已用 `AudioTranscoder` 走系统 MediaExtractor，一般不需要）
5. `cd android && ./gradlew clean`（清掉旧缓存）
6. `flutter clean && flutter pub get && flutter build apk --debug`
7. 逐个处理报错（常见：namespace 缺省、compileSdk 未指定、Kotlin 新 API 变更）。

## 升级能解锁什么

- `media_kit_libs_android_video 1.3.8`（compileSdk 36，更新的 FFmpeg/libmpv 二进制）
- `ffmpeg_kit` 等需要高 SDK 的已断更插件（不推荐新依赖）

## 注意事项

- **AGP 9 是一次大版本跳跃**，大概率有连锁报错，请预留半天到一天排错时间。
- 升级前确保 `git status` 干净，便于回滚。
- iOS 侧不受此影响，但若升级 Flutter 后用新模板生成的项目结构，iOS 的 Podfile
  可能也要同步（有 mac 时再一并处理）。