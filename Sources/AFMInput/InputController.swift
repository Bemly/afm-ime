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

    // MARK: - 组词状态

    private var raw = ""                                  // 拼音缓冲
    private var candidates: [CandidateEngine.Candidate] = []
    private var selectedIndex = 0                         // 全局选中下标
    private var page = 0
    private var aiBoostText: String?                      // FM 提到首位的词
    private var fmGeneration = 0                          // FM 请求代际(防陈旧结果回写)
    private let candidateWindow = CandidateWindowController()

    override init(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
        DebugLog.log("InputController 初始化 client=\(client != nil)")
    }

    override func activateServer(_ sender: Any!) {
        DebugLog.log("activateServer")
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
        guard let event, event.type == .keyDown else {
            DebugLog.log("忽略非 keyDown 事件 type=\(event.map { "\($0.type)" } ?? "nil")")
            return false
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.isSubset(of: [.shift, .capsLock]) {
            DebugLog.log("放行带修饰键 key chars=\(event.charactersIgnoringModifiers ?? "?") mods=\(mods.rawValue)")
            return false
        }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else {
            DebugLog.log("放行多字符事件 '\(event.charactersIgnoringModifiers ?? "?")'")
            return false
        }
        let key = Character(chars).lowercased().first ?? "_"
        let composing = !raw.isEmpty
        DebugLog.log("key '\(chars)' scalar=\(scalar.value) keyCode=\(event.keyCode) composing=\(composing) raw='\(raw)'")

        switch true {
        case ("a"..."z").contains(key), key == "'":
            raw.append(key)
            refresh(client)
            return true

        case event.keyCode == 49 where composing: // 空格键(keyCode 49)→ 上屏选中候选,不插入空格
            DebugLog.log("空格键 → 上屏选中 idx=\(selectedIndex)")
            commitCandidate(at: selectedIndex, client: client)
            return true

        case event.keyCode == 36 where composing: // 回车键(keyCode 36)→ 上屏拼音原文
            DebugLog.log("回车 → 上屏原文 '\(raw)'")
            commit(raw, client: client)
            return true

        case (49...57).contains(scalar.value) where !candidates.isEmpty: // 字符 '1'-'9' 选当前页
            let idx = page * Self.perPage + Int(scalar.value) - 49
            if idx < candidates.count {
                DebugLog.log("数字 \(Int(scalar.value) - 48) → 上屏 idx=\(idx)")
                commitCandidate(at: idx, client: client)
                return true
            }
            DebugLog.log("数字越界 idx=\(idx),放行")
            return false

        case event.keyCode == 51 where composing: // 退格键(keyCode 51)→ 删最后一个字母,组词延续
            raw.removeLast()
            aiBoostText = nil
            DebugLog.log("退格 → raw='\(raw)'")
            refresh(client)
            return true

        case event.keyCode == 53 where composing: // Esc 键(keyCode 53)→ 取消组词
            DebugLog.log("Esc → 取消组词")
            clearComposition(client)
            return true

        case event.keyCode == 125 where composing: // ↓ 键(keyCode 125)高亮下一个
            moveSelection(+1)
            DebugLog.log("↓ 选中=\(selectedIndex) 页=\(page)")
            updateCandidateWindow(client)
            return true

        case event.keyCode == 126 where composing: // ↑ 键(keyCode 126)高亮上一个
            moveSelection(-1)
            DebugLog.log("↑ 选中=\(selectedIndex) 页=\(page)")
            updateCandidateWindow(client)
            return true

        case (chars == "=" || chars == "-") where composing: // =/- 翻页
            changePage(chars == "=" ? 1 : -1)
            DebugLog.log("翻页\(chars == "=" ? "+" : "-") → 页=\(page)")
            updateCandidateWindow(client)
            return true

        default:
            if composing { // 标点等: 先上屏首选,标点放行
                DebugLog.log("标点 '\(chars)' → 先上屏首选再放行")
                commit(candidates.first?.text ?? raw, client: client)
            } else {
                DebugLog.log("无组词,放行 '\(chars)'")
            }
            return false
        }
    }

    // MARK: - 组词状态

    override func composedString(_ sender: Any!) -> Any! {
        NSAttributedString(string: raw)
    }

    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: raw)
    }

    override func commitComposition(_ sender: Any!) {
        DebugLog.log("commitComposition raw='\(raw)' 首选=\(candidates.first?.text ?? "无")")
        guard !raw.isEmpty else { return }
        commit(candidates.first?.text ?? raw, client: sender)
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

        let marked = NSMutableAttributedString(string: raw)
        if !raw.isEmpty {
            marked.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: 0, length: raw.utf16.count))
        }
        textInput.setMarkedText(marked,
                                selectionRange: NSRange(location: marked.length, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        if candidates.isEmpty {
            DebugLog.log("无候选 → 隐藏候选窗")
            candidateWindow.hide()
            fmGeneration &+= 1
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

    private func updateCandidateWindow(_ client: Any!) {
        guard !candidates.isEmpty else { candidateWindow.hide(); return }
        let caret = Self.caretRect(client)
        DebugLog.log("候选窗定位 caret=\(NSStringFromRect(caret)) 选中=\(selectedIndex) 页=\(page)")
        candidateWindow.show(
            items: pageItems(),
            selectedIndex: selectedIndex,
            hasMorePages: (page + 1) * Self.perPage < candidates.count,
            caretRect: caret,
            onSelect: { [weak self] idx in
                DispatchQueue.main.async {
                    DebugLog.log("点击候选 idx=\(idx)")
                    self?.commitCandidate(at: idx, client: self?.client())
                }
            })
    }

    private func commitCandidate(at index: Int, client: Any!) {
        guard index < candidates.count else {
            DebugLog.error("commitCandidate 越界 idx=\(index) 总数=\(candidates.count)")
            return
        }
        commit(candidates[index].text, client: client)
    }

    private func commit(_ text: String, client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            DebugLog.error("commit: client 不符合 IMKTextInput,仅清组词")
            clearComposition(client); return
        }
        DebugLog.log("上屏 '\(text)'")
        textInput.insertText(NSAttributedString(string: text),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        clearComposition(client)
    }

    private func clearComposition(_ client: Any!) {
        raw = ""
        candidates = []
        aiBoostText = nil
        fmGeneration &+= 1
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

        // 整句判定: 无候选,或输入较长而最佳候选的拼音覆盖不足一半(词典切不出整句)
        let topCover = candidates.first?.pinyin.count ?? 0
        let needSentence = texts.isEmpty
            || (snapshotRaw.count >= 8 && topCover < snapshotRaw.count / 2)
        if texts.count <= 1 && !needSentence {
            DebugLog.log("FM 跳过: 候选不足")
            return
        }
        DebugLog.log("FM 排队 gen=\(gen) 模式=\(needSentence ? "整句" : "重排") 上文='\(context)' 拼音='\(snapshotRaw)' 候选=\(texts)")

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            let stillCurrent = await MainActor.run { self.raw == snapshotRaw && self.fmGeneration == gen }
            guard stillCurrent else {
                DebugLog.log("FM 结果丢弃 gen=\(gen)(组词已变化)")
                return
            }
            if needSentence {
                guard let sentence = await FMReranker.shared.predictSentence(context: context, pinyin: snapshotRaw) else {
                    DebugLog.log("FM 整句无结果 gen=\(gen)")
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
