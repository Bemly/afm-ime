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
    static let buildTag = "20260908-kb35"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 幽灵副本自愈(必须先于 IMKServer 初始化——副本若用同一连接名起完整引擎,会劫持客户端
        // 的 IMK 连接,退出后连接断掉,表现为全局打不了字,kb32 时代 23:03 事故实锤):
        // 从非安装位置被点击启动时,同步清自己的 LaunchServices 注册后立即退出,不碰任何引擎设施
        if IMEInstaller.isBundleInstalled(),
           Bundle.main.bundleURL.standardizedFileURL.path != IMEInstaller.installedIMEURL().standardizedFileURL.path {
            DebugLog.log("幽灵副本启动(\(Bundle.main.bundleURL.path))→ 自清 LaunchServices 注册并退出(不初始化引擎)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            p.arguments = ["-u", Bundle.main.bundleURL.path]
            do { try p.run(); p.waitUntilExit() } catch { }
            exit(0)
        }
        let connName = (Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String) ?? "AFMInput_Connection"
        server = IMKServer(name: connName, bundleIdentifier: Bundle.main.bundleIdentifier)
        ClipboardMonitor.shared.start() // 剪贴板历史(⌃V 面板数据源,轮询 changeCount)
        ShiftModeMonitor.start() // Shift 中英切换监听(需输入监控权限,失败会记日志并在 activateServer 重试)
        DebugLog.log("输入法启动 build=\(Self.buildTag): bundle=\(Bundle.main.bundleIdentifier ?? "?") connection=\(connName) debug=\(DebugLog.isDebug) 日志=\(DebugLog.logPath) 词库引擎=\(InputController.engine != nil)")
        DebugLog.log("设置: 英文=\(UserPrefs.englishMode) 模糊=\(UserPrefs.fuzzyPinyin) 全角=\(UserPrefs.fullWidthPunct) FM=\(UserPrefs.fmEnhance) 词频=\(UserPrefs.userFreq) 字号=\(UserPrefs.candidateFontSize)(设置中心写入)")
        // 直接打开引擎 bundle(未安装态,如从 build/DMG 双击)→ 自动拉起设置中心完成一键安装;
        // 已安装后 launchd 按需拉起时 bundle 在安装位置,不会走这一支
        if !IMEInstaller.isBundleInstalled() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettingsHelper()
            }
        }
        NSLog("[AFM] IMKServer 已启动 build=\(Self.buildTag) connection=%@ bundle=%@", connName, Bundle.main.bundleIdentifier ?? "?")
    }

    private func openSettingsHelper() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/AFMSettings.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLog.error("设置中心 helper 缺失: \(url.path)")
            return
        }
        DebugLog.log("未安装态启动 → 自动打开设置中心")
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
