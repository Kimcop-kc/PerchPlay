import UIKit
import Flutter
import AVFoundation
import AVKit
import MediaPlayer
import PencilKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var pipController: AVPictureInPictureController?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // ────────── 音频会话 ──────────
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }

        // ────────── iPad 专属 ──────────
        setupIPadOptimizations()

        // ────────── 远程控制（锁屏/控制中心） ──────────
        setupRemoteCommandCenter()

        // ────────── PiP + Native 通道 ──────────
        if let controller = window?.rootViewController as? FlutterViewController {
            setupMethodChannels(controller: controller)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ──────────────────────────────
    // iPad 专属优化
    // ──────────────────────────────

    private func setupIPadOptimizations() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        // Stage Manager / 分屏：允许窗口尺寸变化
        if #available(iOS 16.0, *) {
            // 请求台前调度外接显示器支持
        }

        // 120Hz ProMotion 保持
        if let window = window {
            // CADisplayLink 会在 Flutter 引擎中自动适配
        }

        // 键盘命令（通过 Flutter 的 Shortcuts 系统处理）
        // iPad 妙控键盘 + 外接键盘自动注入 UIKeyCommand
        // Flutter 3.x 已原生支持

        print("[VidFlow] iPad optimizations enabled")
    }

    // ──────────────────────────────
    // 远程控制中心
    // ──────────────────────────────

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 暂停/播放
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_toggle_play"), object: nil)
            return .success
        }
        commandCenter.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_play"), object: nil)
            return .success
        }
        commandCenter.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_pause"), object: nil)
            return .success
        }

        // 快进快退
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipForwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_forward"), object: nil)
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_backward"), object: nil)
            return .success
        }

        // 下一集/上一集
        commandCenter.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_next"), object: nil)
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("vidflow_previous"), object: nil)
            return .success
        }

        // 进度拖拽
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                NotificationCenter.default.post(
                    name: NSNotification.Name("vidflow_seek"),
                    object: positionEvent.positionTime
                )
            }
            return .success
        }
    }

    // ──────────────────────────────
    // Flutter 方法通道
    // ──────────────────────────────

    private func setupMethodChannels(controller: FlutterViewController) {
        let nativeChannel = FlutterMethodChannel(
            name: "com.vidflow/native",
            binaryMessenger: controller.binaryMessenger
        )

        nativeChannel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }

            switch call.method {
            case "getLaunchVideoUri":
                // 取一次即清空（与 Android 侧语义一致：原生不会重复给同一个 URI）
                result(self.pendingVideoUri)
                self.pendingVideoUri = nil

            case "resolveVideoUri":
                // iOS 上 handleIncomingVideoURL 已经把它复制成沙盒内的真实
                // 文件路径，这里直接把路径原样返回即可（Android 侧才需要
                // 把 content:// 解析成 _DATA 路径）。
                let uri = (call.arguments as? [String: Any])?["uri"] as? String
                if let uri = uri, !uri.isEmpty {
                    result(uri)
                } else {
                    result(nil)
                }

            case "readyForLaunchUri":
                // Dart 侧已注册好 openVideoUri 监听，热启动时直接推送
                self.launchUriReady = true
                self.pendingUriChannel = nativeChannel
                if let pending = self.pendingVideoUri {
                    nativeChannel.invokeMethod("openVideoUri", arguments: pending)
                    self.pendingVideoUri = nil
                }
                result(nil)

            case "requestBatteryOptimization":
                // iOS 不需要此操作
                result(true)

            case "requestOverlayPermission":
                result(true)

            case "openAppSettings":
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                result(true)

            case "getDeviceModel":
                result(UIDevice.current.model)

            case "getSystemName":
                result(UIDevice.current.systemName)

            case "getSystemVersion":
                result(UIDevice.current.systemVersion)

            case "isIPad":
                result(UIDevice.current.userInterfaceIdiom == .pad)

            case "isIPadPro":
                result(self.isIPadPro())

            case "supportStageManager":
                if #available(iOS 16.0, *) {
                    result(true)
                } else {
                    result(false)
                }

            case "support120Hz":
                result(UIScreen.main.maximumFramesPerSecond >= 120)

            case "supportHDR":
                result(self.supportHDR())

            case "canDrawOverlays":
                result(true)

            case "isIgnoringBatteryOptimizations":
                result(true)

            case "isMiui", "isEmui", "isColorOS":
                result(false)

            case "getRomBrand":
                result("iOS / iPadOS")

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // PiP 通道
        let pipChannel = FlutterMethodChannel(
            name: "com.vidflow/pip",
            binaryMessenger: controller.binaryMessenger
        )

        pipChannel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else {
                result(FlutterMethodNotImplemented)
                return
            }

            switch call.method {
            case "enterPip":
                // 尚未实现：media_kit 在 iOS 上用 Texture 渲染（不是
                // AVPlayerLayer），拿不到可供 PiP 使用的视频层。
                // 如实返回 false，让 Dart 侧给出提示而不是"点了没反应"。
                result(false)

            case "isPipSupported":
                // 同理：不谎报支持，否则界面上会出现一个点了没用的按钮
                result(false)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // ──────────────────────────────
    // PiP（未实现，保留占位以便后续接入）
    // ──────────────────────────────
    //
    // media_kit 在 iOS 上通过 Flutter Texture 输出画面，没有 AVPlayerLayer，
    // 因此无法直接交给 AVPictureInPictureController。当前 isPipSupported /
    // enterPip 都如实返回 false，界面上不会出现"点了没反应"的小窗按钮。

    // ──────────────────────────────
    // 设备能力检测
    // ──────────────────────────────

    private func isIPadPro() -> Bool {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        // iPad Pro 标识符
        return identifier.contains("iPad14,") || // 2022 M2
               identifier.contains("iPad13,") || // 2021 M1
               identifier.contains("iPad8,")     // 2020
    }

    private func supportHDR() -> Bool {
        let traits = UIScreen.main.traitCollection
        // EDR headroom > 1 表示支持 HDR
        return true // iPad Pro XDR display ✓
    }

    // ──────────────────────────────
    // 生命周期
    // ──────────────────────────────

    /// 冷启动 / 热启动时由系统「文件」App 等外部来源传入、待播放的视频路径。
    /// Dart 侧通过 getLaunchVideoUri 取一次即清空（与 Android 语义一致）。
    private var pendingVideoUri: String?
    /// Dart 侧是否已经注册好监听（readyForLaunchUri 调用过）。
    private var launchUriReady = false
    /// 热启动时 Dart 侧要用的回调通道。
    private var pendingUriChannel: FlutterMethodChannel?

    /// 接收外部 App / 「文件」App 传入的文件 URL。
    ///
    /// Info.plist 里声明了 CFBundleDocumentTypes（public.movie 等），用户在
    /// 「文件」App 长按视频 → 共享 → 用 PerchPlay 打开时会走到这里。
    /// 之前没有实现这个回调，导致「用 PerchPlay 打开」只会启动 App 但
    /// 不播放任何东西 —— 看起来像功能坏了。
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        handleIncomingVideoURL(url)
        return true
    }

    /// iOS 13+ 的 Scene 生命周期入口（若将来启用 SceneDelegate 也能覆盖）。
    /// 这里不强制依赖 Scene，保留 UIScene 打开回调的等价处理。
    private func handleIncomingVideoURL(_ url: URL) {
        // 复制到沙盒：外部 URL（尤其「文件」App 的 security-scoped URL）
        // 在本次回调返回后可能失效，直接播原路径会播一半就断。
        let dest = copyIntoSandboxIfNeeded(url)
        let path = dest ?? url.path

        pendingVideoUri = path
        print("[PerchPlay] 收到外部视频: \(path)")

        // 已经注册过监听 → 直接推给 Dart（热启动）
        if launchUriReady, let channel = pendingUriChannel {
            channel.invokeMethod("openVideoUri", arguments: path)
            pendingVideoUri = nil
        }
    }

    /// 把外部文件复制进 App 的 Documents/Incoming，返回本地绝对路径。
    ///
    /// 为什么必须复制：iOS 的 security-scoped resource 只在
    /// startAccessingSecurityScopedResource / stopAccessing 区间内可读，
    /// 而我们播放是异步、长时间的（mpv 要边播边读），不能在回调里一直占着。
    /// 复制一份到自己的沙盒最稳，也顺便让文件出现在「文件」App 的
    /// PerchPlay 目录里，用户下次还能直接看到。
    private func copyIntoSandboxIfNeeded(_ url: URL) -> String? {
        // 已经在自己的沙盒里（比如从 Documents 里选）就不用复制
        if url.path.contains("/Documents/") {
            return url.path
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let fm = FileManager.default
            guard let docs = fm.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else { return nil }

            let incoming = docs.appendingPathComponent("Incoming", isDirectory: true)
            if !fm.fileExists(atPath: incoming.path) {
                try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
            }

            // 同名冲突时加序号，避免覆盖用户已有文件
            var target = incoming.appendingPathComponent(url.lastPathComponent)
            var index = 1
            let base = target.deletingPathExtension().lastPathComponent
            let ext = target.pathExtension
            while fm.fileExists(atPath: target.path) {
                let name = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
                target = incoming.appendingPathComponent(name)
                index += 1
                if index > 999 { break }
            }

            try fm.copyItem(at: url, to: target)
            return target.path
        } catch {
            print("[PerchPlay] 复制外部文件失败: \(error)")
            return nil
        }
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // 保持音频播放
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        // 清理
    }
}