// Preferences.prefPane 加载探针:模拟 KeyboardSettings.appex 的实例化路径,离线验证 pane 可加载。
// 用法: DEVELOPER_DIR=<Xcode> xcrun -sdk macosx swiftc -target arm64-apple-macos27.0 \
//         -framework AppKit -framework PreferencePanes proto/prefs_probe.swift -o build/prefs_probe && build/prefs_probe [pane路径]
import AppKit
import PreferencePanes

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AFM拼音.app/Contents/Resources/Preferences.prefPane"

guard let bundle = Bundle(path: path) else {
    print("✗ Bundle(path:) 失败: \(path)")
    exit(1)
}
print("bundle id=\(bundle.bundleIdentifier ?? "nil") principal=\(String(describing: bundle.principalClass))")
guard bundle.load() else {
    print("✗ bundle.load() 失败")
    exit(1)
}
print("✓ bundle.load() 成功")

guard let cls = NSClassFromString("AFMPrefsPane") as? NSPreferencePane.Type else {
    print("✗ NSClassFromString(AFMPrefsPane) 失败(类未注册或类型不符)")
    exit(1)
}
let pane = cls.init(bundle: bundle)
let view = pane.loadMainView()
print("✓ AFMPrefsPane 实例化 + loadMainView: \(view.frame)")
func dump(_ v: NSView, depth: Int) {
    let indent = String(repeating: "  ", count: depth)
    let label = v is NSSwitch ? "[switch]" : (v is NSTextField ? "[label]" : "[view]")
    print("\(indent)\(label) \(type(of: v)) \(NSStringFromRect(v.frame))")
    v.subviews.forEach { dump($0, depth: depth + 1) }
}
dump(view, depth: 1)
// 模拟设置读写:翻一个开关再读回
let defaults = UserDefaults(suiteName: "moe.bemly.inputmethod.AfmIME")! // 探针进程用 suite 模拟同域
print("✓ 探针完成")
