import AppKit
import InputMethodKit
import IMECore

// CLI 安装器模式(参考 squirrel --register-input-source 等)
let cliArgs = CommandLine.arguments
if cliArgs.count > 1 {
    let code: Int32
    switch cliArgs[1] {
    case "--register-input-source", "--install": code = Installer.register()
    case "--enable-input-source": code = Installer.enable()
    case "--select-input-source": code = Installer.select()
    case "--setup": code = Installer.setup() // 单进程连续 register+enable+select,避开 cfprefsd 冲掉瞬态注册
    case "--uninstall": code = { print(IMEInstaller.uninstall()); return 0 }()
    case "--quit": code = Installer.quitRunning()
    default:
        print("用法: AFMInput [--register-input-source|--enable-input-source|--select-input-source|--quit]")
        code = 2
    }
    exit(code)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer?
    /// 构建标记:日志里区分新旧进程(重装后防 launchd 复活旧二进制)
    static let buildTag = "20260906-kb10"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connName = (Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String) ?? "AFMInput_Connection"
        server = IMKServer(name: connName, bundleIdentifier: Bundle.main.bundleIdentifier)
        ClipboardMonitor.shared.start() // 剪贴板历史(⌃V 面板数据源,轮询 changeCount)
        ShiftModeMonitor.start() // Shift 中英切换监听(需输入监控权限,失败会记日志并在 activateServer 重试)
        DebugLog.log("输入法启动 build=\(Self.buildTag): bundle=\(Bundle.main.bundleIdentifier ?? "?") connection=\(connName) debug=\(DebugLog.isDebug) 日志=\(DebugLog.logPath) 词库引擎=\(InputController.engine != nil)")
        NSLog("[AFM] IMKServer 已启动 build=\(Self.buildTag) connection=%@ bundle=%@", connName, Bundle.main.bundleIdentifier ?? "?")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
