# ProGuard rules for VidFlow

# Keep Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep media_kit / libmpv
-keep class com.media_kit.** { *; }
-dontwarn com.media_kit.**

# Keep Kotlin
-keepattributes *Annotation*
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# Keep our app classes
-keep class com.vidflow.player.** { *; }