import Foundation
import UIKit
import Darwin

/// 崩溃日志收集（iOS 原生侧）。
///
/// ## 为什么需要
///
/// Dart 侧的 `runZonedGuarded` / `FlutterError.onError` 只能接住 Dart 异常。
/// 但这个 App 的闪退大多发生在原生：
///
///  - **libmpv 段错误**（SIGSEGV）—— 播放器内核是 C 代码；
///  - **Metal / VideoToolbox / AudioToolbox 崩溃**（SIGABRT、SIGILL）；
///  - **watchdog 超时**（主线程卡死，SIGKILL，**任何方案都捕获不到**）。
///
/// 前两类可以用信号处理器接住并写盘；第三类系统直接 kill -9，
/// 只能靠「下次启动发现没留正常退出标记」间接推断。
///
/// ## 实现要点
///
/// ### 1. 信号处理函数必须 async-signal-safe
///
/// 处理函数运行在崩溃的那个线程上，此时堆可能已经损坏。所以**绝对不能**
/// 用 `String` 拼接、`Array` 字面量、`FileManager`、`DateFormatter` ——
/// 它们内部会 malloc / 取锁 / 触发 Swift 运行时，很容易二次崩溃，
/// 结果一条日志都写不出来。
///
/// 正确做法：只用 `open` / `write` / `close` / `strlen` 这几个 POSIX 调用，
/// 且所有缓冲区**在 install 阶段就分配好**，信号处理函数里只做纯指针运算。
///
/// （第一版这里踩了坑：在处理函数里 `var buffer = [CChar](repeating: 0, ...)`。
/// 数组字面量会分配内存，正好违反上述规则。现在改为全局预分配缓冲区。）
///
/// ### 2. 重新抛出信号
///
/// 写完盘后必须把信号交还给系统，否则 App 会「假活着」—— 界面卡死却不退出，
/// 用户以为死机；系统也不会生成 .ips 崩溃报告。
///
/// ### 3. 只拦致命信号
///
/// 不拦 SIGPIPE 之类非致命信号（播放器解码线程可能正常触发），
/// 全部拦下来只会产生噪音。
final class CrashLog {

    // MARK: - 常量

    private static let dirName = "perchplay_logs"
    private static let fileName = "native_crash.log"
    private static let maxBytes = 128 * 1024

    // MARK: - 预分配缓冲区（信号处理函数里唯一允许使用的东西）

    /// 崩溃文件路径（UTF-8 C 字符串），install 阶段分配，永不释放。
    ///
    /// 用 `UnsafeMutablePointer` 而不是 Swift `Array`：数组的下标访问
    /// 会经过 Swift 运行时的边界检查与独占性检查，在信号上下文里不安全。
    private static var crashPath: UnsafeMutablePointer<CChar>?

    /// 文本缓冲区大小。
    ///
    /// 1024 字节要装下「APP 版本 + iOS 版本 + 设备型号 + 信号号」这一节；
    /// 文件是追加写的，多次崩溃会攒成多节。
    private static let bufferSize = 1024
    private static var textBuffer: UnsafeMutablePointer<CChar>?

    /// 崩溃记录头的纯 ASCII 文本，**在 install 阶段**写成 C 字符串。
    ///
    /// 为什么不在处理函数里写中文字面量：Swift 的 `String` 字面量需要
    /// 走运行时构造，含非 ASCII 时还要做 UTF-8 编码 —— 都是内存分配。
    /// 这里提前烤成字节数组，处理函数里只做逐字节 memcpy。
    private static var headerBytes: UnsafeMutablePointer<CChar>?
    private static var headerLength: Int = 0

    private static var installed = false

    // MARK: - 安装

    /// 装上崩溃钩子。必须在 `didFinishLaunching` 最早期调用。
    static func install() {
        guard !installed else { return }
        installed = true

        prepareBuffers()
        installExceptionHandler()
        installSignalHandlers()
    }

    /// 预先算好路径、分配好缓冲区。此后再不分配内存。
    private static func prepareBuffers() {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        let dir = docs.appendingPathComponent(dirName, isDirectory: true)
        // 这里可以安全用 FileManager（还没进信号上下文）
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let file = dir.appendingPathComponent(fileName)

        // 路径转 C 字符串，整段生命周期常驻
        crashPath = makeCString(file.path)

        // 文本缓冲区按固定大小分配一次
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        for i in 0..<bufferSize {
            buf[i] = 0
        }
        textBuffer = buf

        // 预烤崩溃记录头。
        //
        // 关键：这里是**唯一**能做字符串拼接的地方。把设备/系统信息提前
        // 烤进去，信号处理函数里就只剩纯字节拷贝 —— 否则崩溃时再调
        // UIDevice.current 会分配内存并取锁，极易二次崩溃。
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        let header = """
        ===== native crash (signal) =====
        app = \(version) (\(build))
        os = iOS \(UIDevice.current.systemVersion)
        device = \(UIDevice.current.model)
        signal = """
        headerBytes = makeCString(header)
        headerLength = header.utf8.count
    }

    /// 把 Swift 字符串烘焙成常驻 C 字符串（普通上下文调用）。
    private static func makeCString(_ s: String) -> UnsafeMutablePointer<CChar> {
        let bytes = Array(s.utf8CString) // 含结尾 NUL
        let count = bytes.count
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: count)
        // 不用 withUnsafeBufferPointer + initialize(from:count:)：
        // 那个重载在部分 SDK 上签名不同，这里逐字节拷最保险。
        for i in 0..<count {
            p[i] = bytes[i]
        }
        return p
    }

    /// NSException（Objective-C 异常）处理器。
    ///
    /// 这类异常不走信号机制。典型来源是 UIKit / Flutter 的断言失败。
    /// 它在**普通**上下文里执行，可以安全用 Foundation。
    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "（无 reason）"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let text = """
            ===== 未捕获的 Objective-C 异常 =====
            时间: \(CrashLog.timestamp())
            异常名: \(name)
            原因: \(reason)
            ---------- 堆栈 ----------
            \(stack)
            """
            CrashLog.appendSafely(text)
        }
    }

    /// 信号处理器：真正的硬崩溃（段错误、abort 等）。
    private static func installSignalHandlers() {
        let sigs: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

        for sig in sigs {
            // 用 signal() 而不是 sigaction()：
            //
            // Darwin 上的 signal() 是 **BSD 语义** —— 处理函数被调用后
            // 不会被重置成 SIG_DFL，且被中断的系统调用自动重启。这两点
            // 正是我们需要的。
            //
            // 而 sigaction() 在 Swift 里要用到 C 的 union（sa_handler /
            // sa_sigaction 二选一），Swift 侧赋值必须 unsafeBitCast，
            // 跨 SDK 版本容易出岔子。对「记一笔然后重新抛出」这个用途，
            // signal() 足够且更稳。
            _ = signal(sig, signalHandler)
        }
    }

    /// 信号处理函数。
    ///
    /// 全函数只用：预分配指针、纯算术、`open` / `write` / `close` /
    /// `strlen` / `signal` / `raise`。**不允许**任何内存分配、不允许
    /// Swift `String` / `Array` 字面量、不允许闭包捕获。
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        guard let buf = CrashLog.textBuffer,
              let path = CrashLog.crashPath,
              let header = CrashLog.headerBytes
        else {
            // 缓冲区没准备好（理论上不会），直接把信号交还系统
            _ = signal(sig, SIG_DFL)
            _ = raise(sig)
            return
        }

        // 逐字节拷贝预烤好的记录头 —— 纯 memcpy 语义，无分配
        let hlen = CrashLog.headerLength
        let cap = CrashLog.bufferSize - 8  // 给信号号 + 换行 + NUL 留位
        var i = 0
        while i < hlen && i < cap {
            buf[i] = header[i]
            i += 1
        }

        // 信号编号转十进制（纯算术，无分配）
        if sig >= 100 {
            buf[i] = CChar(48 + sig / 100)
            i += 1
        }
        if sig >= 10 {
            buf[i] = CChar(48 + (sig / 10) % 10)
            i += 1
        }
        buf[i] = CChar(48 + sig % 10)
        i += 1

        // 结尾换行 + NUL
        buf[i] = 10
        i += 1
        buf[i] = 0

        // 追加写崩溃文件（O_WRONLY | O_CREAT | O_APPEND）
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            // strlen 返回 UInt，write 的第三个参数要 Int —— Swift 不做隐式转换
            _ = write(fd, buf, Int(strlen(buf)))
            _ = close(fd)
        }

        // 把信号交还系统（默认处理 = 终止进程 + 生成 ips 报告）
        //
        // 必须重新抛出：否则 App 会「假活着」——界面卡死却不退出，
        // 用户以为死机了，系统也不会生成 .ips 崩溃报告。
        _ = signal(sig, SIG_DFL)
        _ = raise(sig)
    }

    // MARK: - 读取

    /// 取走上一次运行留下的崩溃记录（读完即删）。
    ///
    /// - Returns: 崩溃报告文本；没有记录时返回 `nil`。
    static func takeReport() -> String? {
        guard let dir = logDir() else { return nil }
        let file = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // 空文件也删掉，否则每次启动都提示
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        // 立刻删除：这是「上次」的记录，重复上报会让用户以为又崩了
        try? FileManager.default.removeItem(at: file)

        let clipped = text.count > 24_000
            ? String(text.suffix(24_000))
            : text
        return """
        ⚠ 上次运行在 iOS 原生层崩溃了
        （Dart 侧完全不会执行，所以这里只有原生堆栈）

        \(clipped)
        """
    }

    // MARK: - 辅助

    private static func logDir() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        return docs.appendingPathComponent(dirName, isDirectory: true)
    }

    /// 安全追加（异常处理器 / 普通上下文可用，**不可**用于信号处理函数）。
    private static func appendSafely(_ text: String) {
        guard let dir = logDir() else { return }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let file = dir.appendingPathComponent(fileName)

        // 体积上限保护，避免异常刷屏把沙盒写满
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int,
           size > maxBytes {
            return
        }

        let data = Data(text.utf8) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: file)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
