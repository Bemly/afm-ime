import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IMECore

// AFM拼音.app(GUI 控制中心): 安装器 + 词库浏览 + 用户词权重 + 设置,液态玻璃风格。
// 写设置走 IME 域(UserDefaults(suiteName: moe.bemly.inputmethod.AfmIME) = 输入法进程的
// UserDefaults.standard 域),输入法每次按键现读现判,改动即时生效。
// 键名与 IMECore/UserPrefs.swift 逐字一致——两边都要改。
// 注意: 禁用 @State/@StateObject 等宏包装器(保持 CLT 回退构建可用),用 ObservableObject 家族。

private let imeDomain = "moe.bemly.inputmethod.AfmIME"

// MARK: - 数据模型

final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Tab: String, Identifiable, CaseIterable {
        case install, dict, user, translate, model, test, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .install: return "安装"
            case .dict: return "词库"
            case .user: return "用户词"
            case .translate: return "翻译"
            case .model: return "模型"
            case .test: return "测试"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .install: return "arrow.down.app"
            case .dict: return "character.book.closed"
            case .user: return "person.text.rectangle"
            case .translate: return "translate"
            case .model: return "cpu"
            case .test: return "flask"
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
    @Published var userMessage = ""   // 导入结果等一次性提示

    // 设置(键名 = UserPrefs)
    @Published var fuzzy: Bool { didSet { write("AFMFuzzyPinyin", fuzzy) } }
    @Published var fullWidthPunct: Bool { didSet { write("AFMFullWidthPunct", fullWidthPunct) } }
    @Published var fmEnhance: Bool { didSet { write("AFMFMEnhance", fmEnhance) } }
    @Published var userFreqEnabled: Bool { didSet { write("AFMUserFreqEnabled", userFreqEnabled) } }
    @Published var fontSize: Double { didSet { write("AFMCandidateFontSize", Int(fontSize)) } }
    // 测试:固定透镜拖拽(droplet-relative-motion 支线移植)——键名与 UserPrefs.dropletFixedLens 逐字一致
    @Published var dropletFixedLens: Bool { didSet { write("AFMDropletFixedLens", dropletFixedLens) } }
    @Published var confirmUninstall = false
    @Published var confirmClear = false

    // 快捷键(kb35): IME handle 现读现判,defaults 只存 keyCode(+显示字符免查键码表);
    // 修饰固定为 ⌃(IME 拦截层只拦 ⌃ 组合),录制时强制校验
    struct HotkeyRow: Identifiable {
        let id: String        // defaults 键(AFMHotkey…)
        let title: String
        let display: String   // 如 "⌃V"
        let custom: Bool      // 是否已被用户改过
    }
    static let hotkeySlots: [(key: String, displayKey: String, fallback: Int, fallbackDisplay: String, title: String)] = [
        ("AFMHotkeyClipboard", "AFMHotkeyClipboardDisplay", 9, "V", "剪贴板历史(⌃主键)"),
        ("AFMHotkeyTranslate", "AFMHotkeyTranslateDisplay", 3, "F", "内联翻译(组词中,⌃主键)"),
        ("AFMHotkeySettings", "AFMHotkeySettingsDisplay", 1, "S", "设置中心(⌃主键)"),
    ]
    @Published var hotkeyRows: [HotkeyRow] = []
    @Published var recordingHotkey: String? = nil   // 正在录制的槽(nil=未在录)
    @Published var hotkeyHint = ""
    private var hotkeyMonitor: Any?

    // 模型(kb36):云端模型(Provider 协议接入)+ 端侧 FM 提示词;键名 = IMECore.ModelPrefs 常量(单一来源)
    static let cloudPresets: [(id: String, name: String, baseURL: String, format: String, model: String)] = [
        ("openai", "OpenAI", "https://api.openai.com/v1", "openai", "gpt-4o-mini"),
        ("anthropic", "Anthropic", "https://api.anthropic.com", "anthropic", "claude-sonnet-4-5"),
        ("deepseek", "DeepSeek", "https://api.deepseek.com/v1", "openai", "deepseek-chat"),
        ("kimi", "Kimi(月之暗面)", "https://api.moonshot.cn/v1", "openai", "moonshot-v1-8k"),
        ("zhipu", "智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "openai", "glm-4-flash"),
        ("qwen", "通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", "openai", "qwen-plus"),
        ("ark", "豆包(火山方舟)", "https://ark.cn-beijing.volces.com/api/v3", "openai", ""),
        ("ollama", "Ollama(本机)", "http://127.0.0.1:11434/v1", "openai", ""),
        ("custom", "自定义", "", "openai", ""),
    ]
    @Published var cloudEnabled: Bool { didSet { write(ModelPrefs.cloudEnabledKey, cloudEnabled) } }
    @Published var cloudProvider: String { didSet { write(ModelPrefs.cloudProviderKey, cloudProvider); applyCloudPreset() } }
    @Published var cloudBaseURL: String { didSet { write(ModelPrefs.cloudBaseURLKey, cloudBaseURL) } }
    @Published var cloudAPIKey: String { didSet { write(ModelPrefs.cloudAPIKeyKey, cloudAPIKey) } }
    @Published var cloudModel: String { didSet { write(ModelPrefs.cloudModelKey, cloudModel) } }
    @Published var cloudFormat: String { didSet { write(ModelPrefs.cloudFormatKey, cloudFormat) } }
    // 提示词 = 草稿-应用模式(kb36.1):编辑框预填当前生效值(覆盖 ?? 内置默认),编辑不落盘,
    // 点「应用」才写入(与内置一致的草稿会清掉覆盖键,保证内置更新可跟随);引擎/helper 现读现判
    @Published var promptRerank = ""
    @Published var promptSentence = ""
    @Published var promptTranslateEN = ""
    @Published var promptTranslateZH = ""
    @Published var promptAppliedHint = ""
    @Published var cloudTestResult = ""
    @Published var cloudTesting = false

    /// 选预设 → 自动填接口地址/格式/模型名(自定义不覆盖已填内容)
    private func applyCloudPreset() {
        guard let p = Self.cloudPresets.first(where: { $0.id == cloudProvider }), !p.baseURL.isEmpty else { return }
        cloudBaseURL = p.baseURL
        cloudFormat = p.format
        if !p.model.isEmpty { cloudModel = p.model }
    }

    func testCloud() {
        guard !cloudTesting else { return }
        cloudTesting = true
        cloudTestResult = ""
        Task {
            let out = await CloudProviderModel.probe(baseURL: cloudBaseURL, apiKey: cloudAPIKey,
                                                     modelName: cloudModel, wireFormat: cloudFormat)
            await MainActor.run {
                cloudTesting = false
                cloudTestResult = out
            }
        }
    }

    /// 应用提示词草稿:与内置默认一致的段落清掉覆盖键(跟随内置更新),其余写入
    func applyPrompts() {
        let d = Self.imeDefaults
        let pairs: [(key: String, value: String, def: String)] = [
            (ModelPrefs.promptRerankKey, promptRerank, FMReranker.defaultRerankInstructions),
            (ModelPrefs.promptSentenceKey, promptSentence, FMReranker.defaultSentenceInstructions),
            (ModelPrefs.promptTranslateENKey, promptTranslateEN, FMReranker.defaultTranslateENInstructions),
            (ModelPrefs.promptTranslateZHKey, promptTranslateZH, FMReranker.defaultTranslateZHInstructions),
        ]
        for p in pairs {
            let blank = p.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank || p.value == p.def {
                d.removeObject(forKey: p.key)
            } else {
                d.set(p.value, forKey: p.key)
            }
            NSLog("[AFMApp] 提示词应用 \(p.key)(\(blank || p.value == p.def ? "默认" : "自定义"))")
        }
        promptAppliedHint = "已应用,输入法即时生效 ✓"
    }

    /// 全部恢复默认:草稿填回内置默认并立即应用
    func resetPrompts() {
        promptRerank = FMReranker.defaultRerankInstructions
        promptSentence = FMReranker.defaultSentenceInstructions
        promptTranslateEN = FMReranker.defaultTranslateENInstructions
        promptTranslateZH = FMReranker.defaultTranslateZHInstructions
        applyPrompts()
        NSLog("[AFMApp] FM 提示词全部恢复默认")
    }

    // 翻译(端侧 FM,与引擎进程共用 IMECore.FMReranker;方向自动:含中文→英,否则→中)
    @Published var translateInput = ""
    @Published var translateResult = ""
    @Published var translating = false

    var translateDirection: String {
        if translateInput.trimmingCharacters(in: .whitespaces).isEmpty { return "自动" }
        let hasCJK = translateInput.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return hasCJK ? "中 → 英" : "英 → 中"
    }

    func submitTranslate() {
        let text = translateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !translating else { return }
        translating = true
        translateResult = ""
        Task {
            let out = await FMReranker.shared.translate(text)
            await MainActor.run {
                translating = false
                translateResult = out ?? "翻译失败 — 端侧模型不可用或未输出结果"
            }
        }
    }

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
        dropletFixedLens = d.object(forKey: "AFMDropletFixedLens") as? Bool ?? false
        cloudEnabled = d.object(forKey: ModelPrefs.cloudEnabledKey) as? Bool ?? false
        cloudProvider = d.string(forKey: ModelPrefs.cloudProviderKey) ?? "openai"
        cloudBaseURL = d.string(forKey: ModelPrefs.cloudBaseURLKey) ?? ""
        cloudAPIKey = d.string(forKey: ModelPrefs.cloudAPIKeyKey) ?? ""
        cloudModel = d.string(forKey: ModelPrefs.cloudModelKey) ?? ""
        cloudFormat = d.string(forKey: ModelPrefs.cloudFormatKey) ?? "openai"
        promptRerank = (d.string(forKey: ModelPrefs.promptRerankKey) ?? "").isEmpty ? FMReranker.defaultRerankInstructions : d.string(forKey: ModelPrefs.promptRerankKey)!
        promptSentence = (d.string(forKey: ModelPrefs.promptSentenceKey) ?? "").isEmpty ? FMReranker.defaultSentenceInstructions : d.string(forKey: ModelPrefs.promptSentenceKey)!
        promptTranslateEN = (d.string(forKey: ModelPrefs.promptTranslateENKey) ?? "").isEmpty ? FMReranker.defaultTranslateENInstructions : d.string(forKey: ModelPrefs.promptTranslateENKey)!
        promptTranslateZH = (d.string(forKey: ModelPrefs.promptTranslateZHKey) ?? "").isEmpty ? FMReranker.defaultTranslateZHInstructions : d.string(forKey: ModelPrefs.promptTranslateZHKey)!
        loadStore()
        reloadUserRows()
        loadHotkeys()
    }

    private func write(_ key: String, _ value: Bool) {
        Self.imeDefaults.set(value, forKey: key)
        NSLog("[AFMApp] 设置 \(key) = \(value)")
    }
    private func write(_ key: String, _ value: Int) {
        Self.imeDefaults.set(value, forKey: key)
        NSLog("[AFMApp] 设置 \(key) = \(value)")
    }
    private func write(_ key: String, _ value: String) {
        Self.imeDefaults.set(value, forKey: key)
        NSLog("[AFMApp] 设置 \(key) = \(value.prefix(60))")
    }

    // MARK: 快捷键(kb35)

    private func loadHotkeys() {
        let d = Self.imeDefaults
        hotkeyRows = Self.hotkeySlots.map { slot in
            let custom = d.object(forKey: slot.key) != nil
            let disp = d.string(forKey: slot.displayKey) ?? slot.fallbackDisplay
            return HotkeyRow(id: slot.key, title: slot.title, display: "⌃\(disp)", custom: custom)
        }
    }

    private func effectiveCode(_ slot: (key: String, displayKey: String, fallback: Int, fallbackDisplay: String, title: String)) -> Int {
        Self.imeDefaults.object(forKey: slot.key) as? Int ?? slot.fallback
    }

    func startRecording(_ id: String) {
        stopRecording()
        recordingHotkey = id
        hotkeyHint = "按下新的快捷键(⌃ + 字母/数字/符号)… Esc 取消"
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.recordingHotkey != nil else { return ev }
            self.handleRecordEvent(ev)
            return nil // 录制期间吞掉按键
        }
    }

    func stopRecording() {
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m); hotkeyMonitor = nil }
        recordingHotkey = nil
        hotkeyHint = ""
    }

    func resetHotkeys() {
        for slot in Self.hotkeySlots {
            Self.imeDefaults.removeObject(forKey: slot.key)
            Self.imeDefaults.removeObject(forKey: slot.displayKey)
        }
        NSLog("[AFMApp] 快捷键全部恢复默认")
        loadHotkeys()
        stopRecording()
    }

    private func handleRecordEvent(_ ev: NSEvent) {
        if ev.keyCode == 53 { stopRecording(); return } // Esc 取消
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control), !mods.contains(.option), !mods.contains(.command), !mods.contains(.shift),
              let display = displayChar(for: ev) else {
            hotkeyHint = "需要 ⌃ + 单个字母/数字/符号(Option/Command/Shift 组合与功能键不支持),Esc 取消"
            return
        }
        guard let slot = Self.hotkeySlots.first(where: { $0.key == recordingHotkey }) else {
            stopRecording(); return
        }
        if let dup = Self.hotkeySlots.first(where: { $0.key != slot.key && effectiveCode($0) == Int(ev.keyCode) }) {
            hotkeyHint = "与「\(dup.title)」冲突,换一个键"
            return
        }
        Self.imeDefaults.set(Int(ev.keyCode), forKey: slot.key)
        Self.imeDefaults.set(display, forKey: slot.displayKey)
        NSLog("[AFMApp] 快捷键 \(slot.key) = ⌃\(display) (keyCode \(ev.keyCode))")
        loadHotkeys()
        stopRecording()
    }

    /// 录制显示字符: 字母大写、数字/可打印符号原样;功能键/方向键等显示不出的不支持
    private func displayChar(for ev: NSEvent) -> String? {
        guard let chars = ev.charactersIgnoringModifiers, !chars.isEmpty,
              let scalar = chars.unicodeScalars.first else { return nil }
        let v = scalar.value
        if (97...122).contains(v) { return String(scalar).uppercased() } // a-z
        if (48...57).contains(v) || (32...47).contains(v) || (58...64).contains(v)
            || (91...96).contains(v) || (123...126).contains(v) { return chars } // 数字与可打印符号
        return nil
    }

    // MARK: 词库

    /// 本 helper 位于 引擎.app/Contents/PlugIns/AFMSettings.app → 上三级即引擎 bundle
    var engineBundleURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    var runningFromInstalledLocation: Bool {
        engineBundleURL.standardizedFileURL.path == IMEInstaller.installedIMEURL().standardizedFileURL.path
    }

    /// 词库数据源: 已装输入法 bundle → 本 helper 的父引擎 bundle → 仓库 Data/(开发)
    private func loadStore() {
        let candidates = [
            IMEInstaller.installedIMEURL().appendingPathComponent("Contents/Resources/dict.bin").path,
            engineBundleURL.appendingPathComponent("Contents/Resources/dict.bin").path,
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
        UserFreq.tombstone(words: [word], defaults: Self.imeDefaults) // 删过的不随内置种子版本升级复活
        NSLog("[AFMApp] 删除用户词 '\(word)'")
        UserFreq.postExternalChange() // 引擎内存副本持有旧表,不广播会被下次防抖保存复活
        reloadUserRows()
    }

    func clearUsers() {
        let counts = Self.imeDefaults.dictionary(forKey: "AFMUserFreq") as? [String: Int] ?? [:]
        UserFreq.tombstone(words: Array(counts.keys), defaults: Self.imeDefaults) // 清空前全部记墓碑
        Self.imeDefaults.removeObject(forKey: "AFMUserFreq")
        Self.imeDefaults.removeObject(forKey: "AFMUserPinyin")
        NSLog("[AFMApp] 清空用户词库(墓碑 \(counts.count) 条)")
        UserFreq.postExternalChange()
        reloadUserRows()
    }

    /// 导入用户词:JSON 文件(与内置 builtin-user-words.json 同格式,见 Data/builtin-user-words.json
    /// 头部 note),合并进 IME 域——已有词取次数较大者、拼音仅缺省才补(本机数据优先,同文不降档),
    /// 导入的词解除墓碑(显式带回=用户改主意),写完广播引擎重读(kb40)
    func importUsers() {
        let panel = NSOpenPanel()
        panel.title = "导入用户词"
        panel.message = "JSON 文件,格式同内置用户词种子:{\"version\":1,\"words\":[{\"word\":\"词\",\"pinyin\":\"pin yin\",\"count\":3}]}"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = doc["words"] as? [[String: Any]] else {
            userMessage = "导入失败:不是有效的用户词 JSON(缺 words 数组或格式不对)"
            return
        }
        var counts = Self.imeDefaults.dictionary(forKey: "AFMUserFreq") as? [String: Int] ?? [:]
        var pins = Self.imeDefaults.dictionary(forKey: "AFMUserPinyin") as? [String: String] ?? [:]
        var added = 0, updated = 0, skipped = 0
        var importedWords: [String] = []
        for item in items {
            guard let word = item["word"] as? String, !word.isEmpty, word.count <= 50,
                  let count = item["count"] as? Int, count > 0 else {
                skipped += 1
                continue
            }
            importedWords.append(word)
            if let existing = counts[word] {
                if count > existing { counts[word] = count; updated += 1 }
            } else {
                counts[word] = count
                added += 1
            }
            if let p = item["pinyin"] as? String, UserFreq.isValidPinyin(p), pins[word] == nil {
                pins[word] = p
            }
        }
        Self.imeDefaults.set(counts, forKey: "AFMUserFreq")
        Self.imeDefaults.set(pins, forKey: "AFMUserPinyin")
        UserFreq.untombstone(words: importedWords, defaults: Self.imeDefaults)
        UserFreq.postExternalChange()
        NSLog("[AFMApp] 导入用户词: 新增 \(added) 更新 \(updated) 跳过 \(skipped)(源 \(url.lastPathComponent))")
        userMessage = "导入完成:新增 \(added) 条、更新 \(updated) 条\(skipped > 0 ? "、跳过非法 \(skipped) 条" : "")(共 \(counts.count) 条)"
        reloadUserRows()
    }

    // MARK: 安装

    var embeddedIMEURL: URL {
        engineBundleURL // 合并架构: helper 的父 bundle 即输入法本体
    }

    func installAndEnable() {
        var l = "———— 安装并启用 ————\n"
        if IMEInstaller.isSystemInstalled {
            l += "本机为系统级安装(/Library/Input Methods,由 .pkg 安装器管理)——GUI 只管用户级安装,更新请安装新 .pkg\n"
            installLog = l + installLog
            refreshStatus()
            return
        }
        if runningFromInstalledLocation {
            l += "本设置中心已运行于安装位置,跳过换盘,直接收敛启用状态\n"
            l += IMEInstaller.enable().log
            installLog = l + installLog
            refreshStatus()
            return
        }
        guard FileManager.default.fileExists(atPath: embeddedIMEURL.path) else {
            installLog = l + "✗ 找不到引擎 bundle(打包不完整)\n" + installLog
            return
        }
        l += IMEInstaller.install(embeddedIMEURL: embeddedIMEURL)
        l += IMEInstaller.enable().log
        l += "若首次安装:点「一键注销」并重新登录,登录扫描收录后永久有效\n"
        installLog = l + installLog
        refreshStatus()
    }

    /// 更新: 从本包 rm+cp 换盘 → killall → 确认死透 → open(部署铁律);
    /// 运行于安装位置时没有新包可换,提示走重新打包部署
    func redeploy() {
        var l = "———— 更新输入法 ————\n"
        if IMEInstaller.isSystemInstalled {
            installLog = l + "本机为系统级安装(/Library/Input Methods,由 .pkg 安装器管理)——GUI 换盘只管用户级,更新请安装新 .pkg\n" + installLog
            return
        }
        let dest = IMEInstaller.installedIMEURL()
        if runningFromInstalledLocation {
            installLog = l + "本设置中心运行于安装位置,没有新包可换——重新 scripts/package.sh 后替换 bundle 即可\n" + installLog
            return
        }
        guard FileManager.default.fileExists(atPath: embeddedIMEURL.path) else {
            installLog = l + "✗ 找不到引擎 bundle\n" + installLog
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

// MARK: - 根视图(系统液态玻璃 chrome: NavigationSplitView 侧栏自动玻璃,内容从其下滚过)

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(AppModel.Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon).tag(tab)
                }
                Section {
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(176)
        } detail: {
            Group {
                switch model.tab {
                case .install: InstallView(model: model)
                case .dict: DictView(model: model)
                case .user: UserWordsView(model: model)
                case .translate: TranslateView(model: model)
                case .model: ModelView(model: model)
                case .test: TestView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationTitle(model.tab.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minWidth: 600, minHeight: 440)
        }
    }

    private var sidebarSelection: Binding<AppModel.Tab?> {
        Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.redeploy() } label: { Label("更新输入法", systemImage: "arrow.triangle.2.circlepath") }
            }
            ToolbarItem {
                Button { model.openInputSourceSettings() } label: { Label("输入源设置", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

// MARK: - 词库

struct DictView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.dictSearch.isEmpty {
                    Button("‹ 上一页") { if model.dictPage > 0 { model.dictPage -= 1 } }
                        .disabled(model.dictPage == 0)
                    Text("第 \(model.dictPage + 1) / \(model.dictPageCount) 页").font(.caption).foregroundStyle(.secondary)
                    Button("下一页 ›") { if model.dictPage < model.dictPageCount - 1 { model.dictPage += 1 } }
                        .disabled(model.dictPage >= model.dictPageCount - 1)
                } else {
                    Text("搜索到 \(model.dictRows.count) 条(显示前 80)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.dictStats).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.top, 8)

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
        .searchable(text: $model.dictSearch, placement: .toolbar, prompt: "拼音前缀,如 nihao / nh / meibeng")
    }
}

// MARK: - 用户词

struct UserWordsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("共 \(model.userRows.count) 条 · 用户词处于最高优先档(用户 2 > 全键 1 > 渐进 0),打分 = 2万 + 1.5万·log10(1+次数),词频乘数 = min(1 + 0.5·log10(1+次数), ×3) 仅 ≥2 字词")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 8)

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
            if !model.userMessage.isEmpty {
                Text(model.userMessage)
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.importUsers() } label: { Label("导入用户词…", systemImage: "square.and.arrow.down") }
            }
            ToolbarItem {
                Button { model.confirmClear = true } label: { Label("清空全部", systemImage: "trash") }
                    .disabled(model.userRows.isEmpty)
            }
            ToolbarItem {
                Button { model.reloadUserRows() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .confirmationDialog("清空全部用户词与词频?", isPresented: $model.confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearUsers() }
        }
    }
}

// MARK: - 翻译(端侧 FM,中↔英方向自动)

struct TranslateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(title: "翻译 · \(model.translateDirection)") {
                    TextEditor(text: $model.translateInput)
                        .font(.system(size: 14))
                        .frame(height: 110)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
                        .overlay(alignment: .bottomTrailing) {
                            if !model.translateInput.isEmpty {
                                Button {
                                    model.translateInput = ""
                                    model.translateResult = ""
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                                    .padding(6)
                            }
                        }
                    HStack(spacing: 10) {
                        Button(model.translating ? "翻译中…" : "翻译 ⏎") { model.submitTranslate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.translating || model.translateInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if model.translating { ProgressView().controlSize(.small) }
                        Spacer()
                        if !model.translateResult.isEmpty {
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(model.translateResult, forType: .string)
                            } label: { Label("复制", systemImage: "doc.on.doc") }
                        }
                    }
                    if !model.translateResult.isEmpty {
                        Text(model.translateResult)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
                    }
                    Text("端侧 Apple 模型,隐私安全(不上云);方向自动识别;输入后按 ⏎ 翻译")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .onSubmit { model.submitTranslate() }
    }
}

// MARK: - 模型(kb36:云端模型 Provider 接入 + FM 提示词编辑)

struct ModelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(title: "云端模型(启用后替代端侧 FM,失败自动回落)") {
                    Toggle("启用云端模型", isOn: $model.cloudEnabled)
                    Picker("提供商", selection: $model.cloudProvider) {
                        ForEach(AppModel.cloudPresets, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    Picker("接口格式", selection: $model.cloudFormat) {
                        Text("OpenAI 兼容(/chat/completions)").tag("openai")
                        Text("Anthropic(/v1/messages)").tag("anthropic")
                    }
                    TextField("接口地址 Base URL(如 https://api.deepseek.com/v1)", text: $model.cloudBaseURL)
                    SecureField("API Key", text: $model.cloudAPIKey)
                    TextField("模型名(如 deepseek-chat)", text: $model.cloudModel)
                    HStack(spacing: 10) {
                        Button(model.cloudTesting ? "测试中…" : "测试连接") { model.testCloud() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.cloudTesting || model.cloudBaseURL.isEmpty || model.cloudModel.isEmpty)
                        if model.cloudTesting { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if !model.cloudTestResult.isEmpty {
                        Text(model.cloudTestResult)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    Text("请求结构沿用 fm 框架:提示词=系统消息(instructions),请求体=用户消息(prompt),由 FoundationModels Provider 协议的 Executor 转换。密钥明文存本机 IME 域;远程地址仅支持 https(本机 http 如 Ollama 可用);启用后组词上文与拼音会发送到所选服务商,注重隐私请勿启用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GlassCard(title: "提示词(内置默认已预填;编辑后点「应用」生效,云端启用时同样生效)") {
                    promptEditor("候选重排(只输出序号数字)", $model.promptRerank)
                    promptEditor("整句预测(只输出中文)", $model.promptSentence)
                    promptEditor("翻译 · 中文→英(只输出译文)", $model.promptTranslateEN)
                    promptEditor("翻译 · 外文→中(只输出译文)", $model.promptTranslateZH)
                    HStack(spacing: 10) {
                        Button("应用") { model.applyPrompts() }
                            .buttonStyle(.borderedProminent)
                        Button("全部恢复默认") { model.resetPrompts() }
                        Spacer()
                        if !model.promptAppliedHint.isEmpty {
                            Text(model.promptAppliedHint).font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text("提示词改的是 instructions 段,请保留「只输出…」的格式约束,否则输出无法解析会自动回退词典;与内置默认一致的段落不落盘(跟随内置更新)。请求体(上文/拼音/候选的拼装)由代码固定;引擎与设置中心的翻译页共用这里的配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private func promptEditor(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12))
                .frame(height: 64)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
        }
    }
}

// MARK: - 测试(实验性交互效果开关)

struct TestView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GlassCard(title: "水滴拖拽") {
                    Toggle("固定透镜拖拽(水滴不动,候选条滑过)", isOn: $model.dropletFixedLens)
                    Text("开:按住水滴后它钉在原地(屏幕固定透镜),整条候选栏(玻璃+文字刚体)随手指平移、从水滴下面滑过,松手上屏水滴正下方的候选。\n关(默认):水滴在候选条内随手指滑动,候选栏不动。\n改动即时生效,下一次按住拖拽即按新模式;此页为实验特性试用区。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
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
                GlassCard(title: "快捷键") {
                    ForEach(model.hotkeyRows) { row in
                        HStack(spacing: 10) {
                            Text(row.title).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.display)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(.primary.opacity(0.08)))
                            if row.custom {
                                Text("已自定义").font(.caption2).foregroundStyle(.secondary)
                            }
                            if model.recordingHotkey == row.id {
                                Button("取消") { model.stopRecording() }
                            } else {
                                Button("修改") { model.startRecording(row.id) }
                            }
                        }
                    }
                    if !model.hotkeyHint.isEmpty {
                        Text(model.hotkeyHint).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("全部恢复默认") { model.resetHotkeys() }
                        Spacer()
                    }
                    Text("修饰键固定为 ⌃,主键支持字母/数字/符号;输入法现读现判,改动即时生效。终端里对应组合键会被输入法接管(⌃S 为 XOFF 流控等,已知取舍)。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GlassCard(title: "说明") {
                    Text("中英模式:轻点 Shift 随时切换(全部应用生效,跨重启记忆),故不在此重复提供开关。组词中按住 Shift 敲字母可输入大写英文(如 GDP),随候选一并上屏。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .onDisappear { model.stopRecording() } // 离开设置页:取消录制监控,防止残留吞键
    }
}

// MARK: - 入口(WindowGroup 场景:窗口 chrome 交给系统——玻璃侧栏/工具栏/搜索自动生效)

@main
struct AFMControlCenter: App {
    var body: some Scene {
        WindowGroup("AFM拼音") {
            RootView(model: AppModel.shared)
                .onAppear {
                    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let img = NSImage(contentsOf: url) {
                        NSApp.applicationIconImage = img
                    }
                    NSLog("[AFMApp] 启动 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") 词库=\(AppModel.shared.store != nil ? "已加载" : "未找到")")
                }
        }
        .defaultSize(width: 820, height: 560)
    }
}
