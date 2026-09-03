import AppKit
import InputMethodKit
import IMECore

@objc(InputController)
final class InputController: IMKInputController {
    // MARK: - 引擎(进程内单例)

    static let engine: CandidateEngine? = {
        let path = Bundle.main.path(forResource: "dict", ofType: "bin") ?? "Data/dict.bin"
        guard let store = try? DictStore(url: URL(fileURLWithPath: path)) else {
            NSLog("[AFM] 词库加载失败: %@", path)
            return nil
        }
        NSLog("[AFM] 词库已加载 %@ (记录 %d)", path, store.recordCount)
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
    }

    override func activateServer(_ sender: Any!) {}
    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
    }
    override func hidePalettes() {
        candidateWindow.hide()
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client: Any!) -> Bool {
        guard Self.engine != nil else { return false }
        guard let event, event.type == .keyDown else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.isSubset(of: [.shift, .capsLock]) { return false } // 含 cmd/ctrl/opt 一律放行

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }
        let key = Character(chars).lowercased().first ?? "_"
        let composing = !raw.isEmpty

        switch true {
        case ("a"..."z").contains(key), key == "'":
            raw.append(key)
            refresh(client)
            return true

        case scalar.value == 49 where composing: // 空格 → 上屏选中候选
            commitCandidate(at: selectedIndex, client: client)
            return true

        case scalar.value == 36 where composing: // 回车 → 上屏拼音原文
            commit(raw, client: client)
            return true

        case (49...57).contains(scalar.value) where !candidates.isEmpty: // 数字 1-9 选当前页
            let idx = page * Self.perPage + Int(scalar.value) - 49
            if idx < candidates.count {
                commitCandidate(at: idx, client: client)
                return true
            }
            return false

        case scalar.value == 51 where composing: // 退格
            raw.removeLast()
            aiBoostText = nil
            refresh(client)
            return true

        case scalar.value == 53 where composing: // Esc 取消组词
            clearComposition(client)
            return true

        case scalar.value == 125 where composing: // ↓ 高亮下一个
            moveSelection(+1)
            updateCandidateWindow(client)
            return true

        case scalar.value == 126 where composing: // ↑ 高亮上一个
            moveSelection(-1)
            updateCandidateWindow(client)
            return true

        case (chars == "=" || chars == "-") where composing: // =/- 翻页
            changePage(chars == "=" ? 1 : -1)
            updateCandidateWindow(client)
            return true

        default:
            if composing { // 标点等: 先上屏首选,标点放行
                commit(candidates.first?.text ?? raw, client: client)
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
        guard let textInput = client as? IMKTextInput else { return }
        candidates = raw.isEmpty ? [] : (Self.engine?.candidates(for: raw, limit: 30) ?? [])
        selectedIndex = 0
        page = 0

        let marked = NSMutableAttributedString(string: raw)
        if !raw.isEmpty {
            marked.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: 0, length: raw.utf16.count))
        }
        textInput.setMarkedText(marked,
                                selectionRange: NSRange(location: marked.length, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        if candidates.isEmpty {
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
        candidateWindow.show(
            pinyin: raw,
            items: pageItems(),
            selectedIndex: selectedIndex,
            hasMorePages: (page + 1) * Self.perPage < candidates.count,
            caretRect: caret,
            onSelect: { [weak self] idx in
                DispatchQueue.main.async { self?.commitCandidate(at: idx, client: self?.client()) }
            })
    }

    private func commitCandidate(at index: Int, client: Any!) {
        guard index < candidates.count else { return }
        commit(candidates[index].text, client: client)
    }

    private func commit(_ text: String, client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            clearComposition(client); return
        }
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
        guard texts.count > 1 else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            let stillCurrent = await MainActor.run { self.raw == snapshotRaw && self.fmGeneration == gen }
            guard stillCurrent else { return }
            guard let best = await FMReranker.shared.rerank(context: context, pinyin: snapshotRaw, candidates: texts) else { return }
            await MainActor.run {
                guard self.raw == snapshotRaw, self.fmGeneration == gen,
                      best < texts.count else { return }
                self.applyAIRerank(text: texts[best])
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

    // MARK: - 光标与上文

    /// 光标屏幕坐标矩形(AppKit 底左原点),经 attributes(forCharacterIndex:) 拿行高矩形
    static func caretRect(_ client: Any!) -> NSRect {
        guard let t = client as? IMKTextInput else { return NSRect(x: 0, y: 0, width: 1, height: 20) }
        let sel = t.selectedRange()
        let loc = sel.location == NSNotFound ? 0 : min(sel.location, 4096)
        var rect = NSRect(x: 0, y: 0, width: 1, height: 20)
        _ = t.attributes(forCharacterIndex: loc, lineHeightRectangle: &rect)
        if rect.width <= 0 || rect.height <= 0 {
            rect = NSRect(x: rect.minX, y: rect.minY, width: 1, height: max(rect.height, 20))
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
