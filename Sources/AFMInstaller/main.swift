import AppKit
import SwiftUI
import IMECore

// AFM拼音安装器:一键 安装→注册→启用→选中;失败可一键直达输入源设置
final class InstallModel: ObservableObject {
    @Published var status = IMEInstaller.statusSummary()
    @Published var log = "TIS 三连:TISRegisterInputSource → TISEnableInputSource → TISSelectInputSource\n(TISEnable 对未公证包静默无效时,自动 defaults 直写兜底)\n\n"

    func refresh() {
        status = IMEInstaller.statusSummary()
    }

    func install() {
        var l = "———— 安装 ————\n"
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(IMEInstaller.imeAppName)")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            l += "✗ 安装器资源里没有 IME bundle(打包不完整)\n"
            log = l + log; refresh(); return
        }
        l += IMEInstaller.install(embeddedIMEURL: embedded)
        let e = IMEInstaller.enable()
        l += e.log
        if e.ok {
            let s = IMEInstaller.select()
            l += s.log
        }
        l += "———— 完成 ————\n"
        log = l + log
        refresh()
    }

    func uninstall() {
        log = "———— 卸载 ————\n" + IMEInstaller.uninstall() + log
        refresh()
    }

    func openInputSourceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = InstallModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "appicon", withExtension: "tiff"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().frame(width: 40, height: 40)
                }
                Text("AFM拼音").font(.title2.bold())
                Spacer()
            }
            Text(model.status).font(.callout)
            HStack(spacing: 10) {
                Button("安装并启用输入法") { model.install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("打开输入源设置") { model.openInputSourceSettings() }
                Spacer()
                Button("卸载", role: .destructive) { model.uninstall() }
                    .buttonStyle(.bordered)
            }
            ScrollView {
                Text(model.log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 130)
            Text("装好后按 Ctrl+Space 切换到 AFM拼音,在任意输入框打字即可。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }
}

let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
    styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
window.title = "AFM拼音 安装器"
window.contentView = NSHostingView(rootView: ContentView())
window.center()
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
app.run()
