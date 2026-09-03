import Foundation

/// 调试日志:debug 开关 = AFM_DEBUG=1 环境变量 或 存在标志文件 /tmp/afm-ime-debug
/// (launchd 拉起的进程拿不到 shell 环境变量,所以用标志文件)。日志写 /tmp/afm-ime.log(AFAM_LOG 可覆盖)。
/// error 级别不受开关限制(崩溃排查必需),额外写 NSLog 进统一日志。
public enum DebugLog {
    public static var isDebug: Bool {
        ProcessInfo.processInfo.environment["AFM_DEBUG"] == "1"
            || FileManager.default.fileExists("/tmp/afm-ime-debug")
    }
    public static var logPath: String {
        ProcessInfo.processInfo.environment["AFM_LOG"] ?? "/tmp/afm-ime.log"
    }

    private static let queue = DispatchQueue(label: "moe.bemly.afm.debuglog")
    private static var handle: FileHandle?
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        guard isDebug else { return }
        write("DEBUG", message, file: file, line: line, function: function)
    }

    public static func error(_ message: String, file: String = #file, line: Int = #line, function: String = #function) {
        write("ERROR", message, file: file, line: line, function: function)
        NSLog("[AFM][ERROR] %@", message)
    }

    /// 计时工具:闭包耗时(ms)与返回值一起记日志(仅 debug)
    @discardableResult
    public static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard isDebug else { return try body() }
        let t0 = Date()
        let value = try body()
        log("\(label): \(String(format: "%.2f", -t0.timeIntervalSinceNow * 1000))ms")
        return value
    }

    private static func write(_ level: String, _ message: String, file: String, line: Int, function: String) {
        let fname = (file as NSString).lastPathComponent
        let text = "[\(tsFormatter.string(from: Date()))] [\(level)] [\(fname):\(line) \(function)] \(message)\n"
        queue.sync {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: logPath) {
                    FileManager.default.createFile(atPath: logPath, contents: nil)
                }
                handle = FileHandle(forWritingAtPath: logPath)
                handle?.seekToEndOfFile()
            }
            if let data = text.data(using: .utf8) {
                handle?.write(data)
            }
            if level == "DEBUG" {
                FileHandle.standardError.write(data(text))
            }
        }
    }

    private static func data(_ s: String) -> Data { Data(s.utf8) }
}
