import AppKit
import SwiftUI
import IMECore

// AFM拼音.app(GUI 控制中心): 安装器 + 词库浏览 + 用户词权重 + 设置,液态玻璃风格。
// 写设置走 IME 域(UserDefaults(suiteName: moe.bemly.inputmethod.AfmIME) = 输入法进程的
// UserDefaults.standard 域),输入法每次按键现读现判,改动即时生效。
// 键名与 IMECore/UserPrefs.swift 逐字一致——两边都要改。
// 注意: 禁用 @State/@StateObject 等宏包装器(保持 CLT 回退构建可用),用 ObservableObject 家族。

private let imeDomain = "moe.bemly.inputmethod.AfmIME"
private let imeAppName = "AFM拼音.app" // 安装到 ~/Library/Input Methods 的 bundle 名

// MARK: - 数据模型

final class AppModel: ObservableObject {
    enum Tab: String, Identifiable, CaseIterable {
        case install, dict, user, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .install: return "安装"
            case .dict: return "词库"
            case .user: return "用户词"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .install: return "arrow.down.app"
            case .dict: return "character.book.closed"
            case .user: return "person.text.rectangle"
            case .settings: return "switch.2"
            }
        }
    }

    @Published var tab: Tab = .install

    // 安装
    @Published var status = IMEInstaller.statusSummary()
    @Published var installLog = "首次安装:① 安装并启用 → ② 一键注销 → 重登后即可用;日常更新点「更新输入法」(换盘+重启引擎,秒级)\n\n"

    // 词库
    @Published var dictSearch = "" { didSet { dictPage = 0; reloadDict() } }
    @Published var dictRows: [DictStore.RecordInfo] = []
    @Published var dictPage = 0 { didSet { reloadDict() } }
    @Published var dictStats = ""
    private(set) var store: DictStore?

    // 用户词
    struct UserRow: Identifiable {
        let id: String
        let word: String
        let pinyin: String
        let count: Int
        let score: Int
        let boost: Double
    }
    @Published var userRows: [UserRow] = []

    // 设置(键名 = UserPrefs)
    @Published var fuzzy: Bool { didSet { write("AFMFuzzyPinyin", fuzzy) } }
    @Published var fullWidthPunct: Bool { didSet { write("AFMFullWidthPunct", fullWidthPunct) } }
    @Published var fmEnhance: Bool { didSet { write("AFMFMEnhance", fmEnhance) } }
    @Published var userFreqEnabled: Bool { didSet { write("AFMUserFreqEnabled", userFreqEnabled) } }
    @Published var fontSize: Double { didSet { write("AFMCandidateFontSize", Int(fontSize)) } }
    @Published var confirmUninstall = false
    @Published var confirmClear = false

    private static var imeDefaults: UserDefaults {
        UserDefaults(suiteName: imeDomain) ?? .standard
    }

    init() {
        let d = Self.imeDefaults
        fuzzy = d.object(forKey: "AFMFuzzyPinyin") as? Bool ?? true
        fullWidthPunct = d.object(forKey: "AFMFullWidthPunct") as? Bool ?? true
        fmEnhance = d.object(forKey: "AFMFMEnhance") as? Bool ?? true
        userFreqEnabled = d.object(forKey: "AFMUserFreqEnabled") as? Bool ?? true
        fontSize = Double(d.object(forKey: "AFMCandidateFontSize") as? Int ?? 16)
        loadStore()
        reloadUserRows()
    }

    private func write(_ key: String, _ value: Bool) {
        Self.imeDefaults.set(value, forKey: key)
        NSLog("[AFMApp] 设置 \(key) = \(value)")
    }
    private func write(_ key: String, _ value: Int) {
        Self.imeDefaults.set(value, forKey: key)
        NSLog("[AFMApp] 设置 \(key) = \(value)")
    }

    // MARK: 词库

    /// 词库数据源: 已装输入法 bundle → 本 App 内嵌的输入法 bundle → 仓库 Data/(开发)
    private func loadStore() {
        let candidates = [
            IMEInstaller.installedIMEURL().appendingPathComponent("Contents/Resources/dict.bin").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(imeAppName)/Contents/Resources/dict.bin").path,
            "Data/dict.bin",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let s = try? DictStore(url: URL(fileURLWithPath: path)) {
                store = s
                dictStats = "记录 \(s.recordCount) 条 · 音节 \(s.syllables.count) 个 · \(path)"
                reloadDict()
                return
            }
        }
        dictStats = "未找到 dict.bin — 先安装输入法"
    }

    func reloadDict() {
        guard let store else { return }
        let term = dictSearch.lowercased().filter { ("a"..."z").contains($0) }
        if term.isEmpty {
            // 浏览模式: 按存储序分页(每页 100 条)
            dictRows = store.records(from: dictPage * 100, limit: 100)
        } else {
            let hits = store.query(prefix: term, exactCap: 40, extCap: 40, scanBudget: 200_000)
            dictRows = hits.map { DictStore.RecordInfo(key: $0.key, word: $0.word, weight: $0.weight) }
        }
    }

    var dictPageCount: Int {
        guard let store else { return 1 }
        return max(1, (store.recordCount + 99) / 100)
    }

    // MARK: 用户词

    func reloadUserRows() {
        let uf = UserFreq(defaults: Self.imeDefaults) // 复用打分公式(打分域 = IME 域)
        let counts = Self.imeDefaults.dictionary(forKey: "AFMUserFreq") as? [String: Int] ?? [:]
        let pins = Self.imeDefaults.dictionary(forKey: "AFMUserPinyin") as? [String: String] ?? [:]
        userRows = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (word, count) in
                UserRow(id: word, word: word, pinyin: pins[word] ?? "(未记录)",
                        count: count, score: Int(uf.userScore(count: count)), boost: uf.boost(word))
            }
    }

    func deleteUser(_ word: String) {
        var counts = Self.imeDefaults.dictionary(forKey: "AFMUserFreq") as? [String: Int] ?? [:]
        var pins = Self.imeDefaults.dictionary(forKey: "AFMUserPinyin") as? [String: String] ?? [:]
        counts.removeValue(forKey: word)
        pins.removeValue(forKey: word)
        Self.imeDefaults.set(counts, forKey: "AFMUserFreq")
        Self.imeDefaults.set(pins, forKey: "AFMUserPinyin")
        NSLog("[AFMApp] 删除用户词 '\(word)'")
        reloadUserRows()
    }

    func clearUsers() {
        Self.imeDefaults.removeObject(forKey: "AFMUserFreq")
        Self.imeDefaults.removeObject(forKey: "AFMUserPinyin")
        NSLog("[AFMApp] 清空用户词库")
        reloadUserRows()
    }

    // MARK: 安装

    var embeddedIMEURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(imeAppName)")
    }

    func installAndEnable() {
        var l = "———— 安装并启用 ————\n"
        guard FileManager.default.fileExists(atPath: embeddedIMEURL.path) else {
            installLog = l + "✗ App 内未内嵌输入法 bundle(打包不完整)\n" + installLog
            return
        }
        l += IMEInstaller.install(embeddedIMEURL: embeddedIMEURL)
        l += IMEInstaller.enable().log
        l += "若首次安装:点「一键注销」并重新登录,登录扫描收录后永久有效\n"
        installLog = l + installLog
        refreshStatus()
    }

    /// 日常更新(部署铁律): rm + cp 全量换盘 → killall → 确认死透 → open
    func redeploy() {
        var l = "———— 更新输入法 ————\n"
        let dest = IMEInstaller.installedIMEURL()
        guard FileManager.default.fileExists(atPath: embeddedIMEURL.path) else {
            installLog = l + "✗ App 内未内嵌输入法 bundle\n" + installLog
            return
        }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: embeddedIMEURL, to: dest)
            l += "✓ 已换盘 \(dest.path)\n"
        } catch {
            installLog = l + "✗ 换盘失败: \(error.localizedDescription)\n" + installLog
            return
        }
        runCmd("/usr/bin/killall", ["AFMInput"])
        var waited = 0
        while waited < 20, runCmd("/usr/bin/pgrep", ["-x", "AFMInput"], capture: true) != nil {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        if waited >= 20 { runCmd("/usr/bin/pkill", ["-9", "-x", "AFMInput"]) }
        NSWorkspace.shared.open(dest)
        l += "✓ 引擎已重启(build 见 /tmp/afm-ime.log)\n"
        installLog = l + installLog
        refreshStatus()
    }

    func openInputSourceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources") {
            NSWorkspace.shared.open(url)
        }
    }

    func logout() {
        installLog = (IMEInstaller.requestLogout() ? "———— 已触发注销,重登后输入法自动收录 ————\n" : "✗ 触发失败,请手动注销\n") + installLog
    }

    func uninstall() {
        installLog = "———— 卸载 ————\n" + IMEInstaller.uninstall() + installLog
        refreshStatus()
    }

    func refreshStatus() {
        status = IMEInstaller.statusSummary()
    }

    @discardableResult
    private func runCmd(_ path: String, _ args: [String], capture: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if capture {
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return nil
    }
}

// MARK: - 根视图(侧栏 + 详情)

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 168)
            Divider().opacity(0.4)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 780, height: 560)
        .background(.ultraThickMaterial) // 玻璃之上再铺材质,保证暗亮色下可读
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let url = Bundle.main.url(forResource: "appicon", withExtension: "tiff"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().frame(width: 30, height: 30)
                }
                Text("AFM拼音").font(.title3.bold())
            }
            .padding(.bottom, 14)
            ForEach(AppModel.Tab.allCases) { tab in
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon).frame(width: 18)
                        Text(tab.title)
                        Spacer()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background {
                        if model.tab == tab {
                            Capsule().fill(.white.opacity(0.16))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.tab == tab ? .primary : .secondary)
            }
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
    }

    @ViewBuilder private var detail: some View {
        switch model.tab {
        case .install: InstallView(model: model)
        case .dict: DictView(model: model)
        case .user: UserWordsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

/// 液态玻璃区块卡片(原生 glassEffect;材质底上叠加,暗亮色自适应)
struct GlassCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

// MARK: - 安装

struct InstallView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(title: "状态") {
                    Text(model.status).font(.callout)
                    HStack(spacing: 10) {
                        Button("安装并启用") { model.installAndEnable() }.buttonStyle(.borderedProminent)
                        Button("更新输入法(换盘+重启引擎)") { model.redeploy() }
                        Button("打开输入源设置") { model.openInputSourceSettings() }
                    }
                    HStack(spacing: 10) {
                        Button("一键注销(仅首次安装需要)") { model.logout() }
                        Button("卸载", role: .destructive) { model.confirmUninstall = true }
                    }
                    .confirmationDialog("卸载 AFM拼音 输入法?", isPresented: $model.confirmUninstall, titleVisibility: .visible) {
                        Button("卸载", role: .destructive) { model.uninstall() }
                    } message: {
                        Text("停用并删除 ~/Library/Input Methods 中的输入法 bundle 与启用条目。")
                    }
                }
                GlassCard(title: "安装日志") {
                    Text(model.installLog)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 词库

struct DictView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("拼音前缀搜索(如 nihao / nh / meibeng)", text: $model.dictSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Text(model.dictStats.isEmpty ? "加载中…" : model.dictStats)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14)

            if model.dictSearch.isEmpty {
                HStack {
                    Button("‹ 上一页") { if model.dictPage > 0 { model.dictPage -= 1 } }
                        .disabled(model.dictPage == 0)
                    Text("第 \(model.dictPage + 1) / \(model.dictPageCount) 页").font(.caption).foregroundStyle(.secondary)
                    Button("下一页 ›") { if model.dictPage < model.dictPageCount - 1 { model.dictPage += 1 } }
                        .disabled(model.dictPage >= model.dictPageCount - 1)
                    Spacer()
                    Text("存储序 = 拼音键字典序,同键内词频降序").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
            } else {
                Text("搜索 \(model.dictRows.count) 条(显示前 80)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            List(Array(model.dictRows.prefix(80).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    Text(row.word).font(.system(size: 15, weight: .medium)).frame(minWidth: 90, alignment: .leading)
                    Text(row.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text("权重 \(row.weight)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - 用户词

struct UserWordsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("共 \(model.userRows.count) 条 · 用户词处于最高优先档(用户 2 > 全键 1 > 渐进 0),打分 = 2万 + 1.5万·log10(1+次数),词频乘数 = min(1 + 0.5·log10(1+次数), ×3) 仅 ≥2 字词")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { model.reloadUserRows() }
                Button("清空全部", role: .destructive) { model.confirmClear = true }
                    .disabled(model.userRows.isEmpty)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            .confirmationDialog("清空全部用户词与词频?", isPresented: $model.confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) { model.clearUsers() }
            }

            List {
                ForEach(model.userRows) { row in
                    HStack(spacing: 12) {
                        Text(row.word).font(.system(size: 15, weight: .medium)).frame(minWidth: 90, alignment: .leading)
                        Text(row.pinyin).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(row.count) 次").font(.caption).foregroundStyle(.secondary)
                        Text("档内分 \(row.score)").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "×%.2f", row.boost)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .contextMenu {
                        Button("删除「\(row.word)」", role: .destructive) { model.deleteUser(row.word) }
                    }
                }
            }
            .listStyle(.inset)
            .padding(.horizontal, 10)
            Text("右键条目可删除 · 上屏自动学习(词组学习:分段组句整词组入词库)")
                .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 16)
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(title: "引擎") {
                    Toggle("模糊拼音", isOn: $model.fuzzy)
                    Toggle("全角标点", isOn: $model.fullWidthPunct)
                    Toggle("FM 增强(端侧模型重排 + 整句预测)", isOn: $model.fmEnhance)
                    Toggle("记住打过的词(用户词库 + 词频加成)", isOn: $model.userFreqEnabled)
                    Text("改动即时生效,输入法每次按键现读;开关状态写入 moe.bemly.inputmethod.AfmIME 域")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GlassCard(title: "外观") {
                    HStack {
                        Text("候选条字号").frame(width: 90, alignment: .leading)
                        Slider(value: $model.fontSize, in: 13...22, step: 1)
                            .frame(maxWidth: 260)
                        Text("\(Int(model.fontSize)) pt").monospacedDigit().frame(width: 44)
                    }
                    Text("仅候选条生效;展开网格的行距按 28pt 几何闭合,字号固定。改动打字时即可看到。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GlassCard(title: "说明") {
                    Text("中英模式:轻点 Shift 随时切换(全部应用生效,跨重启记忆),故不在此重复提供开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "appicon", withExtension: "tiff"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "AFM拼音"
        win.contentView = NSHostingView(rootView: RootView(model: model))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSLog("[AFMApp] 启动 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") 词库=\(model.store != nil ? "已加载" : "未找到")")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
