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

    static let perPage = 9

    // MARK: - 中英模式(系统级 ShiftTap 轻点切换,UserDefaults 跨重启记忆)

    static var englishMode: Bool {
        get { UserDefaults.standard.bool(forKey: "AFMEnglishMode") }
        set { UserDefaults.standard.set(newValue, forKey: "AFMEnglishMode") }
    }

    static let liveControllers = NSHashTable<InputController>.weakObjects()

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
    private var page = 0
    private var aiBoostText: String?                      // FM 提到首位的词
    private var fmGeneration = 0                          // FM 请求代际(防陈旧结果回写)
    private var shiftDown = false                         // shift 按住中(flagsChanged)
    private var shiftUsed = false                         // 按住期间按过其他键 → 松开不算轻点
    private var quoteOpenSingle = false                   // '' 成对交替
    private var quoteOpenDouble = false                   // "" 成对交替

    /// 分段转换撤销栈: 渐进前缀词"转换"后整句仍为预编辑态,退格可回退该段
    private struct UndoEntry {
        let segmentText: String     // 该段转换出的词
        let previousRaw: String     // 该段转换前的完整拼音
        let remainderRaw: String    // 转换后剩余的拼音
    }
    private var undoStack: [UndoEntry] = []
    /// 已转换段(尚未真正上屏,整句保持预编辑下划线态,最终上屏时一并写入)
    private var committedBuffer = ""

    private let candidateWindow = CandidateWindowController()

    override init(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
        Self.liveControllers.add(self)
        DebugLog.log("InputController 初始化 client=\(client != nil)")
    }

    override func activateServer(_ sender: Any!) {
        DebugLog.log("activateServer")
        ShiftModeMonitor.retryIfNeeded() // 权限补授后无需重启,焦点切换时重试创建监听
    }

    /// IMK 默认只投递 keyDown;要收修饰键事件(flagsChanged)必须显式声明,否则轻点 Shift 永远收不到
    /// (参考 fcitx5-macos controller.swift 同款覆写)
    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(events.rawValue)
    }
    override func deactivateServer(_ sender: Any!) {
        DebugLog.log("deactivateServer → commitComposition")
        commitComposition(sender)
    }
    override func hidePalettes() {
        DebugLog.log("hidePalettes")
        candidateWindow.hide()
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
        case ("a"..."z").contains(key): // 字母入缓冲
            raw.append(key)
            refresh(client)
            return true

        case eff == "'" where composing: // 组词中 ' 仅作打字辅助分隔符,不入缓冲(保证渐进前缀的字母偏移计算)
            return true

        case event.keyCode == 49 where composing: // 空格键(keyCode 49)→ 上屏选中候选,不插入空格
            DebugLog.log("空格键 → 上屏选中 idx=\(selectedIndex)")
            commitCandidate(at: selectedIndex, client: client)
            return true

        case event.keyCode == 36 where composing: // 回车键(keyCode 36)→ 上屏拼音原文
            DebugLog.log("回车 → 上屏原文 '\(raw)'")
            flush(raw, client: client)
            return true

        case (49...57).contains(effScalar.value) where !candidates.isEmpty: // 字符 '1'-'9' 选当前页(shift+数字=符号,不选词)
            let idx = page * Self.perPage + Int(effScalar.value) - 49
            if idx < candidates.count {
                DebugLog.log("数字 \(Int(scalar.value) - 48) → 上屏 idx=\(idx)")
                commitCandidate(at: idx, client: client)
                return true
            }
            DebugLog.log("数字越界 idx=\(idx),放行")
            return false

        case event.keyCode == 51 where composing: // 退格键(keyCode 51)
            // 分段转换后: 回退最近一段(整句仍是预编辑态,纯内存操作,无需动应用文本)
            if let top = undoStack.last, raw == top.remainderRaw {
                committedBuffer = String(committedBuffer.dropLast(top.segmentText.count))
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
            DebugLog.log("退格 → raw='\(raw)'")
            refresh(client)
            return true

        case event.keyCode == 53 where composing: // Esc 键(keyCode 53)→ 取消组词
            DebugLog.log("Esc → 取消组词")
            clearComposition(client)
            return true

        case event.keyCode == 125 || event.keyCode == 124 where composing: // ↓/→ 键 → 高亮下一个
            moveSelection(+1)
            DebugLog.log("↓/→ 选中=\(selectedIndex) 页=\(page)")
            updateCandidateWindow(client)
            return true

        case event.keyCode == 126 || event.keyCode == 123 where composing: // ↑/← 键 → 高亮上一个
            moveSelection(-1)
            DebugLog.log("↑/← 选中=\(selectedIndex) 页=\(page)")
            updateCandidateWindow(client)
            return true

        case (eff == "=" || eff == "-") where composing: // =/- 翻页
            changePage(eff == "=" ? 1 : -1)
            DebugLog.log("翻页\(eff == "=" ? "+" : "-") → 页=\(page)")
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
        let mapped: String?
        switch chars {
        case "'": quoteOpenSingle.toggle(); mapped = quoteOpenSingle ? "‘" : "’"
        case "\"": quoteOpenDouble.toggle(); mapped = quoteOpenDouble ? "“" : "”"
        default: mapped = Self.fullWidthPunct[chars]
        }
        guard let fw = mapped else {
            if composing { // 未映射标点: 先上屏首选,原标点放行
                DebugLog.log("标点 '\(chars)' → 先上屏首选再放行")
                flush(candidates.first?.text ?? raw, client: client)
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
        flush(candidates.first?.text ?? raw, client: sender)
    }

    // MARK: - 内部

    private func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        var idx = selectedIndex + delta
        if idx < 0 { idx = candidates.count - 1 }
        if idx >= candidates.count { idx = 0 }
        selectedIndex = idx
        page = idx / Self.perPage
    }

    private func changePage(_ delta: Int) {
        let maxPage = (candidates.count - 1) / Self.perPage
        page = max(0, min(maxPage, page + delta))
        selectedIndex = page * Self.perPage
    }

    private func refresh(_ client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            DebugLog.error("refresh: client 不符合 IMKTextInput")
            return
        }
        candidates = raw.isEmpty ? [] : (Self.engine?.candidates(for: raw, limit: 30) ?? [])
        selectedIndex = 0
        page = 0
        DebugLog.log("refresh '\(raw)' → 候选 \(candidates.count) 条: "
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
            if raw.count >= 4 {
                // 无词典候选但 FM 可能出整句:光标处占位等待,不取消推理
                DebugLog.log("无词典候选(长 \(raw.count))→ 占位等待 FM 整句")
                updateCandidateWindow(client, loading: true)
                scheduleFMRerank(client)
            } else {
                DebugLog.log("无候选且过短 → 隐藏候选窗")
                candidateWindow.hide()
            }
        } else {
            updateCandidateWindow(client)
            scheduleFMRerank(client)
        }
    }

    private func pageItems() -> [CandidateItem] {
        let start = page * Self.perPage
        let end = min(start + Self.perPage, candidates.count)
        return (start..<end).map { i in
            CandidateItem(index: i, text: candidates[i].text, isAI: candidates[i].text == aiBoostText)
        }
    }

    private func updateCandidateWindow(_ client: Any!, loading: Bool = false) {
        if candidates.isEmpty {
            guard loading else { candidateWindow.hide(); return }
            let caret = Self.caretRect(client)
            DebugLog.log("候选窗占位(FM 整句中) caret=\(NSStringFromRect(caret))")
            candidateWindow.show(
                items: [], selectedIndex: 0, hasMorePages: false, canPrevPage: false,
                isLoading: true, caretRect: caret, onSelect: { _ in }, onPage: { _ in })
            return
        }
        let caret = Self.caretRect(client)
        DebugLog.log("候选窗定位 caret=\(NSStringFromRect(caret)) 选中=\(selectedIndex) 页=\(page)")
        candidateWindow.show(
            items: pageItems(),
            selectedIndex: selectedIndex,
            hasMorePages: (page + 1) * Self.perPage < candidates.count,
            canPrevPage: page > 0,
            caretRect: caret,
            onSelect: { [weak self] idx in
                DispatchQueue.main.async {
                    DebugLog.log("点击候选 idx=\(idx)")
                    self?.commitCandidate(at: idx, client: self?.client())
                }
            },
            onPage: { [weak self] delta in
                DispatchQueue.main.async {
                    DebugLog.log("点击翻页 \(delta > 0 ? "▸" : "◂") → 页=\((self?.page ?? 0) + delta)")
                    self?.changePage(delta)
                    self?.updateCandidateWindow(self?.client())
                }
            })
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
        // 渐进前缀词(匹配键串是输入串的真前缀): 转换该段进缓冲,剩余拼音继续预测(整句保持预编辑态)
        let concat = cand.pinyin.replacingOccurrences(of: " ", with: "")
        if !concat.isEmpty, raw.hasPrefix(concat), concat.count < raw.count {
            let remainder = String(raw.dropFirst(concat.count))
            DebugLog.log("分段转换 '\(cand.text)' → 余 '\(remainder)'")
            UserFreq.shared.record(cand.text) // 用户词频: 选用即计数
            committedBuffer += cand.text
            undoStack.append(UndoEntry(segmentText: cand.text, previousRaw: raw, remainderRaw: remainder))
            raw = remainder
            aiBoostText = nil
            fmGeneration &+= 1
            refresh(client)
            return
        }
        UserFreq.shared.record(cand.text) // 用户词频: 选用即计数
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
        if let textInput = client as? IMKTextInput {
            textInput.setMarkedText(NSMutableAttributedString(),
                                    selectionRange: NSRange(location: 0, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        candidateWindow.hide()
    }

    // MARK: - FM 异步重排(0.4s 防抖;结果到达时若组词已变则丢弃)

    private func scheduleFMRerank(_ client: Any!) {
        fmGeneration &+= 1
        let gen = fmGeneration
        let snapshotRaw = raw
        let context = Self.contextBeforeCaret(client)
        let texts = candidates.prefix(Self.perPage).map(\.text)

        // 整句判定: 无候选,或输入较长(≥8 字母)——引擎组句是即时草稿,长输入始终触发 FM 纠正
        let needSentence = (texts.isEmpty && raw.count >= 4) || raw.count >= 8
        if texts.count <= 1 && !needSentence {
            DebugLog.log("FM 跳过: 候选不足")
            return
        }
        DebugLog.log("FM 排队 gen=\(gen) 模式=\(needSentence ? "整句" : "重排") 上文='\(context)' 拼音='\(snapshotRaw)' 候选=\(texts)")

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
                guard let sentence = await FMReranker.shared.predictSentence(context: context, pinyin: snapshotRaw) else {
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
                    DebugLog.log("FM 整句生效 gen=\(gen): '\(sentence)' 置顶 ✦")
                    self.applyAISentence(sentence)
                }
            } else {
                guard let best = await FMReranker.shared.rerank(context: context, pinyin: snapshotRaw, candidates: texts) else {
                    DebugLog.log("FM 无结果 gen=\(gen)")
                    return
                }
                await MainActor.run {
                    guard self.raw == snapshotRaw, self.fmGeneration == gen,
                          best < texts.count else {
                        DebugLog.log("FM 结果过期丢弃 gen=\(gen)")
                        return
                    }
                    DebugLog.log("FM 生效 gen=\(gen): '\(texts[best])' 置顶 ✦")
                    self.applyAIRerank(text: texts[best])
                }
            }
        }
    }

    /// 把 FM 选中的词移到首位并标记 ✦
    private func applyAIRerank(text: String) {
        guard let idx = candidates.firstIndex(where: { $0.text == text }), idx > 0 else { return }
        let picked = candidates.remove(at: idx)
        candidates.insert(picked, at: 0)
        aiBoostText = picked.text
        selectedIndex = 0
        page = 0
        updateCandidateWindow(client())
    }

    /// 把 FM 整句预测结果作为首个候选(✦),空格/1 直接上屏
    private func applyAISentence(_ sentence: String) {
        guard !candidates.contains(where: { $0.text == sentence }) else { return }
        let cand = CandidateEngine.Candidate(text: sentence, pinyin: "(AI 整句)", score: .greatestFiniteMagnitude)
        candidates.insert(cand, at: 0)
        aiBoostText = sentence
        selectedIndex = 0
        page = 0
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
