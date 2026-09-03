import AppKit
import Foundation
import IMECore

// CLI 安装器(Squirrel/KeyTao 同款参数),逻辑在 IMECore.IMEInstaller
enum Installer {
    static func register() -> Int32 {
        let url = Bundle.main.bundleURL
        let st = IMEInstaller.register(bundleURL: url)
        print("TISRegisterInputSource(\(url.path)) = \(st)")
        if IMEInstaller.isRegistered() {
            print("注册生效: \(IMEInstaller.modeID)")
            return 0
        }
        print("!! 注册后 TIS 未列出 \(IMEInstaller.modeID)")
        return 1
    }

    static func enable() -> Int32 {
        let r = IMEInstaller.enable()
        print(r.log, terminator: "")
        return r.ok ? 0 : 1
    }

    static func select() -> Int32 {
        let r = IMEInstaller.select()
        print(r.log, terminator: "")
        return r.ok ? 0 : 1
    }

    static func setup() -> Int32 {
        var code = register()
        if code == 0 { code = enable() }
        if code == 0 { code = select() }
        return code
    }

    static func quitRunning() -> Int32 {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: IMEInstaller.bundleID) {
            app.terminate()
        }
        return 0
    }
}
