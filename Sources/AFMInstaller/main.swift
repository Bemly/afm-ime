import AppKit
import SwiftUI
import IMECore

// AFM拼音安装器:安装 → 一键注销 → (重登)完成启用;全程 GUI 化的首次安装流程
final class InstallModel: ObservableObject {
    @Published var status = IMEInstaller.statusSummary()
    @Published var log = "首次安装流程:① 安装并启用输入法 → ② 一键注销 → ③ 重新登录 → ④ 点「重登后:完成启用」\n(仅首次需要注销;之后装卸永久生效)\n\n"

    func refresh() {
        status = IMEInstaller.statusSummary()
    }

    func install() {
        var l = "———— ① 安装 ————\n"
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(IMEInstaller.imeAppName)")
        guard FileManager.default.fileExists(atPath: embedded.path) else {
            l += "✗ 安装器资源里没有 IME bundle(打包不完整)\n"
            log = l + log; refresh(); return
        }
        l += IMEInstaller.install(embeddedIMEURL: embedded)
        let e = IMEInstaller.enable()
        l += e.log
        l += "———— 完成 ————\n"
        log = l + log
        refresh()
    }

    func logout() {
        var l = "———— ② 一键注销 ————\n"
        l += IMEInstaller.requestLogout()
            ? "✓ 已触发注销(若弹出确认框,请点「注销」)…\n"
            : "✗ 触发失败,请手动:苹果菜单 → 注销\n"
        log = l + log
    }

    func postLoginFinish() {
        var l = "———— ④ 重登后:完成启用 ————\n"
        let r = IMEInstaller.postLoginFinish()
        l += r.log
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
                Button("① 安装并启用输入法") { model.install() }
                    .buttonStyle(.borderedProminent)
                Button("② 一键注销") { model.logout() }
                    .buttonStyle(.bordered)
                Button("③ 打开输入源设置") { model.openInputSourceSettings() }
            }
            HStack(spacing: 10) {
                Button("④ 重登后:完成启用") { model.postLoginFinish() }
                    .buttonStyle(.borderedProminent)
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
            Text("首次安装:①→②→重新登录→④,仅此一次;之后装卸永久生效。打字:Ctrl+Space 切换到 AFM拼音。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 500)
    }
}

let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
    styleMask: [.titled, .closable],
    backing: .buffered, defer: false)
window.title = "AFM拼音 安装器"
window.contentView = NSHostingView(rootView: ContentView())
window.center()
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
app.run()
