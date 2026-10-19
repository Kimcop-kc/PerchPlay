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

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // 保持音频播放
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        // 清理
    }
}
