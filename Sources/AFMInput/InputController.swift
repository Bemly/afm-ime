import AppKit
import InputMethodKit
import IMECore

@objc(InputController)
final class InputController: IMKInputController {
    // MARK: - 引擎(进程内单例)

    static let engine: CandidateEngine? = {
        let path = Bundle.main.path(forResource: "dict", ofType: "bin") ?? "Data/dict.bin"
        DebugLog.log("词库加载开始: \(path)")
        guard let store = try? DictStore(url: URL(fileURLWithPath: path)) else {
            DebugLog.error("词库加载失败: \(path)")
            return nil
        }
        DebugLog.log("词库已加载: 记录 \(store.recordCount), 音节 \(store.syllables.count)")
        return CandidateEngine(store: store)
    }()

    static let perPage = 8

    // MARK: - 中英模式(系统级 ShiftTap 轻点切换,UserDefaults 跨重启记忆)

    static var englishMode: Bool {
        get { UserDefaults.standard.bool(forKey: "AFMEnglishMode") }
        set { UserDefaults.standard.set(newValue, forKey: "AFMEnglishMode") }
    }

    // MARK: - 快捷键(设置中心 kb35 起可改:defaults 存 keyCode,IME 每次按键现读现判)

    /// object 判 nil 区分「未设置」与合法键码 0(=字母 A);仅 ⌃+主键,修饰固定
    private static func hotkey(_ name: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: name) as? Int ?? fallback
    }
    /// 缺省: 剪贴板 ⌃V(9) / 内联翻译 ⌃F(3) / 设置中心 ⌃S(1);键名与设置中心 AFMApp 逐字一致
    static var hotkeyClipboard: Int { hotkey("AFMHotkeyClipboard", 9) }
    static var hotkeyTranslate: Int { hotkey("AFMHotkeyTranslate", 3) }
    static var hotkeySettings: Int { hotkey("AFMHotkeySettings", 1) }

    static let liveControllers = NSHashTable<InputController>.weakObjects()

    // MARK: - 伴随面板(⌃V 剪贴板 / ⌃F 翻译)共享状态

    /// 伴随面板定位用: 最近一次光标矩形与候选窗 frame(onFrameChange 回写)
    static var latestCaret: NSRect = .null
    static var latestCandidateFrame: NSRect = .null
    /// 最近活跃的 controller(剪贴板/翻译"插入到光标"的目标客户)
    static weak var lastActive: InputController?

    /// ShiftModeMonitor(主线程)调用:组词中的实例先上屏拼音原文(↩ 行为,非空格选词),再切模式
    static func shiftTappedToggle() {
        for c in liveControllers.allObjects {
            if !c.raw.isEmpty {
                DebugLog.log("Shift 切换 → 先上屏拼音原文 '\(c.raw)'")
                c.flush(c.raw, client: c.client())
            }
            c.quoteOpenSingle = false
            c.quoteOpenDouble = false
        }
        englishMode.toggle()
        DebugLog.log("Shift 切换 → \(englishMode ? "英文(直通)" : "中文")模式")
    }

    // MARK: - 组词状态

    private var raw = ""                                  // 拼音缓冲
    private var candidates: [CandidateEngine.Candidate] = []
    private var selectedIndex = 0                         // 全局选中下标
    private var aiBoostText: String?                      // FM 提到首位的词
    private var fmGeneration = 0                          // FM 请求代际(防陈旧结果回写)
    private var shiftDown = false                         // shift 按住中(flagsChanged)
    private var shiftUsed = false                         // 按住期间按过其他键 → 松开不算轻点
    private var quoteOpenSingle = false                   // '' 成对交替
    private var quoteOpenDouble = false                   // "" 成对交替

    // 候选展示: 条恒显前 8 个(无滑动窗口)/ ↓ 展开 8 列滚动网格(ScrollView 滚轮) / ⌃F 内联翻译
    static let maxCandidates = 100        // 单次查询候选上限(网格滚动需要长列表)
    static let gridColumns = 8            // 展开网格固定列数(候选 1-8 = 首行,移回即收起)
    static let gridVisibleRows = 4        // 展开网格可见行数(滚动区高度)

    private var gridExpanded = false      // ↓ 展开的网格态
    private var translationMode = false   // ⌃F 内联翻译态
    private var translatedText: String?
    private var translating = false
    private var translateGen = 0          // 翻译请求代际(防陈旧结果回写)

    /// 分段转换撤销栈: 渐进前缀词"转换"后整句仍为预编辑态,退格可回退该段
    private struct UndoEntry {
        let segmentText: String     // 该段转换出的词
        let previousRaw: String     // 该段转换前的完整拼音
        let remainderRaw: String    // 转换后剩余的拼音
    }
    private var undoStack: [UndoEntry] = []
    /// 已转换段(尚未真正上屏,整句保持预编辑下划线态,最终上屏时一并写入)
    private var committedBuffer = ""
    /// 已转换段的 (词, 拼音键) 轨迹: 最终上屏时整词组记入用户词库(真的+抽象 → 词组「真的抽象」)
    private var committedKeys: [(word: String, pinyin: String)] = []
    /// 翻译面板等需抢键盘的面板打开期间组词挂起(状态保留,面板关闭后原样恢复,不上屏不丢弃)
    var compositionSuspended = false

    private let candidateWindow = CandidateWindowController()
    /// 候选条水滴模型(单例:面板/覆盖层/控制器多视图引用同一份几何与折射输出)
    static let dropletModel = CandidateDropletModel.shared
    private var dropletModel: CandidateDropletModel { Self.dropletModel }

    // MARK: - 英文字尾冻结(kb35: 组词中 shift+字母 → 大写;首个大写字母起整段为字面英文,不参与拼音)
    // 例: "niHao" = 拼音段 "ni" + 字尾 "Hao" → 候选按 "ni" 查,空格上屏 "你Hao";纯 "GDP" 无候选,空格直接上屏原文

    /// 拼音段: 首个大写字母之前的部分(全小写),供词典查询/FM/用户词学习
    private var pinyinPart: String {
        guard let i = raw.firstIndex(where: { $0.isUppercase }) else { return raw }
        return String(raw[..<i])
    }
    /// 字面英文字尾: 首个大写字母起(含)的整段,提交时原样拼在候选/译文后
    private var literalTail: String {
        guard let i = raw.firstIndex(where: { $0.isUppercase }) else { return "" }
        return String(raw[i...])
    }
    /// 组词中"先上屏首选"场合(标点/失焦/面板插入)的统一文本: 首选+字尾;无候选时上屏 raw 原文
    private var firstChoiceText: String {
        if let first = candidates.first { return first.text + literalTail }
        return raw
    }

    override init(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
        Self.liveControllers.add(self)
        Self.lastActive = self
        candidateWindow.onFrameChange = { frame in
            Self.latestCandidateFrame = frame ?? .null
            CompanionPanels.repositionAll()
        }
        dropletModel.onDrop = { [weak self] fraction in // 水滴松手:吸附最近候选上屏
            guard let self, !self.candidates.isEmpty else { return }
            self.dropletModel.reset()
            let idx = max(0, min(self.candidates.count - 1, Int(fraction.rounded())))
            DebugLog.log("水滴松手 → 上屏 idx=\(idx) (fraction=\(String(format: "%.2f", fraction)))")
            self.commitCandidate(at: idx, client: self.client())
        }
        dropletModel.onPanelShift = { originX in // 固定透镜拖拽:整条 bar(面板)刚体平移
            Self.lastActive?.candidateWindow.shiftPanel(toOriginX: originX)
        }
        DebugLog.log("InputController 初始化 client=\(client != nil)")
    }

    override func activateServer(_ sender: Any!) {
        DebugLog.log("activateServer")
        Self.lastActive = self
        ShiftModeMonitor.retryIfNeeded() // 权限补授后无需重启,焦点切换时重试创建监听
        restoreSuspendedComposition(sender) // 翻译面板关闭还焦点后,原样恢复挂起中的组词
    }

    /// IMK 默认只投递 keyDown;要收修饰键事件(flagsChanged)必须显式声明,否则轻点 Shift 永远收不到
    /// (参考 fcitx5-macos controller.swift 同款覆写)
    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(events.rawValue)
    }
    override func deactivateServer(_ sender: Any!) {
        if compositionSuspended {
            // 翻译面板抢焦点所致:组词挂起中,不提交不上屏(状态留在内存,activateServer 恢复)
            DebugLog.log("deactivateServer(组词挂起中,不提交) raw='\(raw)'")
            return
        }
        DebugLog.log("deactivateServer → commitComposition")
        commitComposition(sender)
    }
    override func hidePalettes() {
        DebugLog.log("hidePalettes")
        candidateWindow.hide()
    }

    // MARK: - 输入法菜单(菜单栏输入菜单里的「设置…」入口)

    /// IMK 输入法子菜单:AFM拼音 激活时点菜单栏拼字图标可见
    override func menu() -> NSMenu! {
        let m = NSMenu(title: "AFM拼音")
        m.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ""))
        return m
    }

    /// 打开设置中心(嵌在引擎 bundle PlugIns/AFMSettings.app 的独立进程——引擎 LSUIElement 不能弹窗)。
    /// IMK 菜单点击经 doCommandBySelector 路由到本方法(默认实现检查 controller 是否响应选择器)
    @objc func openSettings(_ sender: Any?) {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/AFMSettings.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            DebugLog.error("设置中心 helper 缺失: \(url.path)")
            return
        }
        DebugLog.log("输入法菜单 → 打开设置中心")
        NSWorkspace.shared.open(url)
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client: Any!) -> Bool {
        guard Self.engine != nil else {
            DebugLog.error("handle 被调用但引擎未加载,全部放行")
            return false
        }
        guard let event else {
            DebugLog.log("忽略 nil 事件")
            return false
        }
        DebugLog.log("handle type=\(event.type.rawValue) keyCode=\(event.keyCode) chars='\(event.characters ?? "?")' mods=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)")

        // 修饰键事件仅在 AppKit 应用可达(Electron/Chromium 系不转发,recognizedEvents 声明也无效);
        // Shift 中英切换由 ShiftModeMonitor(系统级 CGEventTap)处理,此处仅留诊断日志
        if event.type == .flagsChanged {
            DebugLog.log("flagsChanged(IMK) keyCode=\(event.keyCode) mods=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)")
            return false
        }
        guard event.type == .keyDown else {
            DebugLog.log("忽略非按键事件 type=\(event.type)")
            return false
        }
        // 自己的面板持键(翻译框输入中)→ 全放行:按键必须到达输入框,也不能劫持 lastActive
        // (实测: 面板激活后自有 app 的事件仍回流 handle,此前字母被拼音引擎吞掉 → 翻译框无法输入)
        if CompanionPanels.anyKeyWindow {
            return false
        }
        Self.lastActive = self

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 方向键 keyDown 自带 function|numericPad 修饰位(0xA00000),须剔除后再判定,
        // 否则 ←/→/↑/↓ 全被当成"带修饰键"放行给应用(光标移动而非切换候选)
        let meaningful = mods.intersection([.shift, .control, .option, .command, .capsLock])
        // ⌃;(keyCode 39): 打开系统「显示表情与符号」字符检阅器
        if event.keyCode == 39, mods.contains(.control),
           !mods.contains(.option), !mods.contains(.command) {
            DebugLog.log("快捷键 ⌃; → 打开表情与符号")
            NSApp.orderFrontCharacterPalette(nil)
            return true
        }
        // ⌃V 剪贴板面板(免激活,组词不打断;中英模式都拦;键码设置中心可改)
        if event.keyCode == Self.hotkeyClipboard, mods.contains(.control),
           !mods.contains(.option), !mods.contains(.command), !mods.contains(.shift) {
            Self.latestCaret = Self.caretRect(client)
            DebugLog.log("⌃V → 剪贴板面板")
            CompanionPanels.toggleClipboard()
            return true
        }
        // ⌃F 内联翻译: 组词中把当前高亮候选的译文直接显示在候选框(独立翻译框组件暂不启用);
        // 非组词时放行给应用(终端 forward-char 等原生行为);键码设置中心可改
        if event.keyCode == Self.hotkeyTranslate, mods.contains(.control),
           !mods.contains(.option), !mods.contains(.command), !mods.contains(.shift), !raw.isEmpty {
            Self.latestCaret = Self.caretRect(client)
            DebugLog.log("⌃F → 内联翻译候选")
            if translationMode { exitTranslationMode(client) } else { enterTranslationMode(client) }
            return true
        }
        // ⌃S 打开设置中心(kb34:⌃F 保持内联翻译,设置迁到 ⌃S;中英模式都拦,终端 XOFF 取舍同 ⌃V/⌃F;键码可改)
        if event.keyCode == Self.hotkeySettings, mods.contains(.control),
           !mods.contains(.option), !mods.contains(.command), !mods.contains(.shift) {
            DebugLog.log("⌃S → 打开设置中心")
            openSettings(nil)
            return true
        }
        // 剪贴板面板键控(免激活模式客户端仍持焦点,键盘在此路由;组词中按键仍归组词,面板用点击)
        if CompanionPanels.clipboard.isVisible, raw.isEmpty,
           CompanionPanels.clipboard.routeKey(event) {
            return true
        }
        // Shift 组合键的"轻点"判定在 ShiftModeMonitor(系统级)完成
        if !meaningful.isSubset(of: [.shift, .capsLock]) {
            DebugLog.log("放行带修饰键 key chars=\(event.charactersIgnoringModifiers ?? "?") mods=\(mods.rawValue)")
            return false
        }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else {
            DebugLog.log("放行多字符事件 '\(event.charactersIgnoringModifiers ?? "?")'")
            return false
        }
        let key = Character(chars).lowercased().first ?? "_"
        // Shift 组合符还原(shiftedSymbols): 部分客户端 shift+1 的 chars='1',还原成 '!'
        let eff = (mods.contains(.shift) ? Self.shiftedSymbols[chars] : nil) ?? chars
        let effScalar = eff.unicodeScalars.first ?? scalar
        let composing = !raw.isEmpty
        DebugLog.log("key '\(chars)' eff='\(eff)' scalar=\(scalar.value) keyCode=\(event.keyCode) composing=\(composing) raw='\(raw)'")

        if Self.englishMode { // 英文模式:全部直通——无组词无候选框,标点半角由应用自然插入
            DebugLog.log("英文模式放行 '\(chars)'")
            return false
        }

        switch true {
        case ("a"..."z").contains(key): // 字母入缓冲;按住 Shift → 大写字母,进入英文字尾冻结段(kb35,ShiftTap 的 shiftUsed 机制保证不误触中英切换)
            if mods.contains(.shift) {
                DebugLog.log("shift+字母 → 大写 '\(key.uppercased())' 入英文字尾")
                raw.append(Character(key.uppercased()))
            } else {
                raw.append(key)
            }
            refresh(client)
            return true

        case eff == "'" where composing: // 组词中 ' 仅作打字辅助分隔符,不入缓冲(保证渐进前缀的字母偏移计算)
            return true

        case event.keyCode == 49 where translationMode: // 空格 → 上屏译文(+未提交的英文字尾)
            if !translating, let t = translatedText {
                DebugLog.log("空格 → 上屏译文 '\(t)'")
                flush(t + literalTail, client: client)
            }
            return true

        case event.keyCode == 49 where composing: // 空格键(keyCode 49)→ 上屏选中候选,不插入空格
            DebugLog.log("空格键 → 上屏选中 idx=\(selectedIndex)")
            commitCandidate(at: selectedIndex, client: client)
            return true

        case event.keyCode == 36 where composing: // 回车: 网格展开 → 上屏选中(同空格);未展开 → 上屏拼音原文
            if gridExpanded {
                DebugLog.log("回车(网格) → 上屏选中 idx=\(selectedIndex)")
                commitCandidate(at: selectedIndex, client: client)
            } else {
                DebugLog.log("回车 → 上屏原文 '\(raw)'")
                flush(raw, client: client)
            }
            return true

        case (49...57).contains(effScalar.value) where !candidates.isEmpty: // 数字选词: 条=全局 1-8;网格=水滴所在行内 1-8(shift+数字=符号,不选词)
            let d = Int(effScalar.value) - 49
            let idx = gridExpanded ? (selectedIndex / Self.gridColumns) * Self.gridColumns + d : d
            if d < (gridExpanded ? Self.gridColumns : Self.perPage), idx < candidates.count {
                DebugLog.log("数字 \(d + 1) → 上屏 idx=\(idx) 网格=\(gridExpanded)")
                commitCandidate(at: idx, client: client)
                return true
            }
            DebugLog.log("数字越界 idx=\(idx),放行")
            return false

        case event.keyCode == 51 where composing: // 退格键(keyCode 51)
            // 分段转换后: 回退最近一段(整句仍是预编辑态,纯内存操作,无需动应用文本)
            if let top = undoStack.last, raw == top.remainderRaw {
                committedBuffer = String(committedBuffer.dropLast(top.segmentText.count))
                committedKeys.removeLast() // 与撤销栈平行回退
                undoStack.removeLast()
                raw = top.previousRaw
                aiBoostText = nil
                fmGeneration &+= 1
                DebugLog.log("退格 → 撤销分段 '\(top.segmentText)',恢复 '\(raw)'")
                refresh(client)
                return true
            }
            // 常规: 删最后一个字母,组词延续(手动删字母后撤销栈作废)
            raw.removeLast()
            aiBoostText = nil
            undoStack.removeAll()
            committedKeys.removeAll()
            DebugLog.log("退格 → raw='\(raw)'")
            refresh(client)
            return true

        case event.keyCode == 53 where composing: // Esc 键(keyCode 53)→ 退翻译态 / 取消组词
            if translationMode {
                DebugLog.log("Esc → 退出翻译态")
                exitTranslationMode(client)
                return true
            }
            DebugLog.log("Esc → 取消组词")
            clearComposition(client)
            return true

        case event.keyCode == 125 where composing: // ↓ → 展开 8 列滚动网格 / 网格内下移一行
            if translationMode { exitTranslationMode(client) }
            if gridExpanded { moveInGrid(Self.gridColumns) } else { expandGrid() }
            DebugLog.log("↓ 展开网格=\(gridExpanded) 选中=\(selectedIndex)")
            updateCandidateWindow(client)
            return true

        case event.keyCode == 126 where composing: // ↑ → 网格上移一行(顶行收起) / 条内上移
            if translationMode { exitTranslationMode(client) }
            if gridExpanded { moveInGrid(-Self.gridColumns) } else { moveSelectionBar(-1) }
            DebugLog.log("↑ 展开网格=\(gridExpanded) 选中=\(selectedIndex)")
            updateCandidateWindow(client)
            return true

        case event.keyCode == 124 where composing: // → → 下一个(条内越过第 8 个直接展开网格)
            if translationMode { exitTranslationMode(client) }
            gridExpanded ? moveInGrid(1) : moveSelectionBar(1)
            DebugLog.log("→ 展开网格=\(gridExpanded) 选中=\(selectedIndex)")
            updateCandidateWindow(client)
            return true

        case event.keyCode == 123 where composing: // ← → 上一个
            if translationMode { exitTranslationMode(client) }
            gridExpanded ? moveInGrid(-1) : moveSelectionBar(-1)
            DebugLog.log("← 展开网格=\(gridExpanded) 选中=\(selectedIndex)")
            updateCandidateWindow(client)
            return true

        case (eff == "=" || eff == "-") where composing: // =/- 翻页(条内 ±8 越界自动展/收网格,网格内 ±一行)
            if translationMode { exitTranslationMode(client) }
            let step = eff == "=" ? 1 : -1
            gridExpanded ? moveInGrid(step * Self.gridColumns) : moveSelectionBar(step * Self.perPage)
            DebugLog.log("翻页\(eff == "=" ? "+" : "-") → 选中=\(selectedIndex) 网格=\(gridExpanded)")
            updateCandidateWindow(client)
            return true

        default:
            return handlePunctuation(eff, composing: composing, client: client)
        }
    }

    // MARK: - 中文全角标点(英文模式不会走到这里)

    static let fullWidthPunct: [String: String] = [
        ",": "，", ".": "。", ";": "；", ":": "：",
        "?": "？", "!": "！", "(": "（", ")": "）",
        "[": "【", "]": "】", "{": "「", "}": "」", "<": "《", ">": "》",
        "\\": "、", "`": "·", "~": "～", "$": "￥", "_": "——", "^": "……",
    ]

    /// 部分客户端 shift+标点的 charactersIgnoringModifiers 不含 shift 效果(返回基础字符),
    /// 按住 Shift 时手动还原成上档符号;已应用 shift 的客户端查不到表、原样放行,两种行为都正确
    static let shiftedSymbols: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
        "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    /// 标点处理:命中映射 → (组词中先上屏首选)插入全角,引号成对交替;未映射(-=/ 空格 数字 / 等)按旧逻辑放行
    private func handlePunctuation(_ chars: String, composing: Bool, client: Any!) -> Bool {
        // 全角标点关(设置):映射标点半角原样直通;组词中仍先上屏首选
        guard UserPrefs.fullWidthPunct else {
            if composing {
                DebugLog.log("全角标点关 → 先上屏首选,原样放行 '\(chars)'")
                flush(firstChoiceText, client: client)
            } else {
                DebugLog.log("全角标点关 → 放行 '\(chars)'")
            }
            return false
        }
        let mapped: String?
        switch chars {
        case "'": quoteOpenSingle.toggle(); mapped = quoteOpenSingle ? "‘" : "’"
        case "\"": quoteOpenDouble.toggle(); mapped = quoteOpenDouble ? "“" : "”"
        default: mapped = Self.fullWidthPunct[chars]
        }
        guard let fw = mapped else {
            if composing { // 未映射标点: 先上屏首选,原标点放行
                DebugLog.log("标点 '\(chars)' → 先上屏首选再放行")
                flush(firstChoiceText, client: client)
            } else {
                DebugLog.log("无组词,放行 '\(chars)'")
            }
            return false
        }
        if composing {
            DebugLog.log("标点 '\(chars)' → 上屏首选 + 全角 '\(fw)'")
            flush(candidates.first?.text ?? raw, client: client)
        } else {
            DebugLog.log("标点 '\(chars)' → 全角 '\(fw)'")
        }
        guard let textInput = client as? IMKTextInput else { return false }
        textInput.insertText(NSAttributedString(string: fw),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        return true
    }

    // MARK: - 组词状态

    override func composedString(_ sender: Any!) -> Any! {
        NSAttributedString(string: committedBuffer + raw)
    }

    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: committedBuffer + raw)
    }

    override func commitComposition(_ sender: Any!) {
        DebugLog.log("commitComposition raw='\(raw)' 首选=\(candidates.first?.text ?? "无")")
        guard !raw.isEmpty else { return }
        flush(firstChoiceText, client: sender)
    }

    // MARK: - 内部

    // MARK: - 选中移动
    // 条恒显前 8 个(无滑动窗口);←→ 在 0-7 内移动,→ 越过第 8 个直接展开网格;
    // 网格用 ScrollView 滚动(滚轮/滚动条,选中行越界自动滚入),移回首行(0-7)自动收起回条

    /// 条内 ←→/翻页
    private func moveSelectionBar(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        let idx = selectedIndex + delta
        if delta > 0, idx >= Self.perPage, candidates.count > Self.perPage {
            expandGrid() // 越过条内第 8 个 → 直接展开网格继续
            selectedIndex = min(idx, candidates.count - 1)
        } else {
            selectedIndex = max(0, min(idx, min(Self.perPage, candidates.count) - 1))
        }
    }

    /// 网格内 ±1/±列数;顶行按 ↑ 收起,移回首行(0-7)自动收起
    private func moveInGrid(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        var idx = selectedIndex + delta
        if idx < 0 {
            if delta == -Self.gridColumns { collapseGrid(); return }
            idx = 0
        }
        selectedIndex = min(idx, candidates.count - 1)
        if selectedIndex < Self.gridColumns { collapseGrid() }
    }

    private func expandGrid() {
        gridExpanded = true
    }

    private func collapseGrid() {
        gridExpanded = false
    }

    private func refresh(_ client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            DebugLog.error("refresh: client 不符合 IMKTextInput")
            return
        }
        let py = pinyinPart // 字尾冻结段不进切分器(大写字母不是合法音节,整串查询会拖累渐进兜底)
        candidates = py.isEmpty ? [] : (Self.engine?.candidates(for: py, limit: Self.maxCandidates) ?? [])
        selectedIndex = 0
        dropletModel.reset() // 组词刷新,水滴归位
        exitTranslationState() // 组词已变化,翻译态作废(窗口由本次 refresh 统一刷新)
        DebugLog.log("refresh '\(raw)' 拼音段='\(py)' → 候选 \(candidates.count) 条: "
            + candidates.prefix(5).map { "\($0.text)(\(Int($0.score)))" }.joined(separator: " "))

        let full = committedBuffer + raw // 已转换段 + 剩余拼音,整句保持预编辑下划线态
        let marked = NSMutableAttributedString(string: full)
        if !full.isEmpty {
            marked.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: 0, length: full.utf16.count))
        }
        textInput.setMarkedText(marked,
                                selectionRange: NSRange(location: marked.length, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        if candidates.isEmpty {
            if pinyinPart.count >= 4, UserPrefs.fmEnhance {
                // 无词典候选但 FM 可能出整句:光标处占位等待,不取消推理
                DebugLog.log("无词典候选(拼音段长 \(pinyinPart.count))→ 占位等待 FM 整句")
                updateCandidateWindow(client, loading: true)
                scheduleFMRerank(client)
            } else {
                if !UserPrefs.fmEnhance {
                    DebugLog.log("无候选且 FM 增强关 → 隐藏候选窗")
                } else {
                    DebugLog.log("无候选且过短 → 隐藏候选窗")
                }
                candidateWindow.hide()
            }
        } else {
            updateCandidateWindow(client)
            scheduleFMRerank(client)
        }
    }

    /// 翻译面板要抢键盘(临时激活本进程),组词中打开前调用:状态留在内存不上屏,
    /// deactivateServer 据此跳过提交,activateServer(面板关闭还焦点后)原样恢复
    static func suspendCompositionForPanel() {
        for c in liveControllers.allObjects where !c.raw.isEmpty {
            c.compositionSuspended = true
            c.fmGeneration &+= 1 // 掐掉在途 FM,防止面板期间结果回写重开候选窗
            c.candidateWindow.hide()
            DebugLog.log("组词挂起(面板抢键盘) raw='\(c.raw)'")
        }
    }

    private func restoreSuspendedComposition(_ client: Any!) {
        guard compositionSuspended else { return }
        compositionSuspended = false
        guard !raw.isEmpty else { return }
        DebugLog.log("组词恢复 raw='\(raw)'")
        if let textInput = client as? IMKTextInput {
            let full = committedBuffer + raw
            let marked = NSMutableAttributedString(string: full)
            marked.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: 0, length: full.utf16.count))
            textInput.setMarkedText(marked,
                                    selectionRange: NSRange(location: marked.length, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        updateCandidateWindow(client)
    }

    /// 伴随面板(剪贴板条目/翻译结果)"插入到光标": 组词中先按空格语义上屏首选,再写入客户光标处
    /// (客户端持焦点时立即插入;翻译面板持键则先关面板还焦点,延迟到目标客户重新活跃再插入)
    static func insertFromPanel(_ text: String) {
        if let tp = CompanionPanels.translate.panel, tp.isVisible, NSApp.keyWindow === tp {
            DebugLog.log("插入前先关翻译面板还焦点")
            CompanionPanels.translate.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.doInsert(text) }
            return
        }
        doInsert(text)
    }

    private static func doInsert(_ text: String) {
        guard let c = lastActive, let client = c.client() else {
            DebugLog.error("insertFromPanel: 无活跃 client")
            return
        }
        if !c.raw.isEmpty {
            DebugLog.log("面板插入前先上屏首选 '\(c.firstChoiceText)'")
            c.flush(c.firstChoiceText, client: client)
        }
        guard let textInput = client as? IMKTextInput else {
            DebugLog.error("insertFromPanel: client 不符合 IMKTextInput")
            return
        }
        DebugLog.log("面板插入 长度=\(text.count)")
        textInput.insertText(NSAttributedString(string: text),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func candidateItems() -> [CandidateItem] {
        candidates.enumerated().map {
            CandidateItem(index: $0.offset, text: $0.element.text, isAI: $0.element.text == aiBoostText)
        }
    }

    private func updateCandidateWindow(_ client: Any!, loading: Bool = false) {
        if candidates.isEmpty {
            guard loading else { candidateWindow.hide(); return }
            let caret = Self.caretRect(client)
            Self.latestCaret = caret
            DebugLog.log("候选窗占位(FM 整句中) caret=\(NSStringFromRect(caret))")
            candidateWindow.show(
                items: [], selectedIndex: 0,
                expanded: false, translation: nil, isLoading: true, droplet: dropletModel, caretRect: caret,
                onSelect: { _ in }, onToggleExpand: {})
            return
        }
        let caret = Self.caretRect(client)
        Self.latestCaret = caret
        let translation = translationMode ? TranslationDisplay(text: translatedText, translating: translating) : nil
        DebugLog.log("候选窗定位 caret=\(NSStringFromRect(caret)) 选中=\(selectedIndex) 网格=\(gridExpanded) 翻译=\(translation != nil)")
        candidateWindow.show(
            items: candidateItems(),
            selectedIndex: selectedIndex,
            expanded: gridExpanded,
            translation: translation,
            droplet: dropletModel,
            caretRect: caret,
            onSelect: { [weak self] idx in
                DispatchQueue.main.async {
                    DebugLog.log("点击候选 idx=\(idx)")
                    self?.commitCandidate(at: idx, client: self?.client())
                }
            },
            onToggleExpand: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.candidates.isEmpty else { return }
                    if self.gridExpanded { self.collapseGrid() } else { self.gridExpanded = true }
                    DebugLog.log("点击 ▾/▴ → 展开网格=\(self.gridExpanded)")
                    self.updateCandidateWindow(self.client())
                }
            })
    }

    // MARK: - ⌃F 内联翻译(译文显示在候选框,空格上屏;独立翻译框组件暂不启用)

    private func enterTranslationMode(_ client: Any!) {
        guard !candidates.isEmpty else { return }
        let source = candidates[min(selectedIndex, candidates.count - 1)].text
        translationMode = true
        translatedText = nil
        translating = true
        translateGen &+= 1
        let gen = translateGen
        DebugLog.log("内联翻译 '\(source)'")
        updateCandidateWindow(client)
        Task { [weak self] in
            let out = await FMReranker.shared.translate(source)
            guard let self else { return }
            await MainActor.run {
                guard self.translationMode, self.translateGen == gen else { return }
                self.translating = false
                self.translatedText = out ?? "翻译失败 — FM 不可用"
                DebugLog.log("内联翻译完成: '\(self.translatedText ?? "")'")
                self.updateCandidateWindow(self.client())
            }
        }
    }

    /// 组词变化的场合(打字/退格/刷新): 只复位状态,不刷窗口(调用方随后统一 refresh)
    private func exitTranslationState() {
        translationMode = false
        translatedText = nil
        translating = false
        translateGen &+= 1
    }

    private func exitTranslationMode(_ client: Any!) {
        exitTranslationState()
        updateCandidateWindow(client)
    }

    private func commitCandidate(at index: Int, client: Any!) {
        guard index < candidates.count else {
            // 无候选时空格/数字:按惯例上屏已输入的拼音原文
            if candidates.isEmpty, !raw.isEmpty {
                DebugLog.log("无候选 → 空格/数字上屏原文 '\(raw)'")
                flush(raw, client: client)
            } else {
                DebugLog.error("commitCandidate 越界 idx=\(index) 总数=\(candidates.count)")
            }
            return
        }
        let cand = candidates[index]
        // 英文字尾冻结: 候选只对应拼音段 → 词+字尾一次上屏,不走分段转换(字尾非拼音,分段无意义)
        if !literalTail.isEmpty {
            let tailPinyin = UserFreq.isValidPinyin(cand.pinyin) ? cand.pinyin : pinyinPart
            if !committedKeys.isEmpty { // 前序分段 + 本次词 + 字尾: 词组学习照常
                let phrase = committedBuffer + cand.text
                let phraseKey = committedKeys.map(\.pinyin).joined(separator: " ") + " " + tailPinyin
                if phrase != cand.text {
                    DebugLog.log("词组学习 '\(phrase)' = \(phraseKey)")
                    UserFreq.shared.record(phrase, pinyin: phraseKey)
                }
            }
            UserFreq.shared.record(cand.text, pinyin: tailPinyin)
            DebugLog.log("上屏 '\(cand.text)' + 英文字尾 '\(literalTail)'")
            flush(cand.text + literalTail, client: client)
            return
        }
        // 渐进前缀词(匹配键串是输入串的真前缀): 转换该段进缓冲,剩余拼音继续预测(整句保持预编辑态)
        let concat = cand.pinyin.replacingOccurrences(of: " ", with: "")
        // 用户词频/用户词库: 选用即计数+记拼音;FM 整句等无拼音的候选拼音段当键(下次原样输入可复现)
        let learnPinyin = UserFreq.isValidPinyin(cand.pinyin) ? cand.pinyin : pinyinPart
        if !concat.isEmpty, raw.hasPrefix(concat), concat.count < raw.count {
            let remainder = String(raw.dropFirst(concat.count))
            DebugLog.log("分段转换 '\(cand.text)' → 余 '\(remainder)'")
            UserFreq.shared.record(cand.text, pinyin: learnPinyin)
            committedBuffer += cand.text
            committedKeys.append((cand.text, learnPinyin)) // 词组轨迹(最终上屏整词组入学)
            undoStack.append(UndoEntry(segmentText: cand.text, previousRaw: raw, remainderRaw: remainder))
            raw = remainder
            aiBoostText = nil
            fmGeneration &+= 1
            refresh(client)
            return
        }
        // 词组学习: 分段组出的整词组以拼接拼音键记入用户词库(真的+抽象 → 真的抽象 = zhen de chou xiang,
        // 之后 zhendchoux 逐音节宽松匹配直达)
        if !committedKeys.isEmpty {
            let phrase = committedBuffer + cand.text
            let phraseKey = committedKeys.map(\.pinyin).joined(separator: " ") + " " + learnPinyin
            if phrase != cand.text {
                DebugLog.log("词组学习 '\(phrase)' = \(phraseKey)")
                UserFreq.shared.record(phrase, pinyin: phraseKey)
            }
        }
        UserFreq.shared.record(cand.text, pinyin: learnPinyin)
        flush(cand.text, client: client)
    }

    /// 最终上屏: 已转换段 + 本次文本一并写入,清空全部组词状态
    private func flush(_ text: String, client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            DebugLog.error("flush: client 不符合 IMKTextInput,仅清组词")
            clearComposition(client); return
        }
        let full = committedBuffer + text
        DebugLog.log("上屏 '\(full)'")
        textInput.insertText(NSAttributedString(string: full),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        clearComposition(client)
    }

    private func clearComposition(_ client: Any!) {
        raw = ""
        candidates = []
        aiBoostText = nil
        fmGeneration &+= 1
        undoStack.removeAll()
        committedBuffer = ""
        committedKeys.removeAll()
        compositionSuspended = false
        gridExpanded = false
        dropletModel.reset()
        exitTranslationState()
        if let textInput = client as? IMKTextInput {
            textInput.setMarkedText(NSMutableAttributedString(),
                                    selectionRange: NSRange(location: 0, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        candidateWindow.hide()
    }

    // MARK: - FM 异步重排(0.4s 防抖;结果到达时若组词已变则丢弃)

    private func scheduleFMRerank(_ client: Any!) {
        guard UserPrefs.fmEnhance else {
            DebugLog.log("FM 增强关 → 跳过重排/整句")
            return
        }
        fmGeneration &+= 1
        let gen = fmGeneration
        let snapshotRaw = raw              // 过期判定用(含英文字尾)
        let snapshotPinyin = pinyinPart    // 发给模型的拼音(不含字尾,模型只认音节串)
        let context = Self.contextBeforeCaret(client)
        let texts = candidates.prefix(Self.perPage).map(\.text)

        // 整句判定: 无候选,或输入较长(≥8 字母)——引擎组句是即时草稿,长输入始终触发 FM 纠正
        let needSentence = (texts.isEmpty && snapshotPinyin.count >= 4) || snapshotPinyin.count >= 8
        if texts.count <= 1 && !needSentence {
            DebugLog.log("FM 跳过: 候选不足")
            return
        }
        DebugLog.log("FM 排队 gen=\(gen) 模式=\(needSentence ? "整句" : "重排") 上文='\(context)' 拼音='\(snapshotPinyin)' 候选=\(texts)")

        Task { [weak self] in
            // 整句预测立即触发(词典覆盖不足正是需要整句的时机);候选重排保持 400ms 防抖
            try? await Task.sleep(nanoseconds: needSentence ? 50_000_000 : 400_000_000)
            guard let self else { return }
            let stillCurrent = await MainActor.run { self.raw == snapshotRaw && self.fmGeneration == gen }
            guard stillCurrent else {
                DebugLog.log("FM 结果丢弃 gen=\(gen)(组词已变化)")
                return
            }
            if needSentence {
                guard let sentence = await FMReranker.shared.predictSentence(context: context, pinyin: snapshotPinyin) else {
                    DebugLog.log("FM 整句无结果 gen=\(gen)")
                    await MainActor.run {
                        // 占位中的窗口:整句失败且仍无词典候选 → 收起占位
                        if self.raw == snapshotRaw, self.fmGeneration == gen, self.candidates.isEmpty {
                            DebugLog.log("FM 整句失败 → 收起占位")
                            self.candidateWindow.hide()
                        }
                    }
                    return
                }
                await MainActor.run {
                    guard self.raw == snapshotRaw, self.fmGeneration == gen else {
                        DebugLog.log("FM 整句过期丢弃 gen=\(gen)")
                        return
                    }
                    DebugLog.log("FM 整句生效 gen=\(gen): '\(sentence)' → 第2位 ✦")
                    self.applyAISentence(sentence)
                }
            } else {
                guard let best = await FMReranker.shared.rerank(context: context, pinyin: snapshotPinyin, candidates: texts) else {
                    DebugLog.log("FM 无结果 gen=\(gen)")
                    return
                }
                await MainActor.run {
                    guard self.raw == snapshotRaw, self.fmGeneration == gen,
                          best < texts.count else {
                        DebugLog.log("FM 结果过期丢弃 gen=\(gen)")
                        return
                    }
                    DebugLog.log("FM 生效 gen=\(gen): '\(texts[best])' → 第2位 ✦")
                    self.applyAIRerank(text: texts[best])
                }
            }
        }
    }

    /// 把 FM 选中的词移到第 2 位并标记 ✦——不占第 1:FM 到达瞬间若顶掉首选,
    /// 按惯性直接空格会把"突然换掉的词"打出去;放第 2 位让用户主动选
    private func applyAIRerank(text: String) {
        guard let idx = candidates.firstIndex(where: { $0.text == text }) else { return }
        if idx > 1 {
            let picked = candidates.remove(at: idx)
            candidates.insert(picked, at: min(1, candidates.count))
        }
        aiBoostText = text
        updateCandidateWindow(client())
    }

    /// FM 整句预测结果插到第 2 位(✦),不顶掉词典首选;理由同 applyAIRerank
    private func applyAISentence(_ sentence: String) {
        guard !candidates.contains(where: { $0.text == sentence }) else { return }
        let cand = CandidateEngine.Candidate(text: sentence, pinyin: "(AI 整句)", score: .greatestFiniteMagnitude)
        candidates.insert(cand, at: min(1, candidates.count)) // 无词典候选时即第 1 位
        aiBoostText = sentence
        updateCandidateWindow(client())
    }

    // MARK: - 光标与上文

    /// 光标屏幕坐标矩形(AppKit 底左原点)。
    /// 文档约定:index 相对 inline session,传 0 表示取当前选区信息;
    /// 结果专用于"把候选窗放到屏幕上",返回即屏幕坐标。
    static func caretRect(_ client: Any!) -> NSRect {
        guard let t = client as? IMKTextInput else { return NSRect.null }
        var rect = NSRect.null
        let attrs = t.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        DebugLog.log("caretRect: attrs=\(attrs?.count ?? -1) 项 rect=\(NSStringFromRect(rect))")
        if rect.isNull || rect.width <= 0 || rect.height <= 0 {
            DebugLog.log("caretRect: 客户端未提供有效矩形,候选窗将回退到底部居中")
            return NSRect.null
        }
        return rect
    }

    /// 组词起点之前的已上屏文本(供 FM 语境判断)
    static func contextBeforeCaret(_ client: Any!) -> String {
        guard let t = client as? IMKTextInput else { return "" }
        let sel = t.selectedRange()
        guard sel.location != NSNotFound, sel.location > 0 else { return "" }
        let start = max(0, sel.location - 60)
        guard let sub = t.attributedSubstring(
            from: NSRange(location: start, length: sel.location - start)) else { return "" }
        return String(sub.string.suffix(60))
    }
}
